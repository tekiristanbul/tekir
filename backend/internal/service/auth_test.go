package service_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// backfillCall records one invocation of BackfillFollowsUserID or
// BackfillUpdatesAuthorUserID, so a test can assert linkDevice's backfill
// fires with the right ids without a real database.
type backfillCall struct {
	deviceID uuid.UUID
	userID   uuid.UUID
}

// fakeAuthStore is an in-process stub for service.AuthStore.
type fakeAuthStore struct {
	clock        func() time.Time
	otpCodes     map[string]repository.OtpCode // keyed by phone, latest only
	usersByID    map[uuid.UUID]repository.User
	usersByPhone map[string]repository.User
	devices      map[uuid.UUID]repository.GetDeviceByIDRow

	createUserErr error

	backfillFollowsCalls []backfillCall
	backfillUpdatesCalls []backfillCall
}

func newFakeAuthStore() *fakeAuthStore {
	return &fakeAuthStore{
		clock:        time.Now,
		otpCodes:     map[string]repository.OtpCode{},
		usersByID:    map[uuid.UUID]repository.User{},
		usersByPhone: map[string]repository.User{},
		devices:      map[uuid.UUID]repository.GetDeviceByIDRow{},
	}
}

func (f *fakeAuthStore) CreateOtpCode(_ context.Context, arg repository.CreateOtpCodeParams) (repository.CreateOtpCodeRow, error) {
	f.otpCodes[arg.Phone] = repository.OtpCode{
		ID:          arg.ID,
		Phone:       arg.Phone,
		CodeHash:    arg.CodeHash,
		MaxAttempts: arg.MaxAttempts,
		ExpiresAt:   arg.ExpiresAt,
		CreatedAt:   pgtype.Timestamptz{Time: f.clock(), Valid: true},
	}
	return repository.CreateOtpCodeRow{ID: arg.ID}, nil
}

func (f *fakeAuthStore) GetLatestOtpCode(_ context.Context, phone string) (repository.OtpCode, error) {
	row, ok := f.otpCodes[phone]
	if !ok {
		return repository.OtpCode{}, pgx.ErrNoRows
	}
	return row, nil
}

func (f *fakeAuthStore) IncrementOtpAttempts(_ context.Context, id pgtype.UUID) error {
	for phone, row := range f.otpCodes {
		if row.ID == id {
			row.Attempts++
			f.otpCodes[phone] = row
		}
	}
	return nil
}

// ConsumeOtpCodeIfValid mirrors the real atomic compare-and-set query's
// predicates (id/code_hash match, unconsumed, unexpired, attempts under
// limit) — f.otpCodes only ever holds one (the latest) row per phone, so
// "still the latest" is automatically true for whatever's stored here.
func (f *fakeAuthStore) ConsumeOtpCodeIfValid(_ context.Context, arg repository.ConsumeOtpCodeIfValidParams) (pgtype.UUID, error) {
	row, ok := f.otpCodes[arg.Phone]
	if !ok || row.ID != arg.ID || row.CodeHash != arg.CodeHash ||
		row.ConsumedAt.Valid || !row.ExpiresAt.Time.After(arg.Now.Time) ||
		row.Attempts >= row.MaxAttempts {
		return pgtype.UUID{}, pgx.ErrNoRows
	}
	row.ConsumedAt = arg.ConsumedAt
	f.otpCodes[arg.Phone] = row
	return row.ID, nil
}

func (f *fakeAuthStore) GetUserByPhone(_ context.Context, phone string) (repository.User, error) {
	row, ok := f.usersByPhone[phone]
	if !ok {
		return repository.User{}, pgx.ErrNoRows
	}
	return row, nil
}

func (f *fakeAuthStore) CreateUser(_ context.Context, arg repository.CreateUserParams) (repository.User, error) {
	if f.createUserErr != nil {
		return repository.User{}, f.createUserErr
	}
	user := repository.User{ID: arg.ID, Phone: arg.Phone, PhoneVerifiedAt: arg.PhoneVerifiedAt}
	f.usersByPhone[arg.Phone] = user
	f.usersByID[uuid.UUID(arg.ID.Bytes)] = user
	return user, nil
}

