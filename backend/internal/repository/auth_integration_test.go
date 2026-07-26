package repository_test

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// requires a real, migrated database: run `make migrate-up` against the
// docker-compose postgres first, or let CI's postgres service do it.
// reuses newTestStore/createTestDevice/upsertTestCat from
// updates_integration_test.go / follows_integration_test.go.

// newAuthService wires a real-store-backed AuthService with an injected
// clock, mirroring the unit tests' fake-clock convention (issue #58) so
// otp expiry/cooldown behavior stays deterministic even against postgres.
// Wires the same TxRunner production uses (see cmd/api/main.go), so these
// integration tests exercise the real atomic-consume-plus-transaction
// path, not just the non-transactional fallback unit tests use.
func newAuthService(store *repository.Store, sms service.SmsSender, clock func() time.Time) *service.AuthService {
	sessions := service.NewSessionService(store, []byte("integration-test-key"), time.Hour, 24*time.Hour, service.WithSessionClock(clock), service.WithSessionTxRunner(store))
	return service.NewAuthService(store, sms, sessions, 5*time.Minute, 5, time.Minute, service.WithAuthClock(clock), service.WithAuthTxRunner(store))
}

type recordingSms struct {
	mu   sync.Mutex
	last map[string]string
}

func newRecordingSms() *recordingSms { return &recordingSms{last: map[string]string{}} }

func (r *recordingSms) Send(_ context.Context, phone, code string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.last[phone] = code
	return nil
}

func (r *recordingSms) codeFor(phone string) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.last[phone]
}

var testPhoneCounter int64

// testDigits returns 7 unique decimal digits for building a test phone
// number's subscriber-number tail — a uuid substring can't be used
// directly here, since its hex digits include a-f, which NormalizePhone
// strips as non-numeric.
func testDigits(t *testing.T) string {
	t.Helper()
	n := atomic.AddInt64(&testPhoneCounter, 1)
	v := (time.Now().UnixNano() + n) % 10000000
	if v < 0 {
		v = -v
	}
	return fmt.Sprintf("%07d", v)
}

func TestStore_CreateUser_UniquePhoneConstraint(t *testing.T) {
	store := newTestStore(t)
	phone := "+90555" + testDigits(t)

	if _, err := store.CreateUser(context.Background(), repository.CreateUserParams{
		ID:              pgtype.UUID{Bytes: uuid.New(), Valid: true},
		Phone:           phone,
		PhoneVerifiedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}); err != nil {
		t.Fatalf("first create: %v", err)
	}

	_, err := store.CreateUser(context.Background(), repository.CreateUserParams{
		ID:              pgtype.UUID{Bytes: uuid.New(), Valid: true},
		Phone:           phone,
		PhoneVerifiedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	})
	if err == nil {
		t.Fatal("expected unique constraint violation on duplicate phone, got nil")
	}
}

