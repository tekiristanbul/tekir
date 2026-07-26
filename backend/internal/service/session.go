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

// SessionStore is satisfied by repository.Store; kept as an interface so
// SessionService stays testable without a real database connection.
type SessionStore interface {
	CreateRefreshToken(ctx context.Context, arg repository.CreateRefreshTokenParams) (repository.CreateRefreshTokenRow, error)
	GetRefreshTokenByHash(ctx context.Context, tokenHash string) (repository.RefreshToken, error)
	RevokeRefreshToken(ctx context.Context, arg repository.RevokeRefreshTokenParams) error
}

// SessionService issues, refreshes, validates, and revokes authenticated
// sessions (issue #58): a short-lived HS256 access token plus a
// long-lived, hashed, revocable, rotating refresh token.
type SessionService struct {
	db              SessionStore
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
	access, err := s.signAccessToken(userID)
	if err != nil {
		return Session{}, err
	}

	rawRefresh, err := generateOpaqueToken()
	if err != nil {
		return Session{}, err
	}

	now := s.clock()
	if _, err := s.db.CreateRefreshToken(ctx, repository.CreateRefreshTokenParams{
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
// pair. The presented token is revoked as part of rotation — replaying it
// again (e.g. a stolen copy racing the legitimate client) fails with
// ErrSessionRevoked rather than minting a second pair from the same token.
func (s *SessionService) Refresh(ctx context.Context, rawRefreshToken string) (Session, error) {
	row, err := s.db.GetRefreshTokenByHash(ctx, HashRefreshToken(rawRefreshToken))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Session{}, ErrSessionInvalid
		}
		return Session{}, err
	}

	now := s.clock()
	if row.RevokedAt.Valid {
		return Session{}, ErrSessionRevoked
	}
	if !row.ExpiresAt.Time.After(now) {
		return Session{}, ErrSessionExpired
	}

	if err := s.db.RevokeRefreshToken(ctx, repository.RevokeRefreshTokenParams{
		ID:        row.ID,
		RevokedAt: pgtype.Timestamptz{Time: now, Valid: true},
	}); err != nil {
		return Session{}, err
	}

	return s.Issue(ctx, uuid.UUID(row.UserID.Bytes))
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
