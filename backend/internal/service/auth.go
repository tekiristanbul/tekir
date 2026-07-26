package service

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// ErrOTPResendTooSoon means a code was already requested for this phone
// number more recently than the configured resend cooldown.
var ErrOTPResendTooSoon = errors.New("otp resend too soon")

// ErrOTPNotRequested means no otp code has ever been requested for this
// phone number.
var ErrOTPNotRequested = errors.New("otp not requested")

// ErrOTPExpired means the most recently issued code for this phone number
// has passed its expiry.
var ErrOTPExpired = errors.New("otp expired")

// ErrOTPAlreadyConsumed means the most recently issued code has already
// been used to verify successfully once — replaying it is rejected.
var ErrOTPAlreadyConsumed = errors.New("otp already consumed")

// ErrOTPTooManyAttempts means the most recently issued code has already
// been guessed against more times than its attempt limit allows.
var ErrOTPTooManyAttempts = errors.New("otp too many attempts")

// ErrOTPCodeMismatch means the presented code doesn't match the most
// recently issued (unexpired, unconsumed, not-yet-exhausted) code.
var ErrOTPCodeMismatch = errors.New("otp code mismatch")

// ErrDeviceLinkedToOtherAccount means the presented device is already
// linked to a different account than the one this verification resolved
// to. A device is linked to at most one account, ever — see
// docs/architecture/db.md's devices.user_id design note.
var ErrDeviceLinkedToOtherAccount = errors.New("device linked to a different account")

// ErrInvalidDisplayName means a presented display name is empty (after
// trimming) or exceeds maxDisplayNameLength.
var ErrInvalidDisplayName = errors.New("invalid display name")

// otpCodeDigits is the length of a generated otp code, matching the
// prototype login screen's 6-character code input (prototype/app.js).
const otpCodeDigits = 6

// maxDisplayNameLength bounds the new-account minimum-profile display name
// (issue #58) — generous for a person's name while still bounding storage
// and rendering cost.
const maxDisplayNameLength = 60

// AuthStore is satisfied by repository.Store; kept as an interface so
// AuthService stays testable without a real database connection.
type AuthStore interface {
	CreateOtpCode(ctx context.Context, arg repository.CreateOtpCodeParams) (repository.CreateOtpCodeRow, error)
	GetLatestOtpCode(ctx context.Context, phone string) (repository.OtpCode, error)
	IncrementOtpAttempts(ctx context.Context, id pgtype.UUID) error
	ConsumeOtpCode(ctx context.Context, arg repository.ConsumeOtpCodeParams) error

	GetUserByPhone(ctx context.Context, phone string) (repository.User, error)
	CreateUser(ctx context.Context, arg repository.CreateUserParams) (repository.User, error)
	UpdateUserDisplayName(ctx context.Context, arg repository.UpdateUserDisplayNameParams) error

	GetDeviceByID(ctx context.Context, id pgtype.UUID) (repository.GetDeviceByIDRow, error)
	LinkDeviceToUser(ctx context.Context, arg repository.LinkDeviceToUserParams) error
}

// AuthService implements issue #58's phone-otp authentication: requesting
// and verifying a one-time code, resolving-or-creating exactly one account
// per normalized phone number, and idempotently linking the verifying
// device to that account. Session issuance itself is delegated to
// SessionService so JWT/refresh-token concerns stay separate and
// independently testable.
type AuthService struct {
	db             AuthStore
	sms            SmsSender
	sessions       *SessionService
	otpTTL         time.Duration
	otpMaxAttempts int32
	resendCooldown time.Duration
	clock          func() time.Time
}

// AuthServiceOption configures optional AuthService behavior.
type AuthServiceOption func(*AuthService)

// WithAuthClock overrides the clock used for otp expiry/cooldown
// comparisons, so tests can construct exact expiry-boundary scenarios
// deterministically.
func WithAuthClock(clock func() time.Time) AuthServiceOption {
	return func(s *AuthService) { s.clock = clock }
}