func (f *fakeAuthStore) UpdateUserDisplayName(_ context.Context, arg repository.UpdateUserDisplayNameParams) error {
	id := uuid.UUID(arg.ID.Bytes)
	user, ok := f.usersByID[id]
	if !ok {
		return pgx.ErrNoRows
	}
	user.DisplayName = arg.DisplayName
	f.usersByID[id] = user
	f.usersByPhone[user.Phone] = user
	return nil
}

func (f *fakeAuthStore) GetDeviceByID(_ context.Context, id pgtype.UUID) (repository.GetDeviceByIDRow, error) {
	row, ok := f.devices[uuid.UUID(id.Bytes)]
	if !ok {
		return repository.GetDeviceByIDRow{ID: id}, nil
	}
	return row, nil
}

func (f *fakeAuthStore) LinkDeviceToUser(_ context.Context, arg repository.LinkDeviceToUserParams) error {
	f.devices[uuid.UUID(arg.ID.Bytes)] = repository.GetDeviceByIDRow{ID: arg.ID, UserID: arg.UserID}
	return nil
}

func (f *fakeAuthStore) BackfillFollowsUserID(_ context.Context, arg repository.BackfillFollowsUserIDParams) error {
	f.backfillFollowsCalls = append(f.backfillFollowsCalls, backfillCall{
		deviceID: uuid.UUID(arg.DeviceID.Bytes),
		userID:   uuid.UUID(arg.UserID.Bytes),
	})
	return nil
}

func (f *fakeAuthStore) BackfillUpdatesAuthorUserID(_ context.Context, arg repository.BackfillUpdatesAuthorUserIDParams) error {
	f.backfillUpdatesCalls = append(f.backfillUpdatesCalls, backfillCall{
		deviceID: uuid.UUID(arg.AuthorDeviceID.Bytes),
		userID:   uuid.UUID(arg.AuthorUserID.Bytes),
	})
	return nil
}

type fakeSms struct {
	sent []struct{ phone, code string }
}

func (f *fakeSms) Send(_ context.Context, phone, code string) error {
	f.sent = append(f.sent, struct{ phone, code string }{phone, code})
	return nil
}

func newTestAuthService(t *testing.T, store *fakeAuthStore, sms service.SmsSender, clock func() time.Time) *service.AuthService {
	t.Helper()
	store.clock = clock
	sessions := service.NewSessionService(newFakeSessionStore(), []byte("k"), time.Hour, 24*time.Hour, service.WithSessionClock(clock))
	return service.NewAuthService(store, sms, sessions, 5*time.Minute, 5, time.Minute, service.WithAuthClock(clock))
}

const testDeviceID = "11111111-1111-4111-8111-111111111111"

func TestAuthService_RequestOTP_SendsAndStoresCode(t *testing.T) {
	store := newFakeAuthStore()
	sms := &fakeSms{}
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	svc := newTestAuthService(t, store, sms, func() time.Time { return now })

	if err := svc.RequestOTP(context.Background(), "532 111 22 33"); err != nil {
		t.Fatalf("request otp: %v", err)
	}
	if len(sms.sent) != 1 {
		t.Fatalf("expected 1 sms sent, got %d", len(sms.sent))
	}
	if sms.sent[0].phone != "+905321112233" {
		t.Errorf("expected normalized phone, got %q", sms.sent[0].phone)
	}
	if len(sms.sent[0].code) != 6 {
		t.Errorf("expected 6-digit code, got %q", sms.sent[0].code)
	}
}

func TestAuthService_RequestOTP_InvalidPhone(t *testing.T) {
	store := newFakeAuthStore()
	svc := newTestAuthService(t, store, &fakeSms{}, time.Now)

	if err := svc.RequestOTP(context.Background(), "not-a-phone"); !errors.Is(err, service.ErrInvalidPhone) {
		t.Errorf("expected ErrInvalidPhone, got %v", err)
	}
}