// TestAuthService_VerifyOTP_ConcurrentSamePhone_ResolvesToOneAccount races
// two verifications for the same phone number and code (two different
// devices) against a real database, asserting the atomic
// ConsumeOtpCodeIfValid compare-and-set (code review fix, issue #58)
// guarantees exactly one wins — never both, never zero — rather than
// racing into two sessions from one code. A start-gate channel maximizes
// the chance the two goroutines' VerifyOTP calls genuinely overlap, so
// this test would have been flaky-but-failing against the pre-fix
// read-then-unconditional-update implementation rather than passing by
// scheduling luck.
func TestAuthService_VerifyOTP_ConcurrentSamePhone_ResolvesToOneAccount(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	sms := newRecordingSms()
	now := time.Now()
	svc := newAuthService(store, sms, func() time.Time { return now })

	phone := "555" + testDigits(t)
	deviceA := createTestDevice(t, ctx, store)
	deviceB := createTestDevice(t, ctx, store)

	if err := svc.RequestOTP(ctx, phone); err != nil {
		t.Fatalf("request otp: %v", err)
	}
	code := sms.codeFor("+90" + phone)

	const rounds = 20
	for round := 0; round < rounds; round++ {
		if round > 0 {
			// Each round after the first needs a fresh code: the previous
			// round's winner already consumed the last one.
			now = now.Add(2 * time.Minute) // past the otp resend cooldown
			if err := svc.RequestOTP(ctx, phone); err != nil {
				t.Fatalf("round %d: request otp: %v", round, err)
			}
			code = sms.codeFor("+90" + phone)
		}

		start := make(chan struct{})
		var wg sync.WaitGroup
		results := make([]service.Session, 2)
		errs := make([]error, 2)
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			results[0], errs[0] = svc.VerifyOTP(ctx, phone, code, uuid.UUID(deviceA.Bytes).String())
		}()
		go func() {
			defer wg.Done()
			<-start
			results[1], errs[1] = svc.VerifyOTP(ctx, phone, code, uuid.UUID(deviceB.Bytes).String())
		}()
		close(start)
		wg.Wait()

		// exactly one of the two concurrent verifications may consume the
		// single-use code; the other must fail with a well-defined otp
		// error, never a corrupted/duplicate account.
		successes := 0
		var winner service.Session
		for i, err := range errs {
			if err == nil {
				successes++
				winner = results[i]
			} else if !errors.Is(err, service.ErrOTPAlreadyConsumed) && !errors.Is(err, service.ErrOTPCodeMismatch) {
				t.Errorf("round %d: unexpected error from concurrent verify: %v", round, err)
			}
		}
		if successes != 1 {
			t.Fatalf("round %d: expected exactly 1 successful verify out of 2 concurrent attempts, got %d", round, successes)
		}

		user, err := store.GetUserByPhone(ctx, "+90"+phone)
		if err != nil {
			t.Fatalf("round %d: get user by phone: %v", round, err)
		}
		if uuid.UUID(user.ID.Bytes).String() != winner.UserID {
			t.Errorf("round %d: expected exactly one account to exist for the phone number", round)
		}
	}
}

// TestSessionService_Refresh_ConcurrentSameToken races two refresh calls
// presenting the exact same refresh token against a real database,
// asserting the atomic RevokeRefreshTokenIfActive compare-and-set (code
// review fix, issue #58) guarantees exactly one wins — never both minting
// a replacement session from a single token.
func TestSessionService_Refresh_ConcurrentSameToken(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	svc := service.NewSessionService(store, []byte("integration-test-key"), time.Hour, 24*time.Hour, service.WithSessionTxRunner(store))

	userID := uuid.New()
	if _, err := store.CreateUser(ctx, repository.CreateUserParams{
		ID:              pgtype.UUID{Bytes: userID, Valid: true},
		Phone:           "+90555" + testDigits(t),
		PhoneVerifiedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}); err != nil {
		t.Fatalf("seed user: %v", err)
	}

	session, err := svc.Issue(ctx, userID)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}

	start := make(chan struct{})
	var wg sync.WaitGroup
	results := make([]service.Session, 2)
	errs := make([]error, 2)
	wg.Add(2)
	go func() {
		defer wg.Done()
		<-start
		results[0], errs[0] = svc.Refresh(ctx, session.RefreshToken)
	}()
	go func() {
		defer wg.Done()
		<-start
		results[1], errs[1] = svc.Refresh(ctx, session.RefreshToken)
	}()
	close(start)
	wg.Wait()

	successes := 0
	var winner service.Session
	for i, err := range errs {
		if err == nil {
			successes++
			winner = results[i]
		} else if !errors.Is(err, service.ErrSessionRevoked) {
			t.Errorf("unexpected error from concurrent refresh: %v", err)
		}
	}
	if successes != 1 {
		t.Fatalf("expected exactly 1 successful refresh out of 2 concurrent attempts, got %d", successes)
	}
	if winner.UserID != userID.String() {
		t.Error("expected the replacement session to belong to the same account")
	}
}

