package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// fakeFollowsStore is an in-process stub for FollowsStore.
type fakeFollowsStore struct {
	exists    bool
	existsErr error

	createErr error
	// captured, if non-nil, records the arg the last CreateFollow call
	// received — a pointer field so the write is visible through the copy
	// of fakeFollowsStore that ends up inside FollowsService.
	createdArg *repository.CreateFollowParams

	deleteErr  error
	deletedArg *repository.DeleteFollowParams

	rows    []repository.ListFollowedCatsRow
	listErr error
	// capturedUserID records the account id ListFollowedCats was called
	// with, so a test can assert isolation without needing a real database.
	capturedUserID *pgtype.UUID
}

func (f fakeFollowsStore) CatExists(_ context.Context, _ repository.CatExistsParams) (bool, error) {
	return f.exists, f.existsErr
}

func (f fakeFollowsStore) CreateFollow(_ context.Context, arg repository.CreateFollowParams) error {
	if f.createdArg != nil {
		*f.createdArg = arg
	}
	return f.createErr
}

func (f fakeFollowsStore) DeleteFollow(_ context.Context, arg repository.DeleteFollowParams) error {
	if f.deletedArg != nil {
		*f.deletedArg = arg
	}
	return f.deleteErr
}

func (f fakeFollowsStore) ListFollowedCats(_ context.Context, userID pgtype.UUID) ([]repository.ListFollowedCatsRow, error) {
	if f.capturedUserID != nil {
		*f.capturedUserID = userID
	}
	return f.rows, f.listErr
}

// ── Follow ────────────────────────────────────────────────────────────────

func TestFollowsService_Follow_Success(t *testing.T) {
	var captured repository.CreateFollowParams
	svc := NewFollowsService(fakeFollowsStore{exists: true, createdArg: &captured})

	catID := uuid.New()
	userID := uuid.New()
	deviceID := uuid.New()
	if err := svc.Follow(context.Background(), catID.String(), userID.String(), deviceID.String()); err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if uuid.UUID(captured.CatID.Bytes) != catID {
		t.Errorf("expected cat id %s, got %s", catID, uuid.UUID(captured.CatID.Bytes))
	}
	if uuid.UUID(captured.UserID.Bytes) != userID {
		t.Errorf("expected user id %s, got %s", userID, uuid.UUID(captured.UserID.Bytes))
	}
	if !captured.DeviceID.Valid || uuid.UUID(captured.DeviceID.Bytes) != deviceID {
		t.Errorf("expected device id %s, got %+v", deviceID, captured.DeviceID)
	}
}

func TestFollowsService_Follow_WithoutDeviceToken_StillSucceeds(t *testing.T) {
	var captured repository.CreateFollowParams
	svc := NewFollowsService(fakeFollowsStore{exists: true, createdArg: &captured})

	if err := svc.Follow(context.Background(), uuid.New().String(), uuid.New().String(), ""); err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if captured.DeviceID.Valid {
		t.Errorf("expected no device id recorded, got %+v", captured.DeviceID)
	}
	if !captured.UserID.Valid {
		t.Error("expected user id to still be recorded")
	}
}

func TestFollowsService_Follow_InvalidCatID(t *testing.T) {
	svc := NewFollowsService(fakeFollowsStore{exists: true})
	err := svc.Follow(context.Background(), "not-a-uuid", uuid.New().String(), uuid.New().String())
	if !errors.Is(err, ErrInvalidCatID) {
		t.Fatalf("expected ErrInvalidCatID, got %v", err)
	}
}

func TestFollowsService_Follow_InvalidUserID(t *testing.T) {
	svc := NewFollowsService(fakeFollowsStore{exists: true})
	err := svc.Follow(context.Background(), uuid.New().String(), "not-a-uuid", "")
	if err == nil {
		t.Fatal("expected error for invalid user id, got nil")
	}
}

func TestFollowsService_Follow_InvalidDeviceID(t *testing.T) {
	svc := NewFollowsService(fakeFollowsStore{exists: true})
	err := svc.Follow(context.Background(), uuid.New().String(), uuid.New().String(), "not-a-uuid")
	if err == nil {
		t.Fatal("expected error for invalid device id, got nil")
	}
}