func TestAuthService_RequestOTP_ResendCooldown(t *testing.T) {
	store := newFakeAuthStore()
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	svc := newTestAuthService(t, store, &fakeSms{}, func() time.Time { return now })

	if err := svc.RequestOTP(context.Background(), "5321112233"); err != nil {
		t.Fatalf("first request: %v", err)
	}
	if err := svc.RequestOTP(context.Background(), "5321112233"); !errors.Is(err, service.ErrOTPResendTooSoon) {
		t.Errorf("expected ErrOTPResendTooSoon, got %v", err)
	}
}

func TestAuthService_VerifyOTP_NewAccount(t *testing.T) {
	store := newFakeAuthStore()
	sms := &fakeSms{}
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	svc := newTestAuthService(t, store, sms, func() time.Time { return now })

	if err := svc.RequestOTP(context.Background(), "5321112233"); err != nil {
		t.Fatalf("request: %v", err)
	}
	code := sms.sent[0].code

	session, err := svc.VerifyOTP(context.Background(), "5321112233", code, testDeviceID)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if session.AccessToken == "" || session.RefreshToken == "" || session.UserID == "" {
		t.Error("expected a full session on successful verify")
	}
	if !session.IsNewAccount {
		t.Error("expected IsNewAccount true for a brand-new phone number")
	}

	linked, ok := store.devices[uuid.MustParse(testDeviceID)]
	if !ok || !linked.UserID.Valid {
		t.Fatal("expected device to be linked to the new account")
	}
	if uuid.UUID(linked.UserID.Bytes).String() != session.UserID {
		t.Error("linked device's user id must match the issued session's user id")
	}
}

func TestAuthService_VerifyOTP_ReturningAccount_ResolvesSameUser(t *testing.T) {
	store := newFakeAuthStore()
	sms := &fakeSms{}
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := &now
	svc := newTestAuthService(t, store, sms, func() time.Time { return *clock })

	// first device verifies and creates the account.
	if err := svc.RequestOTP(context.Background(), "5321112233"); err != nil {
		t.Fatalf("first request: %v", err)
	}
	first, err := svc.VerifyOTP(context.Background(), "5321112233", sms.sent[0].code, testDeviceID)
	if err != nil {
		t.Fatalf("first verify: %v", err)
	}

	// a second device verifying the same phone number must resolve to the
	// same account, not create a second one.
	const secondDeviceID = "22222222-2222-4222-8222-222222222222"
	*clock = clock.Add(2 * time.Minute) // past the otp resend cooldown
	if err := svc.RequestOTP(context.Background(), "5321112233"); err != nil {
		t.Fatalf("second request: %v", err)
	}
	second, err := svc.VerifyOTP(context.Background(), "5321112233", sms.sent[len(sms.sent)-1].code, secondDeviceID)
	if err != nil {
		t.Fatalf("second verify: %v", err)
	}

	if first.UserID != second.UserID {
		t.Errorf("expected same account for the same phone, got %s vs %s", first.UserID, second.UserID)
	}
	if !first.IsNewAccount {
		t.Error("expected the first verify to report IsNewAccount true")
	}
	if second.IsNewAccount {
		t.Error("expected the second (returning-account) verify to report IsNewAccount false")
	}
}

func TestAuthService_VerifyOTP_NotRequested(t *testing.T) {
	store := newFakeAuthStore()
	svc := newTestAuthService(t, store, &fakeSms{}, time.Now)

	if _, err := svc.VerifyOTP(context.Background(), "5321112233", "123456", testDeviceID); !errors.Is(err, service.ErrOTPNotRequested) {
		t.Errorf("expected ErrOTPNotRequested, got %v", err)
	}
}

func TestAuthService_VerifyOTP_WrongCode_IncrementsAttempts(t *testing.T) {
	store := newFakeAuthStore()
	sms := &fakeSms{}
	svc := newTestAuthService(t, store, sms, time.Now)

	_ = svc.RequestOTP(context.Background(), "5321112233")

	if _, err := svc.VerifyOTP(context.Background(), "5321112233", "000000", testDeviceID); !errors.Is(err, service.ErrOTPCodeMismatch) {
		t.Errorf("expected ErrOTPCodeMismatch, got %v", err)
	}
	if store.otpCodes["+905321112233"].Attempts != 1 {
		t.Errorf("expected attempts to increment to 1, got %d", store.otpCodes["+905321112233"].Attempts)
	}
}

