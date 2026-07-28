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

// UnlinkDeviceFromUser mirrors the real query's own guard exactly: only
// clears the link when the device is currently linked to this exact
// account, a no-op otherwise (mismatched, unknown, or already-unlinked).
func (f *fakeAuthStore) UnlinkDeviceFromUser(_ context.Context, arg repository.UnlinkDeviceFromUserParams) error {
	row, ok := f.devices[uuid.UUID(arg.ID.Bytes)]
	if !ok || !row.UserID.Valid || row.UserID != arg.UserID {
		return nil
	}
	row.UserID = pgtype.UUID{}
	f.devices[uuid.UUID(arg.ID.Bytes)] = row
	return nil
}

func (f *fakeAuthStore) DeleteRedundantDeviceFollows(_ context.Context, _ repository.DeleteRedundantDeviceFollowsParams) error {
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
const testUserID = "22222222-2222-4222-8222-222222222222"

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

// ── UnlinkDevice / account switching (issue #80, product-owner review) ─────────

func TestAuthService_UnlinkDevice_ClearsLinkForMatchingAccount(t *testing.T) {
	store := newFakeAuthStore()
	svc := newTestAuthService(t, store, &fakeSms{}, time.Now)
	deviceID := uuid.MustParse(testDeviceID)

	store.devices[deviceID] = repository.GetDeviceByIDRow{
		ID:     pgtype.UUID{Bytes: deviceID, Valid: true},
		UserID: pgtype.UUID{Bytes: uuid.MustParse(testUserID), Valid: true},
	}

	if err := svc.UnlinkDevice(context.Background(), testDeviceID, testUserID); err != nil {
		t.Fatalf("unlink: %v", err)
	}
	if store.devices[deviceID].UserID.Valid {
		t.Errorf("expected the device to be unlinked, got %v", store.devices[deviceID].UserID)
	}
}

func TestAuthService_UnlinkDevice_NoopForMismatchedAccount(t *testing.T) {
	store := newFakeAuthStore()
	svc := newTestAuthService(t, store, &fakeSms{}, time.Now)
	deviceID := uuid.MustParse(testDeviceID)
	owner := uuid.MustParse(testUserID)

	store.devices[deviceID] = repository.GetDeviceByIDRow{
		ID:     pgtype.UUID{Bytes: deviceID, Valid: true},
		UserID: pgtype.UUID{Bytes: owner, Valid: true},
	}

	stranger := uuid.New()
	if err := svc.UnlinkDevice(context.Background(), testDeviceID, stranger.String()); err != nil {
		t.Fatalf("unlink attempt (mismatched account): %v", err)
	}
	if store.devices[deviceID].UserID != (pgtype.UUID{Bytes: owner, Valid: true}) {
		t.Errorf("expected the device to remain linked to its real owner, got %v", store.devices[deviceID].UserID)
	}
}

func TestAuthService_UnlinkDevice_InvalidIDs(t *testing.T) {
	store := newFakeAuthStore()
	svc := newTestAuthService(t, store, &fakeSms{}, time.Now)

	if err := svc.UnlinkDevice(context.Background(), "not-a-uuid", testUserID); err == nil {
		t.Error("expected an error for a malformed device id")
	}
	if err := svc.UnlinkDevice(context.Background(), testDeviceID, "not-a-uuid"); err == nil {
		t.Error("expected an error for a malformed user id")
	}
}

// TestAuthService_AccountSwitch_LogoutThenDifferentPhoneLoginSucceeds is
// the end-to-end regression for the exact bug the product-owner review
// found: without an unlink step, a device permanently rejects any second
// account (409, ErrDeviceLinkedToOtherAccount) forever. Simulates logout
// via UnlinkDevice (the same call AuthHandler.Logout now makes) between
// two real VerifyOTP flows on the same device.
func TestAuthService_AccountSwitch_LogoutThenDifferentPhoneLoginSucceeds(t *testing.T) {
	store := newFakeAuthStore()
	sms := &fakeSms{}
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := &now
	svc := newTestAuthService(t, store, sms, func() time.Time { return *clock })

	// account A logs in on the device.
	_ = svc.RequestOTP(context.Background(), "5321112233")
	sessionA, err := svc.VerifyOTP(context.Background(), "5321112233", sms.sent[0].code, testDeviceID)
	if err != nil {
		t.Fatalf("A verify: %v", err)
	}

	// account A "logs out": the device unlinks (AuthHandler.Logout's new step).
	if err := svc.UnlinkDevice(context.Background(), testDeviceID, sessionA.UserID); err != nil {
		t.Fatalf("unlink A: %v", err)
	}

	// account B logs in on the SAME device — must succeed now, not 409.
	_ = svc.RequestOTP(context.Background(), "5339998877")
	sessionB, err := svc.VerifyOTP(context.Background(), "5339998877", sms.sent[len(sms.sent)-1].code, testDeviceID)
	if err != nil {
		t.Fatalf("expected B's login on the unlinked device to succeed, got %v", err)
	}
	if sessionB.UserID == sessionA.UserID {
		t.Fatal("expected B to resolve to a distinct account from A")
	}

	// account B "logs out" too, and account A logs back in — must resolve
	// to A's *original* account, not create a new one. Advance past the
	// per-phone otp resend cooldown so this second request for A's own
	// phone number isn't silently dropped.
	if err := svc.UnlinkDevice(context.Background(), testDeviceID, sessionB.UserID); err != nil {
		t.Fatalf("unlink B: %v", err)
	}
	*clock = clock.Add(2 * time.Minute)
	if err := svc.RequestOTP(context.Background(), "5321112233"); err != nil {
		t.Fatalf("A's second otp request: %v", err)
	}
	sessionA2, err := svc.VerifyOTP(context.Background(), "5321112233", sms.sent[len(sms.sent)-1].code, testDeviceID)
	if err != nil {
		t.Fatalf("expected A's re-login to succeed, got %v", err)
	}
	if sessionA2.UserID != sessionA.UserID {
		t.Fatalf("expected re-login to restore A's original account %s, got %s", sessionA.UserID, sessionA2.UserID)
	}

	// B's own backfill (from its own link above) must never have touched
	// A's follows/updates — asserted at the call-args level here; the real
	// no-cross-contamination guarantee against actual data is covered by
	// TestStore_AccountSwitch_SameDeviceDifferentAccount_NeverLeaksOwnership
	// in internal/repository/devices_integration_test.go.
	for _, call := range store.backfillFollowsCalls {
		if call.userID.String() == sessionB.UserID && call.deviceID.String() != testDeviceID {
			t.Errorf("unexpected backfill call for B against a different device: %+v", call)
		}
	}
}

// TestAuthService_UnlinkDevice_StillLinkedDeviceKeepsRejectingOtherAccount
// proves the 409 conflict check itself is untouched: a device that is
// still linked (no logout/unlink happened) keeps rejecting a different
// account's login, exactly as before this change.
func TestAuthService_UnlinkDevice_StillLinkedDeviceKeepsRejectingOtherAccount(t *testing.T) {
	store := newFakeAuthStore()
	sms := &fakeSms{}
	svc := newTestAuthService(t, store, sms, time.Now)

	_ = svc.RequestOTP(context.Background(), "5321112233")
	if _, err := svc.VerifyOTP(context.Background(), "5321112233", sms.sent[0].code, testDeviceID); err != nil {
		t.Fatalf("A verify: %v", err)
	}

	// no unlink/logout happened — B's login attempt on the same device
	// must still be rejected.
	_ = svc.RequestOTP(context.Background(), "5339998877")
	if _, err := svc.VerifyOTP(context.Background(), "5339998877", sms.sent[len(sms.sent)-1].code, testDeviceID); !errors.Is(err, service.ErrDeviceLinkedToOtherAccount) {
		t.Errorf("expected ErrDeviceLinkedToOtherAccount for a still-linked device, got %v", err)
	}
}

// fakeExternalOTPProvider is an in-process OTPVerificationProvider stub
// (issue #59): it records every start/check call and answers with the
// configured errors.
type fakeExternalOTPProvider struct {
	startCalls []string
	checkCalls []struct{ phone, code string }
	startErr   error
	checkErr   error
}

func (f *fakeExternalOTPProvider) StartVerification(_ context.Context, phone string) error {
	f.startCalls = append(f.startCalls, phone)
	return f.startErr
}

func (f *fakeExternalOTPProvider) CheckVerification(_ context.Context, phone, code string) error {
	f.checkCalls = append(f.checkCalls, struct{ phone, code string }{phone, code})
	return f.checkErr
}

// panicSms fails the test if the local delivery path is ever reached while
// an external provider is configured — the "never falls back to fake"
// proof issue #59 requires.
type panicSms struct{ t *testing.T }

func (p *panicSms) Send(context.Context, string, string) error {
	p.t.Fatal("SmsSender must never be called when an external otp provider is configured")
	return nil
}

func newTestExternalAuthService(t *testing.T, store *fakeAuthStore, external service.OTPVerificationProvider) *service.AuthService {
	t.Helper()
	sessions := service.NewSessionService(newFakeSessionStore(), []byte("k"), time.Hour, 24*time.Hour)
	return service.NewAuthService(store, &panicSms{t: t}, sessions, 5*time.Minute, 5, time.Minute, service.WithExternalOTPProvider(external))
}

// TestNewAuthService_NilSmsWithoutExternalPanics proves the documented
// invariant is enforced at construction time (pr #86 review): a nil
// SmsSender is only legal alongside WithExternalOTPProvider.
func TestNewAuthService_NilSmsWithoutExternalPanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("expected NewAuthService to panic for nil sms without an external provider")
		}
	}()
	sessions := service.NewSessionService(newFakeSessionStore(), []byte("k"), time.Hour, 24*time.Hour)
	service.NewAuthService(newFakeAuthStore(), nil, sessions, 5*time.Minute, 5, time.Minute)
}