func TestFollowsService_Follow_UnknownCat(t *testing.T) {
	svc := NewFollowsService(fakeFollowsStore{exists: false})
	err := svc.Follow(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String())
	if !errors.Is(err, ErrCatNotFound) {
		t.Fatalf("expected ErrCatNotFound, got %v", err)
	}
}

func TestFollowsService_Follow_Idempotent(t *testing.T) {
	// Store.CreateFollow's on-conflict-do-nothing means a repeat call never
	// surfaces an error — this just asserts the service doesn't invent one.
	svc := NewFollowsService(fakeFollowsStore{exists: true})
	catID := uuid.New().String()
	userID := uuid.New().String()
	deviceID := uuid.New().String()

	if err := svc.Follow(context.Background(), catID, userID, deviceID); err != nil {
		t.Fatalf("first follow: %v", err)
	}
	if err := svc.Follow(context.Background(), catID, userID, deviceID); err != nil {
		t.Fatalf("repeat follow: %v", err)
	}
}

func TestFollowsService_Follow_ExistsCheckError(t *testing.T) {
	svc := NewFollowsService(fakeFollowsStore{existsErr: errors.New("db down")})
	err := svc.Follow(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String())
	if err == nil {
		t.Fatal("expected error from db, got nil")
	}
	if errors.Is(err, ErrCatNotFound) {
		t.Errorf("db error must not be reported as ErrCatNotFound, got %v", err)
	}
}

func TestFollowsService_Follow_CreateError(t *testing.T) {
	svc := NewFollowsService(fakeFollowsStore{exists: true, createErr: errors.New("db down")})
	err := svc.Follow(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String())
	if err == nil {
		t.Fatal("expected error from db, got nil")
	}
}

// ── Unfollow ──────────────────────────────────────────────────────────────

func TestFollowsService_Unfollow_Success(t *testing.T) {
	var captured repository.DeleteFollowParams
	svc := NewFollowsService(fakeFollowsStore{exists: true, deletedArg: &captured})

	catID := uuid.New()
	userID := uuid.New()
	if err := svc.Unfollow(context.Background(), catID.String(), userID.String()); err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if uuid.UUID(captured.CatID.Bytes) != catID {
		t.Errorf("expected cat id %s, got %s", catID, uuid.UUID(captured.CatID.Bytes))
	}
	if uuid.UUID(captured.UserID.Bytes) != userID {
		t.Errorf("expected user id %s, got %s", userID, uuid.UUID(captured.UserID.Bytes))
	}
}

func TestFollowsService_Unfollow_InvalidCatID(t *testing.T) {
	svc := NewFollowsService(fakeFollowsStore{exists: true})
	err := svc.Unfollow(context.Background(), "not-a-uuid", uuid.New().String())
	if !errors.Is(err, ErrInvalidCatID) {
		t.Fatalf("expected ErrInvalidCatID, got %v", err)
	}
}

func TestFollowsService_Unfollow_UnknownCat(t *testing.T) {
	svc := NewFollowsService(fakeFollowsStore{exists: false})
	err := svc.Unfollow(context.Background(), uuid.New().String(), uuid.New().String())
	if !errors.Is(err, ErrCatNotFound) {
		t.Fatalf("expected ErrCatNotFound, got %v", err)
	}
}

func TestFollowsService_Unfollow_NotFollowingIsIdempotent(t *testing.T) {
	// DeleteFollow on a nonexistent relationship deletes zero rows; the fake
	// returns nil either way, mirroring the real query's behavior.
	svc := NewFollowsService(fakeFollowsStore{exists: true})
	if err := svc.Unfollow(context.Background(), uuid.New().String(), uuid.New().String()); err != nil {
		t.Fatalf("expected no error unfollowing a cat never followed, got %v", err)
	}
}

// ── ListFollows ───────────────────────────────────────────────────────────

func TestFollowsService_ListFollows_ScopedToUser(t *testing.T) {
	var captured pgtype.UUID
	svc := NewFollowsService(fakeFollowsStore{capturedUserID: &captured})

	userID := uuid.New()
	if _, err := svc.ListFollows(context.Background(), userID.String()); err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if uuid.UUID(captured.Bytes) != userID {
		t.Errorf("expected query scoped to user %s, got %s", userID, uuid.UUID(captured.Bytes))
	}
}