func TestAuthService_VerifyOTP_TooManyAttempts(t *testing.T) {
	store := newFakeAuthStore()
	sms := &fakeSms{}
	sessions := service.NewSessionService(newFakeSessionStore(), []byte("k"), time.Hour, 24*time.Hour)
	svc := service.NewAuthService(store, sms, sessions, 5*time.Minute, 2, time.Minute)

	_ = svc.RequestOTP(context.Background(), "5321112233")

	_, _ = svc.VerifyOTP(context.Background(), "5321112233", "000000", testDeviceID)
	_, _ = svc.VerifyOTP(context.Background(), "5321112233", "000000", testDeviceID)

	if _, err := svc.VerifyOTP(context.Background(), "5321112233", sms.sent[0].code, testDeviceID); !errors.Is(err, service.ErrOTPTooManyAttempts) {
		t.Errorf("expected ErrOTPTooManyAttempts after exhausting attempts, got %v", err)
	}
}

func TestAuthService_VerifyOTP_Expired(t *testing.T) {
	store := newFakeAuthStore()
	sms := &fakeSms{}
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := &now
	svc := newTestAuthService(t, store, sms, func() time.Time { return *clock })

	_ = svc.RequestOTP(context.Background(), "5321112233")
	code := sms.sent[0].code

	*clock = clock.Add(10 * time.Minute)
	if _, err := svc.VerifyOTP(context.Background(), "5321112233", code, testDeviceID); !errors.Is(err, service.ErrOTPExpired) {
		t.Errorf("expected ErrOTPExpired, got %v", err)
	}
}

func TestAuthService_VerifyOTP_ReplayAfterSuccess(t *testing.T) {
	store := newFakeAuthStore()
	sms := &fakeSms{}
	svc := newTestAuthService(t, store, sms, time.Now)

	_ = svc.RequestOTP(context.Background(), "5321112233")
	code := sms.sent[0].code

	if _, err := svc.VerifyOTP(context.Background(), "5321112233", code, testDeviceID); err != nil {
		t.Fatalf("first verify: %v", err)
	}

	const secondDeviceID = "22222222-2222-4222-8222-222222222222"
	if _, err := svc.VerifyOTP(context.Background(), "5321112233", code, secondDeviceID); !errors.Is(err, service.ErrOTPAlreadyConsumed) {
		t.Errorf("expected ErrOTPAlreadyConsumed replaying a consumed code, got %v", err)
	}
}

func TestAuthService_VerifyOTP_DeviceAlreadyLinkedToDifferentAccount(t *testing.T) {
	store := newFakeAuthStore()
	sms := &fakeSms{}
	svc := newTestAuthService(t, store, sms, time.Now)

	// device links to the first account.
	_ = svc.RequestOTP(context.Background(), "5321112233")
	if _, err := svc.VerifyOTP(context.Background(), "5321112233", sms.sent[0].code, testDeviceID); err != nil {
		t.Fatalf("first verify: %v", err)
	}

	// the same device now attempts to verify a different phone number —
	// must be rejected rather than silently reassigning the device.
	_ = svc.RequestOTP(context.Background(), "5339998877")
	if _, err := svc.VerifyOTP(context.Background(), "5339998877", sms.sent[len(sms.sent)-1].code, testDeviceID); !errors.Is(err, service.ErrDeviceLinkedToOtherAccount) {
		t.Errorf("expected ErrDeviceLinkedToOtherAccount, got %v", err)
	}
}

