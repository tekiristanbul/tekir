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

// fakeDevicesStore is an in-process stub for DevicesStore.
type fakeDevicesStore struct {
	createdRows []repository.CreateDeviceParams
	createErr   error

	deviceRow repository.GetDeviceByTokenHashRow
	getErr    error

	setPushTokenCalls []repository.SetDevicePushTokenParams
	setPushTokenErr   error
}

func (f *fakeDevicesStore) CreateDevice(_ context.Context, arg repository.CreateDeviceParams) (repository.CreateDeviceRow, error) {
	if f.createErr != nil {
		return repository.CreateDeviceRow{}, f.createErr
	}
	f.createdRows = append(f.createdRows, arg)
	return repository.CreateDeviceRow{
		ID:        arg.ID,
		CreatedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}, nil
}

func (f *fakeDevicesStore) GetDeviceByTokenHash(_ context.Context, _ string) (repository.GetDeviceByTokenHashRow, error) {
	return f.deviceRow, f.getErr
}

func (f *fakeDevicesStore) SetDevicePushToken(_ context.Context, arg repository.SetDevicePushTokenParams) error {
	f.setPushTokenCalls = append(f.setPushTokenCalls, arg)
	return f.setPushTokenErr
}

// ── token generation ─────────────────────────────────────────────────────────

func TestGenerateTokenEntropy(t *testing.T) {
	// Register two devices and confirm the tokens are distinct and long enough
	// to carry at least 256 bits of base64-encoded entropy.
	svc := service.NewDevicesService(&fakeDevicesStore{})

	r1, err := svc.Register(context.Background(), "web", nil)
	if err != nil {
		t.Fatalf("first register: %v", err)
	}
	r2, err := svc.Register(context.Background(), "web", nil)
	if err != nil {
		t.Fatalf("second register: %v", err)
	}

	if r1.DeviceToken == r2.DeviceToken {
		t.Fatal("two successive tokens must be distinct")
	}

	// 32 bytes base64 → ⌈32*4/3⌉ = 43 chars (raw URL encoding, no padding).
	if len(r1.DeviceToken) < 43 {
		t.Errorf("token too short: %d chars (expected ≥43)", len(r1.DeviceToken))
	}
}

func TestHashDeviceTokenDeterministic(t *testing.T) {
	const raw = "some-test-token"
	h1 := service.HashDeviceToken(raw)
	h2 := service.HashDeviceToken(raw)
	if h1 != h2 {
		t.Error("same input must produce the same hash")
	}
	if len(h1) != 64 {
		t.Errorf("sha-256 hex must be 64 chars, got %d", len(h1))
	}
}

func TestHashDeviceTokenDistinct(t *testing.T) {
	if service.HashDeviceToken("a") == service.HashDeviceToken("b") {
		t.Error("different inputs must produce different hashes")
	}
}

// ── registration ─────────────────────────────────────────────────────────────

func TestDevicesService_Register_AllPlatforms(t *testing.T) {
	platforms := []string{"ios", "android", "web"}
	for _, p := range platforms {
		t.Run(p, func(t *testing.T) {
			store := &fakeDevicesStore{}
			svc := service.NewDevicesService(store)

			reg, err := svc.Register(context.Background(), p, nil)
			if err != nil {
				t.Fatalf("register: %v", err)
			}
			if reg.DeviceID == "" {
				t.Error("DeviceID must not be empty")
			}
			if reg.DeviceToken == "" {
				t.Error("DeviceToken must not be empty")
			}
			// token must not appear in the stored row — only the hash.
			if len(store.createdRows) != 1 {
				t.Fatalf("expected 1 stored row, got %d", len(store.createdRows))
			}
			if store.createdRows[0].TokenHash == reg.DeviceToken {
				t.Error("raw token must not be stored as the hash")
			}
		})
	}
}

func TestDevicesService_Register_NoPushToken(t *testing.T) {
	store := &fakeDevicesStore{}
	svc := service.NewDevicesService(store)

	if _, err := svc.Register(context.Background(), "web", nil); err != nil {
		t.Fatalf("register without push_token: %v", err)
	}
	if len(store.createdRows) != 1 {
		t.Fatalf("expected 1 stored row, got %d", len(store.createdRows))
	}
	if store.createdRows[0].PushToken.Valid {
		t.Error("push_token must be null when not supplied")
	}
}

func TestDevicesService_Register_WithPushToken(t *testing.T) {
	store := &fakeDevicesStore{}
	svc := service.NewDevicesService(store)

	pt := "fcm-token-abc"
	if _, err := svc.Register(context.Background(), "android", &pt); err != nil {
		t.Fatalf("register with push_token: %v", err)
	}
	if !store.createdRows[0].PushToken.Valid || store.createdRows[0].PushToken.String != pt {
		t.Errorf("push_token not stored correctly: %v", store.createdRows[0].PushToken)
	}
}

func TestDevicesService_Register_InvalidPlatform(t *testing.T) {
	svc := service.NewDevicesService(&fakeDevicesStore{})

	cases := []string{"", "windows", "macos", "linux", "IOS", "Android", "WEB"}
	for _, p := range cases {
		t.Run(p, func(t *testing.T) {
			_, err := svc.Register(context.Background(), p, nil)
			if !errors.Is(err, service.ErrInvalidPlatform) {
				t.Errorf("expected ErrInvalidPlatform, got %v", err)
			}
		})
	}
}

