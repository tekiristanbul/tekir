package service_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// fakeSessionStore is an in-process stub for service.SessionStore.
type fakeSessionStore struct {
	rows      map[string]repository.RefreshToken
	createErr error
}

func newFakeSessionStore() *fakeSessionStore {
	return &fakeSessionStore{rows: map[string]repository.RefreshToken{}}
}

func (f *fakeSessionStore) CreateRefreshToken(_ context.Context, arg repository.CreateRefreshTokenParams) (repository.CreateRefreshTokenRow, error) {
	if f.createErr != nil {
		return repository.CreateRefreshTokenRow{}, f.createErr
	}
	f.rows[arg.TokenHash] = repository.RefreshToken{
		ID:        arg.ID,
		UserID:    arg.UserID,
		TokenHash: arg.TokenHash,
		ExpiresAt: arg.ExpiresAt,
	}
	return repository.CreateRefreshTokenRow{ID: arg.ID, CreatedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true}}, nil
}

func (f *fakeSessionStore) GetRefreshTokenByHash(_ context.Context, tokenHash string) (repository.RefreshToken, error) {
	row, ok := f.rows[tokenHash]
	if !ok {
		return repository.RefreshToken{}, pgx.ErrNoRows
	}
	return row, nil
}

func (f *fakeSessionStore) RevokeRefreshToken(_ context.Context, arg repository.RevokeRefreshTokenParams) error {
	for hash, row := range f.rows {
		if row.ID == arg.ID {
			row.RevokedAt = arg.RevokedAt
			f.rows[hash] = row
			return nil
		}
	}
	return nil
}

func TestSessionService_Issue_ProducesValidAccessToken(t *testing.T) {
	store := newFakeSessionStore()
	svc := service.NewSessionService(store, []byte("test-signing-key"), time.Hour, 24*time.Hour)
	userID := uuid.New()

	session, err := svc.Issue(context.Background(), userID)
	if err != nil {
		t.Fatalf("issue: %v", err)
	}
	if session.UserID != userID.String() {
		t.Errorf("expected user id %s, got %s", userID, session.UserID)
	}

	gotUserID, err := svc.ValidateAccessToken(session.AccessToken)
	if err != nil {
		t.Fatalf("validate: %v", err)
	}
	if gotUserID != userID.String() {
		t.Errorf("expected %s, got %s", userID, gotUserID)
	}
}

func TestSessionService_ValidateAccessToken_Expired(t *testing.T) {
	store := newFakeSessionStore()
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }
	svc := service.NewSessionService(store, []byte("test-signing-key"), time.Minute, 24*time.Hour, service.WithSessionClock(clock))

	session, err := svc.Issue(context.Background(), uuid.New())
	if err != nil {
		t.Fatalf("issue: %v", err)
	}

	now = now.Add(2 * time.Minute)
	if _, err := svc.ValidateAccessToken(session.AccessToken); !errors.Is(err, service.ErrSessionInvalid) {
		t.Errorf("expected ErrSessionInvalid for expired token, got %v", err)
	}
}

func TestSessionService_ValidateAccessToken_WrongSigningKey(t *testing.T) {
	store := newFakeSessionStore()
	svc := service.NewSessionService(store, []byte("key-a"), time.Hour, 24*time.Hour)
	other := service.NewSessionService(store, []byte("key-b"), time.Hour, 24*time.Hour)

	session, err := svc.Issue(context.Background(), uuid.New())
	if err != nil {
		t.Fatalf("issue: %v", err)
	}
	if _, err := other.ValidateAccessToken(session.AccessToken); !errors.Is(err, service.ErrSessionInvalid) {
		t.Errorf("expected ErrSessionInvalid for wrong signing key, got %v", err)
	}
}