func TestAuthService_VerifyOTP_RelinkingSameAccountIsIdempotent(t *testing.T) {
	store := newFakeAuthStore()
	sms := &fakeSms{}
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := &now
	svc := newTestAuthService(t, store, sms, func() time.Time { return *clock })

	if err := svc.RequestOTP(context.Background(), "5321112233"); err != nil {
		t.Fatalf("first request: %v", err)
	}
	first, err := svc.VerifyOTP(context.Background(), "5321112233", sms.sent[0].code, testDeviceID)
	if err != nil {
		t.Fatalf("first verify: %v", err)
	}

	// same device, same phone/account, verifying again (e.g. a retried
	// request) must succeed without error.
	*clock = clock.Add(2 * time.Minute) // past the otp resend cooldown
	if err := svc.RequestOTP(context.Background(), "5321112233"); err != nil {
		t.Fatalf("second request: %v", err)
	}
	second, err := svc.VerifyOTP(context.Background(), "5321112233", sms.sent[len(sms.sent)-1].code, testDeviceID)
	if err != nil {
		t.Fatalf("second verify (relink to same account): %v", err)
	}
	if first.UserID != second.UserID {
		t.Error("expected the same account on idempotent relink")
	}
}

// TestAuthService_VerifyOTP_BackfillsFollowsAndUpdatesUserID proves
// linkDevice backfills a newly-linked device's pre-existing device-owned
// content onto the account (issue #65) — asserted here at the fake-store
// level; the real-database preservation guarantee is covered by
// internal/repository/auth_integration_test.go.
func TestAuthService_VerifyOTP_BackfillsFollowsAndUpdatesUserID(t *testing.T) {
	store := newFakeAuthStore()
	sms := &fakeSms{}
	svc := newTestAuthService(t, store, sms, time.Now)

	_ = svc.RequestOTP(context.Background(), "5321112233")
	session, err := svc.VerifyOTP(context.Background(), "5321112233", sms.sent[0].code, testDeviceID)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}

	if len(store.backfillFollowsCalls) != 1 {
		t.Fatalf("expected exactly one follows backfill call, got %d", len(store.backfillFollowsCalls))
	}
	if got := store.backfillFollowsCalls[0]; got.deviceID.String() != testDeviceID || got.userID.String() != session.UserID {
		t.Errorf("unexpected follows backfill args: %+v", got)
	}
	if len(store.backfillUpdatesCalls) != 1 {
		t.Fatalf("expected exactly one updates backfill call, got %d", len(store.backfillUpdatesCalls))
	}
	if got := store.backfillUpdatesCalls[0]; got.deviceID.String() != testDeviceID || got.userID.String() != session.UserID {
		t.Errorf("unexpected updates backfill args: %+v", got)
	}
}

// TestAuthService_VerifyOTP_ReVerifySameAccount_BackfillIsIdempotent proves
// re-verifying an already-linked device runs the backfill again (safe,
// since the real queries only touch still-null rows) rather than skipping
// it — a second verification must not be a smaller-guarantee no-op.
func TestAuthService_VerifyOTP_ReVerifySameAccount_BackfillIsIdempotent(t *testing.T) {
	store := newFakeAuthStore()
	sms := &fakeSms{}
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := &now
	svc := newTestAuthService(t, store, sms, func() time.Time { return *clock })

	_ = svc.RequestOTP(context.Background(), "5321112233")
	if _, err := svc.VerifyOTP(context.Background(), "5321112233", sms.sent[0].code, testDeviceID); err != nil {
		t.Fatalf("first verify: %v", err)
	}

	*clock = clock.Add(2 * time.Minute)
	_ = svc.RequestOTP(context.Background(), "5321112233")
	if _, err := svc.VerifyOTP(context.Background(), "5321112233", sms.sent[len(sms.sent)-1].code, testDeviceID); err != nil {
		t.Fatalf("second verify: %v", err)
	}

	if len(store.backfillFollowsCalls) != 2 {
		t.Errorf("expected backfill to run on every successful link (idempotent at the query level), got %d calls", len(store.backfillFollowsCalls))
	}
	if store.backfillFollowsCalls[0].userID != store.backfillFollowsCalls[1].userID {
		t.Error("expected both backfill calls to target the same account")
	}
}