func NewAuthService(db AuthStore, sms SmsSender, sessions *SessionService, otpTTL time.Duration, otpMaxAttempts int32, resendCooldown time.Duration, opts ...AuthServiceOption) *AuthService {
	s := &AuthService{
		db:             db,
		sms:            sms,
		sessions:       sessions,
		otpTTL:         otpTTL,
		otpMaxAttempts: otpMaxAttempts,
		resendCooldown: resendCooldown,
		clock:          time.Now,
	}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

// RequestOTP normalizes phone, generates and stores a new one-time code,
// and asks the SmsSender to deliver it. A resend cooldown against the most
// recently issued code for the same number is enforced here — this is the
// per-phone "attempt limit" issue #58 requires for otp request cadence,
// distinct from the per-code guess-attempt limit VerifyOTP enforces.
func (s *AuthService) RequestOTP(ctx context.Context, rawPhone string) error {
	phone, err := NormalizePhone(rawPhone)
	if err != nil {
		return err
	}

	latest, err := s.db.GetLatestOtpCode(ctx, phone)
	switch {
	case err == nil:
		if s.clock().Sub(latest.CreatedAt.Time) < s.resendCooldown {
			return ErrOTPResendTooSoon
		}
	case errors.Is(err, pgx.ErrNoRows):
		// no prior code for this number — nothing to cool down against.
	default:
		return err
	}

	code, err := generateOTPCode()
	if err != nil {
		return err
	}

	now := s.clock()
	if _, err := s.db.CreateOtpCode(ctx, repository.CreateOtpCodeParams{
		ID:          pgtype.UUID{Bytes: uuid.New(), Valid: true},
		Phone:       phone,
		CodeHash:    HashOTPCode(phone, code),
		MaxAttempts: s.otpMaxAttempts,
		ExpiresAt:   pgtype.Timestamptz{Time: now.Add(s.otpTTL), Valid: true},
	}); err != nil {
		return err
	}

	return s.sms.Send(ctx, phone, code)
}

// VerifyOTP checks the presented phone+code against the most recently
// issued otp_codes row, resolves-or-creates exactly one account for the
// normalized phone, idempotently links deviceID to that account, and
// issues a new session. deviceID always comes from the caller's resolved
// X-Device-Token (see handler.RequireDeviceToken) — never client-supplied.
func (s *AuthService) VerifyOTP(ctx context.Context, rawPhone, code, deviceID string) (Session, error) {
	phone, err := NormalizePhone(rawPhone)
	if err != nil {
		return Session{}, err
	}
	did, err := uuid.Parse(deviceID)
	if err != nil {
		return Session{}, err
	}

	row, err := s.db.GetLatestOtpCode(ctx, phone)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Session{}, ErrOTPNotRequested
		}
		return Session{}, err
	}

	now := s.clock()
	switch {
	case row.ConsumedAt.Valid:
		return Session{}, ErrOTPAlreadyConsumed
	case !row.ExpiresAt.Time.After(now):
		return Session{}, ErrOTPExpired
	case row.Attempts >= row.MaxAttempts:
		return Session{}, ErrOTPTooManyAttempts
	}

	if HashOTPCode(phone, code) != row.CodeHash {
		if err := s.db.IncrementOtpAttempts(ctx, row.ID); err != nil {
			return Session{}, err
		}
		return Session{}, ErrOTPCodeMismatch
	}

	if err := s.db.ConsumeOtpCode(ctx, repository.ConsumeOtpCodeParams{
		ID:         row.ID,
		ConsumedAt: pgtype.Timestamptz{Time: now, Valid: true},
	}); err != nil {
		return Session{}, err
	}

	user, isNew, err := s.resolveOrCreateUser(ctx, phone, now)
	if err != nil {
		return Session{}, err
	}

	if err := s.linkDevice(ctx, did, uuid.UUID(user.ID.Bytes)); err != nil {
		return Session{}, err
	}

	session, err := s.sessions.Issue(ctx, uuid.UUID(user.ID.Bytes))
	if err != nil {
		return Session{}, err
	}
	session.IsNewAccount = isNew
	return session, nil
}

