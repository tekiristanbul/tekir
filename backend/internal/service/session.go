package service

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"time"

	"github.com/golang-jwt/jwt/v4"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// ErrSessionInvalid means the presented access or refresh token is
// malformed, has an unknown signature, or matches no stored row. Every
// session-validation failure collapses to this one error (or, for a
// refresh token, ErrSessionExpired/ErrSessionRevoked) — callers must not
// try to distinguish "doesn't exist" from "is malformed" for an attacker.
var ErrSessionInvalid = errors.New("invalid session")

// ErrSessionExpired means a presented refresh token matched a stored row
// past its expires_at.
var ErrSessionExpired = errors.New("session expired")

// ErrSessionRevoked means a presented refresh token matched a stored row
// that has already been revoked (by rotation or logout).
var ErrSessionRevoked = errors.New("session revoked")

// refreshTokenBytes mirrors the device token's entropy budget (issue #32):
// 32 bytes × 8 = 256 bits, URL-safe base64-encoded.
const refreshTokenBytes = 32

// Session is the access/refresh token pair returned by otp verification
// and by a successful refresh. IsNewAccount is only meaningful on the
// result of AuthService.VerifyOTP (SessionService itself always issues it
// as false) — see VerifyOTP's doc comment.
type Session struct {
	AccessToken  string
	RefreshToken string
	UserID       string
	IsNewAccount bool
}

// accessClaims is the JWT claim set for an access token: only the
// account's id as Subject, plus standard issued-at/expiry. No phone
// number, role, or other account data is embedded — the token is a
// short-lived capability to authenticate as UserID, nothing more.
type accessClaims struct {
	jwt.RegisteredClaims
}

// SessionStore is satisfied by repository.Store (and, transaction-scoped,
// by *repository.Queries — see TxRunner); kept as an interface so
// SessionService stays testable without a real database connection.
type SessionStore interface {
	CreateRefreshToken(ctx context.Context, arg repository.CreateRefreshTokenParams) (repository.CreateRefreshTokenRow, error)
	GetRefreshTokenByHash(ctx context.Context, tokenHash string) (repository.RefreshToken, error)
	RevokeRefreshToken(ctx context.Context, arg repository.RevokeRefreshTokenParams) error
	RevokeRefreshTokenIfActive(ctx context.Context, arg repository.RevokeRefreshTokenIfActiveParams) (pgtype.UUID, error)
}

// SessionService issues, refreshes, validates, and revokes authenticated
// sessions (issue #58): a short-lived HS256 access token plus a
// long-lived, hashed, revocable, rotating refresh token.
type SessionService struct {
	db              SessionStore
	txRunner        TxRunner
	signingKey      []byte
	accessTokenTTL  time.Duration
	refreshTokenTTL time.Duration
	clock           func() time.Time
}

// SessionServiceOption configures optional SessionService behavior.
type SessionServiceOption func(*SessionService)

// WithSessionClock overrides the clock used for token issuance and expiry
// comparisons, so tests can construct exact expiry-boundary scenarios
// deterministically (mirrors WithFollowsClock's convention).
func WithSessionClock(clock func() time.Time) SessionServiceOption {
	return func(s *SessionService) { s.clock = clock }
}

// WithSessionTxRunner wires a TxRunner so Refresh's atomic conditional
// revoke and its replacement token's creation commit or roll back
// together (code review fix, issue #58). Unset in unit tests, which
// exercise the non-transactional fallback with hand-rolled fakes instead.
func WithSessionTxRunner(tx TxRunner) SessionServiceOption {
	return func(s *SessionService) { s.txRunner = tx }
}

