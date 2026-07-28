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

// AuthStore is satisfied by repository.Store (and, transaction-scoped, by
// *repository.Queries — see TxRunner); kept as an interface so AuthService
// stays testable without a real database connection.
type AuthStore interface {
	CreateOtpCode(ctx context.Context, arg repository.CreateOtpCodeParams) (repository.CreateOtpCodeRow, error)
	GetLatestOtpCode(ctx context.Context, phone string) (repository.OtpCode, error)
	IncrementOtpAttempts(ctx context.Context, id pgtype.UUID) error
	ConsumeOtpCodeIfValid(ctx context.Context, arg repository.ConsumeOtpCodeIfValidParams) (pgtype.UUID, error)

	GetUserByPhone(ctx context.Context, phone string) (repository.User, error)
	CreateUser(ctx context.Context, arg repository.CreateUserParams) (repository.User, error)
	UpdateUserDisplayName(ctx context.Context, arg repository.UpdateUserDisplayNameParams) error

	GetDeviceByID(ctx context.Context, id pgtype.UUID) (repository.GetDeviceByIDRow, error)
	LinkDeviceToUser(ctx context.Context, arg repository.LinkDeviceToUserParams) error
	UnlinkDeviceFromUser(ctx context.Context, arg repository.UnlinkDeviceFromUserParams) error
	DeleteRedundantDeviceFollows(ctx context.Context, arg repository.DeleteRedundantDeviceFollowsParams) error
	BackfillFollowsUserID(ctx context.Context, arg repository.BackfillFollowsUserIDParams) error
	BackfillUpdatesAuthorUserID(ctx context.Context, arg repository.BackfillUpdatesAuthorUserIDParams) error
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
	external       OTPVerificationProvider
	sessions       *SessionService
	txRunner       TxRunner
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

// WithAuthTxRunner wires a TxRunner so VerifyOTP's otp consumption,
// account resolution, device linking, and session issuance commit or roll
// back together (code review fix, issue #58): a failure partway through
// never leaves an otp code permanently consumed with no session issued.
// Unset in unit tests, which exercise the non-transactional fallback with
// hand-rolled fakes instead.
func WithAuthTxRunner(tx TxRunner) AuthServiceOption {
	return func(s *AuthService) { s.txRunner = tx }
}

// WithExternalOTPProvider routes RequestOTP and VerifyOTP's code issuance
// and checking through an external verification provider (issue #59,
// twilio verify) instead of the local otp_codes flow. The provider owns
// code generation, delivery, expiry, resend cadence, and guess limiting
// end to end, so none of the local otp_codes machinery (cooldown check,
// code hashing, atomic consumption, attempt counting) runs — account
// resolution, device linking, and session issuance are unchanged and still
// commit atomically when a TxRunner is configured. With this option set,
// the SmsSender passed to NewAuthService is never called and may be nil;
// there is deliberately no code path from a failing external provider back
// onto the local/fake flow.
func WithExternalOTPProvider(p OTPVerificationProvider) AuthServiceOption {
	return func(s *AuthService) { s.external = p }
}

// NewAuthService builds the phone-otp auth service. sms may be nil only
// when WithExternalOTPProvider is also passed — the external provider then
// replaces the local generate-store-send flow entirely. That invariant is
// enforced here: a nil sms without an external provider panics at
// construction (wiring) time rather than surfacing later as a nil
// dereference on the first RequestOTP.
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
	if s.sms == nil && s.external == nil {
		panic("service: NewAuthService requires an SmsSender unless WithExternalOTPProvider is configured")
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

	if s.external != nil {
		// The provider owns generation, delivery, and resend cadence
		// (issue #59) — no otp_codes row is written and the local cooldown
		// doesn't apply; a provider-side send limit comes back as
		// ErrOTPResendTooSoon through the same error contract.
		return s.external.StartVerification(ctx, phone)
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
//
// Consuming the code is an atomic compare-and-set (ConsumeOtpCodeIfValid):
// two concurrent verifications presenting the same code can never both
// win, since only one commits before the other re-evaluates the same
// predicates and finds the code already spent (code review fix, issue
// #58) — the loser is rejected here, before ever reaching account
// resolution, device linking, or session issuance. When a TxRunner is
// configured, that consumption plus the downstream account/device/session
// writes all commit or roll back together, so a failure partway through
// never permanently burns the code with no session issued.
func (s *AuthService) VerifyOTP(ctx context.Context, rawPhone, code, deviceID string) (Session, error) {
	phone, err := NormalizePhone(rawPhone)
	if err != nil {
		return Session{}, err
	}
	did, err := uuid.Parse(deviceID)
	if err != nil {
		return Session{}, err
	}

	if s.external != nil {
		// The provider checked, expired, or attempt-limited the code
		// itself (issue #59) — a failure returns here with the mapped
		// error, never falling back onto the local otp_codes flow.
		if err := s.external.CheckVerification(ctx, phone, code); err != nil {
			return Session{}, err
		}
		return s.sessionForVerifiedPhone(ctx, phone, did, s.clock())
	}

	row, err := s.db.GetLatestOtpCode(ctx, phone)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Session{}, ErrOTPNotRequested
		}
		return Session{}, err
	}

	now := s.clock()
	// Pre-checks purely for a precise error message on the common paths —
	// the actual security boundary is the atomic compare-and-set below,
	// which re-validates all of this itself regardless of what this read
	// observed.
	switch {
	case row.ConsumedAt.Valid:
		return Session{}, ErrOTPAlreadyConsumed
	case !row.ExpiresAt.Time.After(now):
		return Session{}, ErrOTPExpired
	case row.Attempts >= row.MaxAttempts:
		return Session{}, ErrOTPTooManyAttempts
	}

	presentedHash := HashOTPCode(phone, code)
	if presentedHash != row.CodeHash {
		if err := s.db.IncrementOtpAttempts(ctx, row.ID); err != nil {
			return Session{}, err
		}
		return Session{}, ErrOTPCodeMismatch
	}

	consumeArgs := repository.ConsumeOtpCodeIfValidParams{
		ID:         row.ID,
		Phone:      phone,
		CodeHash:   presentedHash,
		ConsumedAt: pgtype.Timestamptz{Time: now, Valid: true},
		Now:        pgtype.Timestamptz{Time: now, Valid: true},
	}

	if s.txRunner != nil {
		var session Session
		err := s.txRunner.WithinTx(ctx, func(q *repository.Queries) error {
			if _, err := q.ConsumeOtpCodeIfValid(ctx, consumeArgs); err != nil {
				return err
			}
			user, isNew, err := s.resolveOrCreateUser(ctx, q, phone, now)
			if err != nil {
				return err
			}
			if err := s.linkDevice(ctx, q, did, uuid.UUID(user.ID.Bytes)); err != nil {
				return err
			}
			session, err = s.sessions.IssueTx(ctx, q, uuid.UUID(user.ID.Bytes))
			if err != nil {
				return err
			}
			session.IsNewAccount = isNew
			return nil
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return Session{}, ErrOTPAlreadyConsumed
			}
			return Session{}, err
		}
		return session, nil
	}

	if _, err := s.db.ConsumeOtpCodeIfValid(ctx, consumeArgs); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Session{}, ErrOTPAlreadyConsumed
		}
		return Session{}, err
	}

	user, isNew, err := s.resolveOrCreateUser(ctx, s.db, phone, now)
	if err != nil {
		return Session{}, err
	}

	if err := s.linkDevice(ctx, s.db, did, uuid.UUID(user.ID.Bytes)); err != nil {
		return Session{}, err
	}

	session, err := s.sessions.Issue(ctx, uuid.UUID(user.ID.Bytes))
	if err != nil {
		return Session{}, err
	}
	session.IsNewAccount = isNew
	return session, nil
}