// resolveOrCreateUser returns the existing account for phone, or creates
// one, alongside whether it was just created. users.phone's unique
// constraint is what makes this resolve to exactly one account even when
// two verify requests for the same number race: the losing insert hits
// the constraint and this falls back to a lookup (isNew false) rather
// than erroring.
func (s *AuthService) resolveOrCreateUser(ctx context.Context, phone string, now time.Time) (repository.User, bool, error) {
	existing, err := s.db.GetUserByPhone(ctx, phone)
	if err == nil {
		return existing, false, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return repository.User{}, false, err
	}

	created, err := s.db.CreateUser(ctx, repository.CreateUserParams{
		ID:              pgtype.UUID{Bytes: uuid.New(), Valid: true},
		Phone:           phone,
		PhoneVerifiedAt: pgtype.Timestamptz{Time: now, Valid: true},
	})
	if err != nil {
		if isUniqueViolation(err) {
			existing, err := s.db.GetUserByPhone(ctx, phone)
			return existing, false, err
		}
		return repository.User{}, false, err
	}
	return created, true, nil
}

// SetDisplayName sets a newly-created account's minimum-profile display
// name (issue #58's prototype-matching "Görünen adını seç" step). Callers
// only invoke this for an account VerifyOTP just reported as new
// (Session.IsNewAccount) — re-setting it for a returning account is not
// prevented here (no uniqueness or one-time constraint on the column
// itself), that's a client-flow convention, not a server invariant.
func (s *AuthService) SetDisplayName(ctx context.Context, userID, displayName string) error {
	name := strings.TrimSpace(displayName)
	if name == "" || len(name) > maxDisplayNameLength {
		return ErrInvalidDisplayName
	}

	uid, err := uuid.Parse(userID)
	if err != nil {
		return ErrInvalidDisplayName
	}

	return s.db.UpdateUserDisplayName(ctx, repository.UpdateUserDisplayNameParams{
		ID:          pgtype.UUID{Bytes: uid, Valid: true},
		DisplayName: pgtype.Text{String: name, Valid: true},
	})
}

// linkDevice idempotently links deviceID to userID. Linking a device
// already linked to this same account is a no-op (including under
// concurrent retries — see LinkDeviceToUser's own idempotency). Linking a
// device already linked to a *different* account is rejected rather than
// silently reassigning it, so a device's prior authored content
// (cats.created_by_device_id / updates.author_device_id, both keyed by
// device_id) is never retroactively re-attributed to a second account.
func (s *AuthService) linkDevice(ctx context.Context, deviceID, userID uuid.UUID) error {
	device, err := s.db.GetDeviceByID(ctx, pgtype.UUID{Bytes: deviceID, Valid: true})
	if err != nil {
		return err
	}
	if device.UserID.Valid {
		if uuid.UUID(device.UserID.Bytes) == userID {
			return nil
		}
		return ErrDeviceLinkedToOtherAccount
	}
	return s.db.LinkDeviceToUser(ctx, repository.LinkDeviceToUserParams{
		ID:     pgtype.UUID{Bytes: deviceID, Valid: true},
		UserID: pgtype.UUID{Bytes: userID, Valid: true},
	})
}

// generateOTPCode returns a cryptographically random otpCodeDigits-digit
// numeric string (e.g. "042917"), including a possible leading zero.
func generateOTPCode() (string, error) {
	max := 1
	for range otpCodeDigits {
		max *= 10
	}

	b := make([]byte, 4)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	n := (uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])) % uint32(max)
	return fmt.Sprintf("%0*d", otpCodeDigits, n), nil
}

// HashOTPCode returns the lower-hex sha-256 hash of a code bound to its
// phone number, so the same digit string never hashes identically across
// two different phone numbers. This is the only value stored in
// otp_codes.code_hash; the plaintext code is never persisted.
func HashOTPCode(phone, code string) string {
	sum := sha256.Sum256([]byte(phone + ":" + code))
	return hex.EncodeToString(sum[:])
}

// isUniqueViolation reports whether err is a postgres unique-constraint
// violation (sqlstate 23505) — used to detect the losing side of a
// concurrent CreateUser race on users.phone.
func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}