func NewSessionService(db SessionStore, signingKey []byte, accessTokenTTL, refreshTokenTTL time.Duration, opts ...SessionServiceOption) *SessionService {
	s := &SessionService{
		db:              db,
		signingKey:      signingKey,
		accessTokenTTL:  accessTokenTTL,
		refreshTokenTTL: refreshTokenTTL,
		clock:           time.Now,
	}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

// Issue mints a new access/refresh token pair for userID.
func (s *SessionService) Issue(ctx context.Context, userID uuid.UUID) (Session, error) {
	return s.issue(ctx, s.db, userID)
}

// IssueTx is Issue, but writes the new refresh token through db instead of
// the service's own store — used by AuthService.VerifyOTP to keep session
// issuance inside the same transaction as otp consumption, account
// resolution, and device linking.
func (s *SessionService) IssueTx(ctx context.Context, db SessionStore, userID uuid.UUID) (Session, error) {
	return s.issue(ctx, db, userID)
}

func (s *SessionService) issue(ctx context.Context, db SessionStore, userID uuid.UUID) (Session, error) {
	access, err := s.signAccessToken(userID)
	if err != nil {
		return Session{}, err
	}

	rawRefresh, err := generateOpaqueToken()
	if err != nil {
		return Session{}, err
	}

	now := s.clock()
	if _, err := db.CreateRefreshToken(ctx, repository.CreateRefreshTokenParams{
		ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
		UserID:    pgtype.UUID{Bytes: userID, Valid: true},
		TokenHash: HashRefreshToken(rawRefresh),
		ExpiresAt: pgtype.Timestamptz{Time: now.Add(s.refreshTokenTTL), Valid: true},
	}); err != nil {
		return Session{}, err
	}

	return Session{AccessToken: access, RefreshToken: rawRefresh, UserID: userID.String()}, nil
}

// Refresh rotates a valid, unexpired, unrevoked refresh token into a new
// pair. The presented token is atomically revoked as part of rotation —
// two concurrent refresh calls presenting the same token can never both
// win: RevokeRefreshTokenIfActive re-evaluates "unrevoked and unexpired"
// atomically against the row's committed state, so only one revoke can
// ever succeed (code review fix, issue #58); the loser gets
// ErrSessionRevoked rather than a second minted pair. When a TxRunner is
// configured, the revoke and its replacement token's creation commit or
// roll back together, so a failure minting the replacement never leaves
// the client with no valid token at all.
func (s *SessionService) Refresh(ctx context.Context, rawRefreshToken string) (Session, error) {
	tokenHash := HashRefreshToken(rawRefreshToken)
	row, err := s.db.GetRefreshTokenByHash(ctx, tokenHash)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Session{}, ErrSessionInvalid
		}
		return Session{}, err
	}

	now := s.clock()
	// Pre-checks purely for a precise error message on the common paths —
	// the actual security boundary is the atomic conditional revoke below,
	// which re-validates both predicates itself regardless of what this
	// read observed.
	if row.RevokedAt.Valid {
		return Session{}, ErrSessionRevoked
	}
	if !row.ExpiresAt.Time.After(now) {
		return Session{}, ErrSessionExpired
	}

	revokeArgs := repository.RevokeRefreshTokenIfActiveParams{
		ID:        row.ID,
		RevokedAt: pgtype.Timestamptz{Time: now, Valid: true},
		Now:       pgtype.Timestamptz{Time: now, Valid: true},
	}

	if s.txRunner != nil {
		var session Session
		err := s.txRunner.WithinTx(ctx, func(q *repository.Queries) error {
			userID, err := q.RevokeRefreshTokenIfActive(ctx, revokeArgs)
			if err != nil {
				return err
			}
			session, err = s.issue(ctx, q, uuid.UUID(userID.Bytes))
			return err
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return Session{}, ErrSessionRevoked
			}
			return Session{}, err
		}
		return session, nil
	}

	userID, err := s.db.RevokeRefreshTokenIfActive(ctx, revokeArgs)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Session{}, ErrSessionRevoked
		}
		return Session{}, err
	}
	return s.issue(ctx, s.db, uuid.UUID(userID.Bytes))
}

// Revoke invalidates a refresh token (logout). Revoking an unknown or
// already-revoked token is not an error — logout is idempotent, matching
// Follow/Unfollow's convention elsewhere in this codebase.
func (s *SessionService) Revoke(ctx context.Context, rawRefreshToken string) error {
	row, err := s.db.GetRefreshTokenByHash(ctx, HashRefreshToken(rawRefreshToken))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		return err
	}
	if row.RevokedAt.Valid {
		return nil
	}
	return s.db.RevokeRefreshToken(ctx, repository.RevokeRefreshTokenParams{
		ID:        row.ID,
		RevokedAt: pgtype.Timestamptz{Time: s.clock(), Valid: true},
	})
}

// ValidateAccessToken parses and validates an access token JWT, returning
// its subject (the account's user id) as a string. Expired, malformed,
// wrong-algorithm, and bad-signature tokens all return ErrSessionInvalid —
// the caller (RequireBearer) must not distinguish why, mirroring
// RequireDeviceToken's generic-401 convention.
func (s *SessionService) ValidateAccessToken(rawToken string) (string, error) {
	token, err := jwt.ParseWithClaims(rawToken, &accessClaims{}, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, ErrSessionInvalid
		}
		return s.signingKey, nil
	})
	if err != nil || token == nil || !token.Valid {
		return "", ErrSessionInvalid
	}

	claims, ok := token.Claims.(*accessClaims)
	if !ok || claims.Subject == "" {
		return "", ErrSessionInvalid
	}
	return claims.Subject, nil
}

func (s *SessionService) signAccessToken(userID uuid.UUID) (string, error) {
	now := s.clock()
	claims := accessClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   userID.String(),
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(s.accessTokenTTL)),
		},
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(s.signingKey)
}

// generateOpaqueToken returns a URL-safe base64-encoded refresh token with
// at least 256 bits of entropy from a cryptographically secure source —
// the same construction as the device token (issue #32).
func generateOpaqueToken() (string, error) {
	b := make([]byte, refreshTokenBytes)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// HashRefreshToken returns the lower-hex sha-256 hash of a raw refresh
// token — the only value ever stored in refresh_tokens.token_hash.
func HashRefreshToken(rawToken string) string {
	sum := sha256.Sum256([]byte(rawToken))
	return hex.EncodeToString(sum[:])
}