// TestAuthService_VerifyOTP_DeviceLinkedToOtherAccount_NeverBackfills is
// the explicit regression for "must not silently transfer ownership": a
// device rejected for belonging to a different account must never have its
// content backfilled toward the new account.
func TestAuthService_VerifyOTP_DeviceLinkedToOtherAccount_NeverBackfills(t *testing.T) {
	store := newFakeAuthStore()
	sms := &fakeSms{}
	svc := newTestAuthService(t, store, sms, time.Now)

	_ = svc.RequestOTP(context.Background(), "5321112233")
	if _, err := svc.VerifyOTP(context.Background(), "5321112233", sms.sent[0].code, testDeviceID); err != nil {
		t.Fatalf("first verify: %v", err)
	}
	callsAfterFirstLink := len(store.backfillFollowsCalls)

	_ = svc.RequestOTP(context.Background(), "5339998877")
	if _, err := svc.VerifyOTP(context.Background(), "5339998877", sms.sent[len(sms.sent)-1].code, testDeviceID); !errors.Is(err, service.ErrDeviceLinkedToOtherAccount) {
		t.Fatalf("expected ErrDeviceLinkedToOtherAccount, got %v", err)
	}

	if len(store.backfillFollowsCalls) != callsAfterFirstLink {
		t.Errorf("expected no additional backfill after a rejected relink, got %d calls (was %d)", len(store.backfillFollowsCalls), callsAfterFirstLink)
	}
}

func TestAuthService_SetDisplayName_Success(t *testing.T) {
	store := newFakeAuthStore()
	svc := newTestAuthService(t, store, &fakeSms{}, time.Now)

	id := uuid.New()
	store.usersByID[id] = repository.User{ID: pgtype.UUID{Bytes: id, Valid: true}, Phone: "+905321112233"}

	if err := svc.SetDisplayName(context.Background(), id.String(), "  Ayşe  "); err != nil {
		t.Fatalf("set display name: %v", err)
	}
	got := store.usersByID[id]
	if !got.DisplayName.Valid || got.DisplayName.String != "Ayşe" {
		t.Errorf("expected trimmed display name %q, got %+v", "Ayşe", got.DisplayName)
	}
}

func TestAuthService_SetDisplayName_EmptyOrWhitespace(t *testing.T) {
	store := newFakeAuthStore()
	svc := newTestAuthService(t, store, &fakeSms{}, time.Now)

	for _, name := range []string{"", "   "} {
		if err := svc.SetDisplayName(context.Background(), uuid.New().String(), name); !errors.Is(err, service.ErrInvalidDisplayName) {
			t.Errorf("expected ErrInvalidDisplayName for %q, got %v", name, err)
		}
	}
}

func TestAuthService_SetDisplayName_TooLong(t *testing.T) {
	store := newFakeAuthStore()
	svc := newTestAuthService(t, store, &fakeSms{}, time.Now)

	tooLong := strings.Repeat("a", 61)
	if err := svc.SetDisplayName(context.Background(), uuid.New().String(), tooLong); !errors.Is(err, service.ErrInvalidDisplayName) {
		t.Errorf("expected ErrInvalidDisplayName for a 61-char name, got %v", err)
	}
}

func TestAuthService_SetDisplayName_InvalidUserID(t *testing.T) {
	store := newFakeAuthStore()
	svc := newTestAuthService(t, store, &fakeSms{}, time.Now)

	if err := svc.SetDisplayName(context.Background(), "not-a-uuid", "Ayşe"); !errors.Is(err, service.ErrInvalidDisplayName) {
		t.Errorf("expected ErrInvalidDisplayName for a malformed user id, got %v", err)
	}
}

func TestHashOTPCode_BoundToPhone(t *testing.T) {
	if service.HashOTPCode("+905321112233", "123456") == service.HashOTPCode("+905339998877", "123456") {
		t.Error("the same code for two different phone numbers must hash differently")
	}
	h1 := service.HashOTPCode("+905321112233", "123456")
	h2 := service.HashOTPCode("+905321112233", "123456")
	if h1 != h2 {
		t.Error("same phone+code must hash the same")
	}
}