// sessionForVerifiedPhone runs VerifyOTP's post-verification tail for the
// external-provider path (issue #59): resolve-or-create the account for an
// already-verified phone, link the device, and issue a session — all in
// one transaction when a TxRunner is configured, exactly like the local
// path. It has no consumption step of its own because the provider already
// consumed the verification atomically on its side; the local path keeps
// its ConsumeOtpCodeIfValid inside its own transaction and doesn't reuse
// this helper for that reason.
func (s *AuthService) sessionForVerifiedPhone(ctx context.Context, phone string, did uuid.UUID, now time.Time) (Session, error) {
	if s.txRunner != nil {
		var session Session
		err := s.txRunner.WithinTx(ctx, func(q *repository.Queries) error {
			user, isNew, err := s.resolveOrCreateUser(ctx, q, phone, now)
			if err != nil {
				return err
			}
			if err := s.linkDevice(ctx, q, did, uuid.UUID(user.ID.Bytes)); err != nil {
				return err
			}
			session, err = s.sessions.IssueTx(ctx, q, uuid.UUID(user.ID.Bytes))
			if err != nil {
				return err
			}
			session.IsNewAccount = isNew
			return nil
		})
		if err != nil {
			return Session{}, err
		}
		return session, nil
	}

	user, isNew, err := s.resolveOrCreateUser(ctx, s.db, phone, now)
	if err != nil {
		return Session{}, err
	}
	if err := s.linkDevice(ctx, s.db, did, uuid.UUID(user.ID.Bytes)); err != nil {
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
// than erroring. db is explicit (rather than always s.db) so the same
// logic runs either directly against the service's store or, inside
// VerifyOTP's transaction, against a transaction-scoped *repository.Queries.
func (s *AuthService) resolveOrCreateUser(ctx context.Context, db AuthStore, phone string, now time.Time) (repository.User, bool, error) {
	existing, err := db.GetUserByPhone(ctx, phone)
	if err == nil {
		return existing, false, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return repository.User{}, false, err
	}

	created, err := db.CreateUser(ctx, repository.CreateUserParams{
		ID:              pgtype.UUID{Bytes: uuid.New(), Valid: true},
		Phone:           phone,
		PhoneVerifiedAt: pgtype.Timestamptz{Time: now, Valid: true},
	})
	if err != nil {
		if isUniqueViolation(err) {
			existing, err := db.GetUserByPhone(ctx, phone)
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

// UnlinkDevice clears deviceID's account link, but only when it currently
// matches userID (issue #80, product-owner review) — the entire safety
// mechanism lives in UnlinkDeviceFromUser's own conditional update, so a
// mismatched, stale, or already-unlinked device affects zero rows rather
// than erroring. Called from AuthHandler.Logout so the same installation
// can sign into a different account afterward; deliberately separate from
// linkDevice's own conflict check above, which still rejects linking a
// still-linked device to a different account exactly as before — this
// method only ever clears a link that matches the caller's own account,
// never reassigns one. Never touches follows/updates/badges/notifications
// or any other ownership data.
func (s *AuthService) UnlinkDevice(ctx context.Context, deviceID, userID string) error {
	did, err := uuid.Parse(deviceID)
	if err != nil {
		return err
	}
	uid, err := uuid.Parse(userID)
	if err != nil {
		return err
	}
	return s.db.UnlinkDeviceFromUser(ctx, repository.UnlinkDeviceFromUserParams{
		ID:     pgtype.UUID{Bytes: did, Valid: true},
		UserID: pgtype.UUID{Bytes: uid, Valid: true},
	})
}

// linkDevice idempotently links deviceID to userID. Linking a device
// already linked to this same account is a no-op on the link itself
// (including under concurrent retries — see LinkDeviceToUser's own
// idempotency). Linking a device already linked to a *different* account
// is rejected rather than silently reassigning it, so a device's prior
// authored content (cats.created_by_device_id / updates.author_device_id,
// both keyed by device_id) is never retroactively re-attributed to a
// second account — that path returns immediately, before any backfill.
//
// On both the fresh-link and already-linked-to-this-account paths (issue
// #65), linkDevice also backfills this device's pre-existing device-owned
// follows and ordinary updates onto the account: BackfillFollowsUserID and
// BackfillUpdatesAuthorUserID each only touch rows still missing the
// account column, so re-running them (a repeat verification of the same
// already-linked device, or a retried transaction) is a safe no-op rather
// than a re-assignment. This is what makes "existing device-owned content
// remains associated after linking" true without a separate migration
// step for devices linked after this ships. db is explicit for the same
// reason as resolveOrCreateUser's.
func (s *AuthService) linkDevice(ctx context.Context, db AuthStore, deviceID, userID uuid.UUID) error {
	device, err := db.GetDeviceByID(ctx, pgtype.UUID{Bytes: deviceID, Valid: true})
	if err != nil {
		return err
	}
	if device.UserID.Valid {
		if uuid.UUID(device.UserID.Bytes) != userID {
			return ErrDeviceLinkedToOtherAccount
		}
	} else if err := db.LinkDeviceToUser(ctx, repository.LinkDeviceToUserParams{
		ID:     pgtype.UUID{Bytes: deviceID, Valid: true},
		UserID: pgtype.UUID{Bytes: userID, Valid: true},
	}); err != nil {
		return err
	}

	deviceArg := pgtype.UUID{Bytes: deviceID, Valid: true}
	userArg := pgtype.UUID{Bytes: userID, Valid: true}
	// Must run before BackfillFollowsUserID (issue #71): drops this
	// device's own not-yet-backfilled follow rows that duplicate a follow
	// the account already owns for the same cat, so the plain assignment
	// below can never violate follows_user_cat_uq.
	if err := db.DeleteRedundantDeviceFollows(ctx, repository.DeleteRedundantDeviceFollowsParams{
		DeviceID: deviceArg,
		UserID:   userArg,
	}); err != nil {
		return err
	}
	if err := db.BackfillFollowsUserID(ctx, repository.BackfillFollowsUserIDParams{
		UserID:   userArg,
		DeviceID: deviceArg,
	}); err != nil {
		return err
	}
	return db.BackfillUpdatesAuthorUserID(ctx, repository.BackfillUpdatesAuthorUserIDParams{
		AuthorUserID:   userArg,
		AuthorDeviceID: deviceArg,
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