func TestAuthService_External_RequestOTP_StartsVerification(t *testing.T) {
	store := newFakeAuthStore()
	external := &fakeExternalOTPProvider{}
	svc := newTestExternalAuthService(t, store, external)

	if err := svc.RequestOTP(context.Background(), "532 111 22 33"); err != nil {
		t.Fatalf("request otp: %v", err)
	}
	if len(external.startCalls) != 1 || external.startCalls[0] != "+905321112233" {
		t.Errorf("expected one start call with the normalized phone, got %v", external.startCalls)
	}
	if len(store.otpCodes) != 0 {
		t.Error("expected no local otp_codes row when the provider owns the code")
	}
}

func TestAuthService_External_RequestOTP_InvalidPhoneNeverReachesProvider(t *testing.T) {
	external := &fakeExternalOTPProvider{}
	svc := newTestExternalAuthService(t, newFakeAuthStore(), external)

	if err := svc.RequestOTP(context.Background(), "not-a-phone"); !errors.Is(err, service.ErrInvalidPhone) {
		t.Fatalf("expected ErrInvalidPhone, got %v", err)
	}
	if len(external.startCalls) != 0 {
		t.Error("expected no provider call for a malformed phone")
	}
}

func TestAuthService_External_RequestOTP_ProviderErrorPropagates(t *testing.T) {
	external := &fakeExternalOTPProvider{startErr: service.ErrOTPResendTooSoon}
	svc := newTestExternalAuthService(t, newFakeAuthStore(), external)

	if err := svc.RequestOTP(context.Background(), "5321112233"); !errors.Is(err, service.ErrOTPResendTooSoon) {
		t.Errorf("expected the provider's mapped error, got %v", err)
	}
}