func TestFollowsService_ListFollows_InvalidUserID(t *testing.T) {
	svc := NewFollowsService(fakeFollowsStore{})
	_, err := svc.ListFollows(context.Background(), "not-a-uuid")
	if err == nil {
		t.Fatal("expected error for invalid user id, got nil")
	}
}

func TestFollowsService_ListFollows_MapsCatSummary(t *testing.T) {
	fixedNow := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	id := uuid.New()
	svc := NewFollowsService(fakeFollowsStore{rows: []repository.ListFollowedCatsRow{
		{
			ID:                 pgtype.UUID{Bytes: id, Valid: true},
			Name:               pgtype.Text{String: "tekir", Valid: true},
			PhotoUrl:           "https://placecats.com/millie/300/200",
			Lng:                28.9744,
			Lat:                41.0256,
			AreaLabel:          pgtype.Text{String: "Galata Kulesi çevresi, Beyoğlu", Valid: true},
			LastUpdateAt:       pgtype.Timestamptz{Time: fixedNow.Add(-time.Hour), Valid: true},
			NeedsHelpCategory:  pgtype.Text{String: "injured_or_sick", Valid: true},
			NeedsHelpCreatedAt: pgtype.Timestamptz{Time: fixedNow.Add(-2 * time.Hour), Valid: true},
			NeedsHelpExpiresAt: pgtype.Timestamptz{Time: fixedNow.Add(time.Hour), Valid: true},
		},
	}}, WithFollowsClock(func() time.Time { return fixedNow }))

	cats, err := svc.ListFollows(context.Background(), uuid.New().String())
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(cats) != 1 {
		t.Fatalf("expected 1 cat, got %d", len(cats))
	}
	c := cats[0]
	if c.ID != id.String() {
		t.Errorf("expected id %s, got %s", id.String(), c.ID)
	}
	if c.Name != "tekir" {
		t.Errorf("expected name %q, got %q", "tekir", c.Name)
	}
	if c.ActiveAlert == nil || c.ActiveAlert.Category != "injured_or_sick" {
		t.Errorf("expected active injured_or_sick alert, got %v", c.ActiveAlert)
	}
	if c.LastUpdateAt == nil || !c.LastUpdateAt.Equal(fixedNow.Add(-time.Hour)) {
		t.Errorf("unexpected last_update_at: %v", c.LastUpdateAt)
	}
}

func TestFollowsService_ListFollows_NullLastUpdateAt(t *testing.T) {
	id := uuid.New()
	svc := NewFollowsService(fakeFollowsStore{rows: []repository.ListFollowedCatsRow{
		{
			ID:       pgtype.UUID{Bytes: id, Valid: true},
			Name:     pgtype.Text{String: "never updated", Valid: true},
			PhotoUrl: "https://placecats.com/millie/300/200",
			Lng:      28.9744,
			Lat:      41.0256,
			// LastUpdateAt intentionally left zero-value (Valid: false).
		},
	}})

	cats, err := svc.ListFollows(context.Background(), uuid.New().String())
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(cats) != 1 {
		t.Fatalf("expected 1 cat, got %d", len(cats))
	}
	if cats[0].LastUpdateAt != nil {
		t.Errorf("expected nil last_update_at for a never-updated cat, got %v", cats[0].LastUpdateAt)
	}
	if cats[0].ActiveAlert != nil {
		t.Errorf("expected no active alert, got %v", cats[0].ActiveAlert)
	}
}

func TestFollowsService_ListFollows_Empty(t *testing.T) {
	svc := NewFollowsService(fakeFollowsStore{rows: nil})
	cats, err := svc.ListFollows(context.Background(), uuid.New().String())
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(cats) != 0 {
		t.Fatalf("expected 0 cats, got %d", len(cats))
	}
}

func TestFollowsService_ListFollows_StoreError(t *testing.T) {
	svc := NewFollowsService(fakeFollowsStore{listErr: errors.New("db down")})
	_, err := svc.ListFollows(context.Background(), uuid.New().String())
	if err == nil {
		t.Fatal("expected error from db, got nil")
	}
}