// TestAuthService_VerifyOTP_FailedLinkDoesNotBurnTheCode proves the
// transactional wrapping (code review fix, issue #58): when a downstream
// step (device linking) fails after the otp was atomically consumed, the
// whole transaction — including that consumption — rolls back, so the
// code remains valid for a legitimate retry rather than being wasted.
func TestAuthService_VerifyOTP_FailedLinkDoesNotBurnTheCode(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	sms := newRecordingSms()
	now := time.Now()
	svc := newAuthService(store, sms, func() time.Time { return now })

	// device is already linked to a different account, so verifying phone
	// on this device will fail at the linkDevice step, after the otp
	// consume has already run inside the same transaction.
	linkedDevice := createTestDevice(t, ctx, store)
	otherPhone := "555" + testDigits(t)
	if err := svc.RequestOTP(ctx, otherPhone); err != nil {
		t.Fatalf("request otp (other account): %v", err)
	}
	if _, err := svc.VerifyOTP(ctx, otherPhone, sms.codeFor("+90"+otherPhone), uuid.UUID(linkedDevice.Bytes).String()); err != nil {
		t.Fatalf("verify otp (other account): %v", err)
	}

	phone := "555" + testDigits(t)
	if err := svc.RequestOTP(ctx, phone); err != nil {
		t.Fatalf("request otp: %v", err)
	}
	code := sms.codeFor("+90" + phone)

	_, err := svc.VerifyOTP(ctx, phone, code, uuid.UUID(linkedDevice.Bytes).String())
	if !errors.Is(err, service.ErrDeviceLinkedToOtherAccount) {
		t.Fatalf("expected ErrDeviceLinkedToOtherAccount, got %v", err)
	}

	// the transaction must have rolled back the otp consumption along with
	// everything else — a fresh device presenting the same code now
	// succeeds, proving the code was never actually spent.
	freshDevice := createTestDevice(t, ctx, store)
	session, err := svc.VerifyOTP(ctx, phone, code, uuid.UUID(freshDevice.Bytes).String())
	if err != nil {
		t.Fatalf("expected the otp to still be valid after the failed link, got: %v", err)
	}
	if !session.IsNewAccount {
		t.Error("expected a new account for the previously-unverified phone")
	}
}

// TestAuthService_VerifyOTP_PreservesDeviceOwnedContentAfterLinking is the
// explicit, tested ownership outcome issue #58 requires: a device that
// already follows a cat and has authored an update keeps both, unchanged,
// after its otp verification links it to an account. Ownership is a
// derived join (device_id -> devices.user_id), never a rewritten id, so
// neither the follows row nor the update's author_device_id is touched by
// linking.
func TestAuthService_VerifyOTP_PreservesDeviceOwnedContentAfterLinking(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	deviceID := createTestDevice(t, ctx, store)
	catID := upsertTestCat(t, ctx, store, "auth-test-cat")

	update, err := store.CreateOrdinaryUpdate(ctx, repository.CreateOrdinaryUpdateParams{
		ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
		CatID:          catID,
		AuthorDeviceID: deviceID,
		CreatedAt:      pgtype.Timestamptz{Time: time.Now(), Valid: true},
		Statuses:       []string{"seen"},
	})
	if err != nil {
		t.Fatalf("seed authored update: %v", err)
	}

	if err := store.CreateFollow(ctx, repository.CreateFollowParams{DeviceID: deviceID, CatID: catID}); err != nil {
		t.Fatalf("seed follow: %v", err)
	}

	// now verify otp for this device, linking it to a fresh account.
	sms := newRecordingSms()
	now := time.Now()
	svc := newAuthService(store, sms, func() time.Time { return now })
	phone := "555" + testDigits(t)
	if err := svc.RequestOTP(ctx, phone); err != nil {
		t.Fatalf("request otp: %v", err)
	}
	session, err := svc.VerifyOTP(ctx, phone, sms.codeFor("+90"+phone), uuid.UUID(deviceID.Bytes).String())
	if err != nil {
		t.Fatalf("verify otp: %v", err)
	}

	// the follow must still exist, scoped to this device.
	cats, err := store.ListFollowedCats(ctx, deviceID)
	if err != nil {
		t.Fatalf("list followed cats: %v", err)
	}
	found := false
	for _, c := range cats {
		if c.ID == catID {
			found = true
		}
	}
	if !found {
		t.Error("expected the device's pre-linking follow to survive account linking")
	}

	// the authored update's attribution must be unchanged — verified with
	// a raw query since author_device_id is never selected back to a
	// client (see docs/architecture/api.md).
	dsn := os.Getenv("DATABASE_URL")
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("connect for raw verification: %v", err)
	}
	defer pool.Close()

	var authorDeviceID pgtype.UUID
	if err := pool.QueryRow(ctx, `select author_device_id from updates where id = $1`, update.ID).Scan(&authorDeviceID); err != nil {
		t.Fatalf("read back update: %v", err)
	}
	if authorDeviceID != deviceID {
		t.Error("expected the update's author_device_id to remain the originating device after linking")
	}

	// and the device is now linked to exactly the account VerifyOTP issued.
	deviceRow, err := store.GetDeviceByID(ctx, deviceID)
	if err != nil {
		t.Fatalf("get device: %v", err)
	}
	if !deviceRow.UserID.Valid || uuid.UUID(deviceRow.UserID.Bytes).String() != session.UserID {
		t.Error("expected device.user_id to equal the issued session's user id")
	}
}