func TestAuthService_External_VerifyOTP_SuccessIssuesSession(t *testing.T) {
	store := newFakeAuthStore()
	external := &fakeExternalOTPProvider{}
	svc := newTestExternalAuthService(t, store, external)

	session, err := svc.VerifyOTP(context.Background(), "5321112233", "123456", testDeviceID)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if len(external.checkCalls) != 1 || external.checkCalls[0].phone != "+905321112233" || external.checkCalls[0].code != "123456" {
		t.Errorf("expected one check call with normalized phone and code, got %v", external.checkCalls)
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
}

func TestAuthService_External_VerifyOTP_ReturningAccount(t *testing.T) {
	store := newFakeAuthStore()
	external := &fakeExternalOTPProvider{}
	svc := newTestExternalAuthService(t, store, external)

	first, err := svc.VerifyOTP(context.Background(), "5321112233", "123456", testDeviceID)
	if err != nil {
		t.Fatalf("first verify: %v", err)
	}
	second, err := svc.VerifyOTP(context.Background(), "5321112233", "654321", "33333333-3333-4333-8333-333333333333")
	if err != nil {
		t.Fatalf("second verify: %v", err)
	}
	if first.UserID != second.UserID {
		t.Errorf("expected the same account for the same phone, got %s vs %s", first.UserID, second.UserID)
	}
	if second.IsNewAccount {
		t.Error("expected the returning-account verify to report IsNewAccount false")
	}
}

// TestAuthService_External_VerifyOTP_RejectionNeverFallsBack seeds a local
// otp_codes row that WOULD verify through the local flow, then has the
// provider reject the code — the rejection must stand. A configured
// external provider is authoritative; there is no path back onto the local
// code table (issue #59).
func TestAuthService_External_VerifyOTP_RejectionNeverFallsBack(t *testing.T) {
	store := newFakeAuthStore()
	now := time.Now()
	if _, err := store.CreateOtpCode(context.Background(), repository.CreateOtpCodeParams{
		ID:          pgtype.UUID{Bytes: uuid.New(), Valid: true},
		Phone:       "+905321112233",
		CodeHash:    service.HashOTPCode("+905321112233", "123456"),
		MaxAttempts: 5,
		ExpiresAt:   pgtype.Timestamptz{Time: now.Add(5 * time.Minute), Valid: true},
	}); err != nil {
		t.Fatalf("seed otp code: %v", err)
	}

	external := &fakeExternalOTPProvider{checkErr: service.ErrOTPCodeMismatch}
	svc := newTestExternalAuthService(t, store, external)

	if _, err := svc.VerifyOTP(context.Background(), "5321112233", "123456", testDeviceID); !errors.Is(err, service.ErrOTPCodeMismatch) {
		t.Fatalf("expected the provider's rejection to stand, got %v", err)
	}
	if len(store.usersByPhone) != 0 {
		t.Error("expected no account to be created on a rejected verification")
	}
	if row := store.otpCodes["+905321112233"]; row.ConsumedAt.Valid || row.Attempts != 0 {
		t.Error("expected the local otp_codes row to be untouched by the external path")
	}
}

func TestAuthService_External_VerifyOTP_ProviderUnavailablePropagates(t *testing.T) {
	external := &fakeExternalOTPProvider{checkErr: service.ErrOTPProviderUnavailable}
	svc := newTestExternalAuthService(t, newFakeAuthStore(), external)

	if _, err := svc.VerifyOTP(context.Background(), "5321112233", "123456", testDeviceID); !errors.Is(err, service.ErrOTPProviderUnavailable) {
		t.Errorf("expected ErrOTPProviderUnavailable, got %v", err)
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