func TestDevicesService_Register_StoresHashNotToken(t *testing.T) {
	store := &fakeDevicesStore{}
	svc := service.NewDevicesService(store)

	reg, err := svc.Register(context.Background(), "ios", nil)
	if err != nil {
		t.Fatalf("register: %v", err)
	}

	row := store.createdRows[0]
	// The stored hash must be the sha-256 of the returned raw token.
	expectedHash := service.HashDeviceToken(reg.DeviceToken)
	if row.TokenHash != expectedHash {
		t.Errorf("stored hash %q ≠ sha256(%q)", row.TokenHash, reg.DeviceToken)
	}
	// The hash must not equal the raw token.
	if row.TokenHash == reg.DeviceToken {
		t.Error("raw token must not be stored verbatim as hash")
	}
}

func TestDevicesService_Register_DBError(t *testing.T) {
	svc := service.NewDevicesService(&fakeDevicesStore{createErr: errors.New("connection refused")})

	_, err := svc.Register(context.Background(), "web", nil)
	if err == nil {
		t.Fatal("expected error from db, got nil")
	}
}

// ── token resolution ──────────────────────────────────────────────────────────

func TestDevicesService_ResolveToken_Valid(t *testing.T) {
	id := uuid.New()
	store := &fakeDevicesStore{
		deviceRow: repository.GetDeviceByTokenHashRow{
			ID: pgtype.UUID{Bytes: id, Valid: true},
		},
	}
	svc := service.NewDevicesService(store)

	identity, err := svc.ResolveToken(context.Background(), "some-token")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if identity.DeviceID != id.String() {
		t.Errorf("expected device id %s, got %s", id.String(), identity.DeviceID)
	}
}

func TestDevicesService_ResolveToken_NotFound(t *testing.T) {
	svc := service.NewDevicesService(&fakeDevicesStore{getErr: pgx.ErrNoRows})

	_, err := svc.ResolveToken(context.Background(), "unknown-token")
	if !errors.Is(err, service.ErrDeviceNotFound) {
		t.Errorf("expected ErrDeviceNotFound, got %v", err)
	}
}

func TestDevicesService_ResolveToken_Revoked(t *testing.T) {
	id := uuid.New()
	store := &fakeDevicesStore{
		deviceRow: repository.GetDeviceByTokenHashRow{
			ID:        pgtype.UUID{Bytes: id, Valid: true},
			RevokedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
		},
	}
	svc := service.NewDevicesService(store)

	_, err := svc.ResolveToken(context.Background(), "revoked-token")
	if !errors.Is(err, service.ErrDeviceRevoked) {
		t.Errorf("expected ErrDeviceRevoked, got %v", err)
	}
}

func TestDevicesService_ResolveToken_DBError(t *testing.T) {
	svc := service.NewDevicesService(&fakeDevicesStore{getErr: errors.New("db unavailable")})

	_, err := svc.ResolveToken(context.Background(), "some-token")
	if err == nil {
		t.Fatal("expected error from db, got nil")
	}
	if errors.Is(err, service.ErrDeviceNotFound) || errors.Is(err, service.ErrDeviceRevoked) {
		t.Errorf("db error must not be wrapped as a domain error, got %v", err)
	}
}

// ── hash content ──────────────────────────────────────────────────────────────

func TestHashDeviceToken_OnlyLowerHex(t *testing.T) {
	h := service.HashDeviceToken("test-token")
	for _, ch := range h {
		if !strings.ContainsRune("0123456789abcdef", ch) {
			t.Errorf("hash contains non-lower-hex character: %q", ch)
		}
	}
}

// ── push token registration (issue #84) ──────────────────────────────────────

func TestSetPushToken_StoresTrimmedToken(t *testing.T) {
	db := &fakeDevicesStore{}
	svc := service.NewDevicesService(db)
	deviceID := uuid.New()

	if err := svc.SetPushToken(context.Background(), deviceID.String(), "  fcm-token-value  "); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(db.setPushTokenCalls) != 1 {
		t.Fatalf("expected 1 store call, got %d", len(db.setPushTokenCalls))
	}
	call := db.setPushTokenCalls[0]
	if !call.PushToken.Valid || call.PushToken.String != "fcm-token-value" {
		t.Errorf("expected trimmed token stored, got %+v", call.PushToken)
	}
	if uuid.UUID(call.DeviceID.Bytes) != deviceID {
		t.Errorf("expected device id %s, got %s", deviceID, uuid.UUID(call.DeviceID.Bytes))
	}
}

func TestSetPushToken_RejectsEmptyAndOversized(t *testing.T) {
	db := &fakeDevicesStore{}
	svc := service.NewDevicesService(db)

	for name, token := range map[string]string{
		"empty":      "",
		"whitespace": "   ",
		"oversized":  strings.Repeat("x", 5000),
	} {
		if err := svc.SetPushToken(context.Background(), uuid.NewString(), token); !errors.Is(err, service.ErrInvalidPushToken) {
			t.Errorf("%s: expected ErrInvalidPushToken, got %v", name, err)
		}
	}
	if len(db.setPushTokenCalls) != 0 {
		t.Errorf("store must not be called for rejected tokens: %d calls", len(db.setPushTokenCalls))
	}
}

func TestSetPushToken_RejectsMalformedDeviceID(t *testing.T) {
	db := &fakeDevicesStore{}
	svc := service.NewDevicesService(db)

	if err := svc.SetPushToken(context.Background(), "not-a-uuid", "fcm-token-value"); !errors.Is(err, service.ErrDeviceNotFound) {
		t.Errorf("expected ErrDeviceNotFound, got %v", err)
	}
	if len(db.setPushTokenCalls) != 0 {
		t.Errorf("store must not be called for a malformed device id")
	}
}