func TestSessionService_ValidateAccessToken_Malformed(t *testing.T) {
	svc := service.NewSessionService(newFakeSessionStore(), []byte("k"), time.Hour, 24*time.Hour)
	if _, err := svc.ValidateAccessToken("not-a-jwt"); !errors.Is(err, service.ErrSessionInvalid) {
		t.Errorf("expected ErrSessionInvalid for malformed token, got %v", err)
	}
}

func TestSessionService_Refresh_RotatesAndRevokesOldToken(t *testing.T) {
	store := newFakeSessionStore()
	svc := service.NewSessionService(store, []byte("k"), time.Hour, 24*time.Hour)

	first, err := svc.Issue(context.Background(), uuid.New())
	if err != nil {
		t.Fatalf("issue: %v", err)
	}

	second, err := svc.Refresh(context.Background(), first.RefreshToken)
	if err != nil {
		t.Fatalf("refresh: %v", err)
	}
	if second.RefreshToken == first.RefreshToken {
		t.Error("refresh must rotate to a new refresh token")
	}
	if second.UserID != first.UserID {
		t.Error("refresh must preserve the same user id")
	}

	// replaying the original (now-rotated) refresh token must fail.
	if _, err := svc.Refresh(context.Background(), first.RefreshToken); !errors.Is(err, service.ErrSessionRevoked) {
		t.Errorf("expected ErrSessionRevoked replaying a rotated token, got %v", err)
	}
}

func TestSessionService_Refresh_Expired(t *testing.T) {
	store := newFakeSessionStore()
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }
	svc := service.NewSessionService(store, []byte("k"), time.Hour, time.Minute, service.WithSessionClock(clock))

	session, err := svc.Issue(context.Background(), uuid.New())
	if err != nil {
		t.Fatalf("issue: %v", err)
	}

	now = now.Add(2 * time.Minute)
	if _, err := svc.Refresh(context.Background(), session.RefreshToken); !errors.Is(err, service.ErrSessionExpired) {
		t.Errorf("expected ErrSessionExpired, got %v", err)
	}
}

func TestSessionService_Refresh_Unknown(t *testing.T) {
	svc := service.NewSessionService(newFakeSessionStore(), []byte("k"), time.Hour, 24*time.Hour)
	if _, err := svc.Refresh(context.Background(), "unknown-token"); !errors.Is(err, service.ErrSessionInvalid) {
		t.Errorf("expected ErrSessionInvalid, got %v", err)
	}
}

func TestSessionService_Revoke_IsIdempotent(t *testing.T) {
	store := newFakeSessionStore()
	svc := service.NewSessionService(store, []byte("k"), time.Hour, 24*time.Hour)

	session, err := svc.Issue(context.Background(), uuid.New())
	if err != nil {
		t.Fatalf("issue: %v", err)
	}

	if err := svc.Revoke(context.Background(), session.RefreshToken); err != nil {
		t.Fatalf("first revoke: %v", err)
	}
	if err := svc.Revoke(context.Background(), session.RefreshToken); err != nil {
		t.Fatalf("second revoke must also succeed (idempotent): %v", err)
	}

	if _, err := svc.Refresh(context.Background(), session.RefreshToken); !errors.Is(err, service.ErrSessionRevoked) {
		t.Errorf("expected ErrSessionRevoked after logout, got %v", err)
	}
}

func TestSessionService_Revoke_UnknownTokenIsNotAnError(t *testing.T) {
	svc := service.NewSessionService(newFakeSessionStore(), []byte("k"), time.Hour, 24*time.Hour)
	if err := svc.Revoke(context.Background(), "never-issued"); err != nil {
		t.Errorf("revoking an unknown token must not error, got %v", err)
	}
}

func TestHashRefreshToken_DeterministicAndDistinct(t *testing.T) {
	h1 := service.HashRefreshToken("a")
	h2 := service.HashRefreshToken("a")
	if h1 != h2 {
		t.Error("same input must hash the same")
	}
	if service.HashRefreshToken("a") == service.HashRefreshToken("b") {
		t.Error("different input must hash differently")
	}
}