func TestAuthService_VerifyOTP_DeviceLinkedToDifferentAccount_Integration(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	sms := newRecordingSms()
	now := time.Now()
	svc := newAuthService(store, sms, func() time.Time { return now })

	deviceID := createTestDevice(t, ctx, store)

	phoneA := "555" + testDigits(t)
	if err := svc.RequestOTP(ctx, phoneA); err != nil {
		t.Fatalf("request otp a: %v", err)
	}
	if _, err := svc.VerifyOTP(ctx, phoneA, sms.codeFor("+90"+phoneA), uuid.UUID(deviceID.Bytes).String()); err != nil {
		t.Fatalf("verify a: %v", err)
	}

	phoneB := "555" + testDigits(t)
	if err := svc.RequestOTP(ctx, phoneB); err != nil {
		t.Fatalf("request otp b: %v", err)
	}
	_, err := svc.VerifyOTP(ctx, phoneB, sms.codeFor("+90"+phoneB), uuid.UUID(deviceID.Bytes).String())
	if !errors.Is(err, service.ErrDeviceLinkedToOtherAccount) {
		t.Errorf("expected ErrDeviceLinkedToOtherAccount, got %v", err)
	}
}

func TestAuthService_SetDisplayName_Integration(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	sms := newRecordingSms()
	now := time.Now()
	svc := newAuthService(store, sms, func() time.Time { return now })

	deviceID := createTestDevice(t, ctx, store)
	phone := "555" + testDigits(t)
	if err := svc.RequestOTP(ctx, phone); err != nil {
		t.Fatalf("request otp: %v", err)
	}
	session, err := svc.VerifyOTP(ctx, phone, sms.codeFor("+90"+phone), uuid.UUID(deviceID.Bytes).String())
	if err != nil {
		t.Fatalf("verify otp: %v", err)
	}
	if !session.IsNewAccount {
		t.Fatal("expected a brand-new account")
	}

	if err := svc.SetDisplayName(ctx, session.UserID, "Ayşe"); err != nil {
		t.Fatalf("set display name: %v", err)
	}

	user, err := store.GetUserByID(ctx, pgtype.UUID{Bytes: uuid.MustParse(session.UserID), Valid: true})
	if err != nil {
		t.Fatalf("get user: %v", err)
	}
	if !user.DisplayName.Valid || user.DisplayName.String != "Ayşe" {
		t.Errorf("expected persisted display name %q, got %+v", "Ayşe", user.DisplayName)
	}
}

func TestSessionService_RefreshAndRevoke_Integration(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	svc := service.NewSessionService(store, []byte("integration-test-key"), time.Hour, 24*time.Hour)

	userID := uuid.New()
	// a refresh token references users(id), so seed a real account first.
	if _, err := store.CreateUser(ctx, repository.CreateUserParams{
		ID:              pgtype.UUID{Bytes: userID, Valid: true},
		Phone:           "+90555" + testDigits(t),
		PhoneVerifiedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}); err != nil {
		t.Fatalf("seed user: %v", err)
	}

	session, err := svc.Issue(ctx, userID)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}

	rotated, err := svc.Refresh(ctx, session.RefreshToken)
	if err != nil {
		t.Fatalf("refresh: %v", err)
	}
	if rotated.RefreshToken == session.RefreshToken {
		t.Error("expected a rotated refresh token")
	}

	if _, err := svc.Refresh(ctx, session.RefreshToken); !errors.Is(err, service.ErrSessionRevoked) {
		t.Errorf("expected ErrSessionRevoked replaying the original token, got %v", err)
	}

	if err := svc.Revoke(ctx, rotated.RefreshToken); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	if _, err := svc.Refresh(ctx, rotated.RefreshToken); !errors.Is(err, service.ErrSessionRevoked) {
		t.Errorf("expected ErrSessionRevoked after logout, got %v", err)
	}
}
