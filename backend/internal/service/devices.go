package service

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// ErrInvalidPlatform means the platform value isn't one of the accepted values.
var ErrInvalidPlatform = errors.New("invalid platform")

// ErrDeviceNotFound means no device matches the presented token hash.
var ErrDeviceNotFound = errors.New("device not found")

// ErrDeviceRevoked means the device credential has been revoked.
var ErrDeviceRevoked = errors.New("device revoked")

// ErrInvalidPushToken means the presented push token is empty or
// implausibly large.
var ErrInvalidPushToken = errors.New("invalid push token")

// maxPushTokenLength bounds an fcm registration token (issue #84) before
// it's ever stored — real tokens are a few hundred bytes; anything near
// this limit is garbage, and an unbounded value would let one request
// bloat the devices row arbitrarily.
const maxPushTokenLength = 4096

// allowedPlatforms is the closed set of accepted platform values (see
// docs/architecture/api.md). 'web' is required because the flutter
// application has a web target.
var allowedPlatforms = map[string]bool{
	"ios":     true,
	"android": true,
	"web":     true,
}

// deviceTokenBytes is the number of random bytes for the device token —
// 32 bytes × 8 = 256 bits of entropy, URL-safe base64-encoded for safe
// transport in an HTTP header value.
const deviceTokenBytes = 32

// DeviceRegistration is the one-time result of a successful POST /v1/devices.
// DeviceToken is the raw, high-entropy secret the client must persist
// securely — it is never stored server-side or returned again after this.
type DeviceRegistration struct {
	DeviceID    string
	DeviceToken string
}

// DeviceIdentity is the non-secret representation of a resolved device,
// placed in request context by the device-auth middleware. Only DeviceID
// and (if linked, issue #58) UserID are carried — never the raw token or
// its hash.
type DeviceIdentity struct {
	DeviceID string
	// UserID is the account this device is linked to, or nil if the device
	// has never completed otp verification (see AuthService.VerifyOTP).
	UserID *string
}

// DevicesStore is satisfied by repository.Store; kept as an interface so
// DevicesService stays testable without a real database connection.
type DevicesStore interface {
	CreateDevice(ctx context.Context, arg repository.CreateDeviceParams) (repository.CreateDeviceRow, error)
	GetDeviceByTokenHash(ctx context.Context, tokenHash string) (repository.GetDeviceByTokenHashRow, error)
	SetDevicePushToken(ctx context.Context, arg repository.SetDevicePushTokenParams) error
}

// DevicesService handles device registration and credential resolution.
// Token generation and hashing are implemented here, not in the handler,
// so they can be tested independently of HTTP concerns.
type DevicesService struct {
	db DevicesStore
}

func NewDevicesService(db DevicesStore) *DevicesService {
	return &DevicesService{db: db}
}

// Register creates a new anonymous device identity. It validates the
// platform, generates a cryptographically secure token, stores only its
// hash, and returns the raw token once. The caller must not log or
// persist the returned DeviceToken.
func (s *DevicesService) Register(ctx context.Context, platform string, pushToken *string) (DeviceRegistration, error) {
	if !allowedPlatforms[platform] {
		return DeviceRegistration{}, ErrInvalidPlatform
	}

	rawToken, err := generateDeviceToken()
	if err != nil {
		return DeviceRegistration{}, err
	}
	hash := HashDeviceToken(rawToken)

	id := uuid.New()
	row, err := s.db.CreateDevice(ctx, repository.CreateDeviceParams{
		ID:        pgtype.UUID{Bytes: id, Valid: true},
		TokenHash: hash,
		PushToken: nullableText(pushToken),
		Platform:  platform,
	})
	if err != nil {
		return DeviceRegistration{}, err
	}

	return DeviceRegistration{
		DeviceID:    uuid.UUID(row.ID.Bytes).String(),
		DeviceToken: rawToken,
	}, nil
}

// SetPushToken registers or refreshes the caller installation's fcm token
// (issue #84). In-place on the caller's own device row — rotation never
// creates a second row — and the underlying query clears the same token
// off any other row, so a re-registered installation can't be pushed
// twice. The token is a delivery credential: it is never logged here or
// anywhere downstream.
func (s *DevicesService) SetPushToken(ctx context.Context, deviceID, pushToken string) error {
	pushToken = strings.TrimSpace(pushToken)
	if pushToken == "" || len(pushToken) > maxPushTokenLength {
		return ErrInvalidPushToken
	}
	id, err := uuid.Parse(deviceID)
	if err != nil {
		return ErrDeviceNotFound
	}
	return s.db.SetDevicePushToken(ctx, repository.SetDevicePushTokenParams{
		PushToken: pgtype.Text{String: pushToken, Valid: true},
		DeviceID:  pgtype.UUID{Bytes: id, Valid: true},
	})
}

// ResolveToken hashes the presented raw token and resolves it to a
// non-secret DeviceIdentity. Returns ErrDeviceNotFound if no matching
// row exists and ErrDeviceRevoked if the device has been revoked.
// The caller (middleware) must not log the raw token or the hash.
func (s *DevicesService) ResolveToken(ctx context.Context, rawToken string) (DeviceIdentity, error) {
	hash := HashDeviceToken(rawToken)
	row, err := s.db.GetDeviceByTokenHash(ctx, hash)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return DeviceIdentity{}, ErrDeviceNotFound
		}
		return DeviceIdentity{}, err
	}
	if row.RevokedAt.Valid {
		return DeviceIdentity{}, ErrDeviceRevoked
	}
	identity := DeviceIdentity{DeviceID: uuid.UUID(row.ID.Bytes).String()}
	if row.UserID.Valid {
		userID := uuid.UUID(row.UserID.Bytes).String()
		identity.UserID = &userID
	}
	return identity, nil
}

// generateDeviceToken returns a URL-safe base64-encoded token with at
// least 256 bits of entropy from a cryptographically secure random source.
func generateDeviceToken() (string, error) {
	b := make([]byte, deviceTokenBytes)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// HashDeviceToken returns the lower-hex SHA-256 hash of the raw token.
// This is the only value stored in devices.token_hash; the raw token is
// never persisted. Exported so it can be used in tests without importing
// crypto packages directly.
func HashDeviceToken(rawToken string) string {
	sum := sha256.Sum256([]byte(rawToken))
	return hex.EncodeToString(sum[:])
}

// nullableText converts a *string to pgtype.Text for use in sqlc queries.
func nullableText(s *string) pgtype.Text {
	if s == nil {
		return pgtype.Text{}
	}
	return pgtype.Text{String: *s, Valid: true}
}
