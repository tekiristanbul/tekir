package repository_test

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// createTestDevice registers a device row directly through the store, the
// same way service.DevicesService.Register does, so follows tests have a
// real device_id to satisfy the follows.device_id foreign key.
func createTestDevice(t *testing.T, ctx context.Context, store *repository.Store) pgtype.UUID {
	t.Helper()
	id := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	hash := service.HashDeviceToken("follows-test-token-" + uuid.New().String())
	if _, err := store.CreateDevice(ctx, repository.CreateDeviceParams{
		ID:        id,
		TokenHash: hash,
		Platform:  "web",
	}); err != nil {
		t.Fatalf("create device: %v", err)
	}
	return id
}

// createTestUser creates an account row directly through the store, the
// same way AuthService.resolveOrCreateUser does, so follows tests have a
// real user_id to satisfy the follows.user_id foreign key (issue #65).
func createTestUser(t *testing.T, ctx context.Context, store *repository.Store) pgtype.UUID {
	t.Helper()
	id := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.CreateUser(ctx, repository.CreateUserParams{
		ID:              id,
		Phone:           "+90555" + testDigits(t),
		PhoneVerifiedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}); err != nil {
		t.Fatalf("create user: %v", err)
	}
	return id
}

func TestStore_CreateFollow_Idempotent(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "tekir")
	userID := createTestUser(t, ctx, store)

	for i := 0; i < 3; i++ {
		if err := store.CreateFollow(ctx, repository.CreateFollowParams{UserID: userID, CatID: catID}); err != nil {
			t.Fatalf("create follow attempt %d: %v", i, err)
		}
	}

	rows, err := store.ListFollowedCats(ctx, userID)
	if err != nil {
		t.Fatalf("list follows: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected exactly 1 follow row after repeat follows, got %d", len(rows))
	}
}

func TestStore_CreateFollow_ConcurrentDuplicate(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "tekir")
	userID := createTestUser(t, ctx, store)

	const n = 10
	var wg sync.WaitGroup
	errs := make([]error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			errs[i] = store.CreateFollow(ctx, repository.CreateFollowParams{UserID: userID, CatID: catID})
		}(i)
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Fatalf("concurrent create follow %d: %v", i, err)
		}
	}

	rows, err := store.ListFollowedCats(ctx, userID)
	if err != nil {
		t.Fatalf("list follows: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected exactly 1 follow row after concurrent duplicate follows, got %d", len(rows))
	}
}

func TestStore_CreateFollow_WithDeviceAssociation_PersistsBoth(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "tekir")
	userID := createTestUser(t, ctx, store)
	deviceID := createTestDevice(t, ctx, store)

	if err := store.CreateFollow(ctx, repository.CreateFollowParams{UserID: userID, DeviceID: deviceID, CatID: catID}); err != nil {
		t.Fatalf("create follow: %v", err)
	}

	rows, err := store.ListFollowedCats(ctx, userID)
	if err != nil {
		t.Fatalf("list follows: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected exactly 1 follow row, got %d", len(rows))
	}
}

// TestStore_CreateFollow_DeviceOnlyLegacyRowStillReadable proves a
// pre-issue-#65 device-only follow row (no user_id) remains valid under the
// new schema — it doesn't violate the owner check constraint or the new
// partial unique indexes, it just isn't returned by the now user_id-scoped
// ListFollowedCats until the owning device is linked to an account (see
// AuthService.linkDevice's backfill, exercised in auth_integration_test.go).
func TestStore_CreateFollow_DeviceOnlyLegacyRowStillReadable(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "tekir")
	deviceID := createTestDevice(t, ctx, store)

	// CreateFollow with no UserID reproduces the shape every pre-#65
	// follow row has: device_id set, user_id null — exactly what
	// AuthService.linkDevice's backfill later needs to find and update.
	if err := store.CreateFollow(ctx, repository.CreateFollowParams{DeviceID: deviceID, CatID: catID}); err != nil {
		t.Fatalf("seed legacy device-only follow: %v", err)
	}

	// Not visible to any account yet — it has no user_id.
	userID := createTestUser(t, ctx, store)
	rows, err := store.ListFollowedCats(ctx, userID)
	if err != nil {
		t.Fatalf("list follows: %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("expected the legacy device-only row to stay invisible until linked, got %d rows", len(rows))
	}
}

func TestStore_DeleteFollow_Idempotent(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "tekir")
	userID := createTestUser(t, ctx, store)

	// deleting a follow that never existed must succeed, not error.
	if err := store.DeleteFollow(ctx, repository.DeleteFollowParams{UserID: userID, CatID: catID}); err != nil {
		t.Fatalf("delete nonexistent follow: %v", err)
	}

	if err := store.CreateFollow(ctx, repository.CreateFollowParams{UserID: userID, CatID: catID}); err != nil {
		t.Fatalf("create follow: %v", err)
	}
	if err := store.DeleteFollow(ctx, repository.DeleteFollowParams{UserID: userID, CatID: catID}); err != nil {
		t.Fatalf("first delete: %v", err)
	}
	// repeat delete of an already-removed follow must also succeed.
	if err := store.DeleteFollow(ctx, repository.DeleteFollowParams{UserID: userID, CatID: catID}); err != nil {
		t.Fatalf("repeat delete: %v", err)
	}

	rows, err := store.ListFollowedCats(ctx, userID)
	if err != nil {
		t.Fatalf("list follows: %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("expected 0 follow rows after delete, got %d", len(rows))
	}
}

func TestStore_ListFollowedCats_OrderedByMostRecentActivity(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	userID := createTestUser(t, ctx, store)
	now := time.Now()

	older := upsertTestCat(t, ctx, store, "older")
	newer := upsertTestCat(t, ctx, store, "newer")

	if err := store.UpdateCatLastUpdateAt(ctx, repository.UpdateCatLastUpdateAtParams{
		ID:           older,
		LastUpdateAt: pgtype.Timestamptz{Time: now.Add(-2 * time.Hour), Valid: true},
	}); err != nil {
		t.Fatalf("set older last_update_at: %v", err)
	}
	if err := store.UpdateCatLastUpdateAt(ctx, repository.UpdateCatLastUpdateAtParams{
		ID:           newer,
		LastUpdateAt: pgtype.Timestamptz{Time: now.Add(-time.Hour), Valid: true},
	}); err != nil {
		t.Fatalf("set newer last_update_at: %v", err)
	}

	for _, id := range []pgtype.UUID{older, newer} {
		if err := store.CreateFollow(ctx, repository.CreateFollowParams{UserID: userID, CatID: id}); err != nil {
			t.Fatalf("create follow: %v", err)
		}
	}

	rows, err := store.ListFollowedCats(ctx, userID)
	if err != nil {
		t.Fatalf("list follows: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("expected 2 followed cats, got %d", len(rows))
	}
	if rows[0].ID != newer || rows[1].ID != older {
		t.Fatalf("expected newer activity first (newer, older), got (%v, %v)", rows[0].ID, rows[1].ID)
	}
}

// TestStore_ListFollowedCats_NullLastUpdateAtSortsLast proves a followed cat
// that has never received an update (last_update_at is null) sorts after
// every cat with real activity, matching the query's "desc nulls last" rule
// (issue #44).
func TestStore_ListFollowedCats_NullLastUpdateAtSortsLast(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	userID := createTestUser(t, ctx, store)

	neverUpdated := upsertTestCat(t, ctx, store, "never updated")
	updated := upsertTestCat(t, ctx, store, "updated")

	if err := store.UpdateCatLastUpdateAt(ctx, repository.UpdateCatLastUpdateAtParams{
		ID:           updated,
		LastUpdateAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}); err != nil {
		t.Fatalf("set last_update_at: %v", err)
	}

	for _, id := range []pgtype.UUID{neverUpdated, updated} {
		if err := store.CreateFollow(ctx, repository.CreateFollowParams{UserID: userID, CatID: id}); err != nil {
			t.Fatalf("create follow: %v", err)
		}
	}

	rows, err := store.ListFollowedCats(ctx, userID)
	if err != nil {
		t.Fatalf("list follows: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("expected 2 followed cats, got %d", len(rows))
	}
	if rows[0].ID != updated {
		t.Fatalf("expected the cat with real activity first, got %v", rows[0].ID)
	}
	if rows[1].ID != neverUpdated || rows[1].LastUpdateAt.Valid {
		t.Fatalf("expected the never-updated cat last with a null last_update_at, got %v (valid=%v)", rows[1].ID, rows[1].LastUpdateAt.Valid)
	}
}

// TestStore_ListFollowedCats_TieBreaksByCatIDDescending proves two followed
// cats with an identical last_update_at (including both null) fall back to
// `id desc` as an explicit, deterministic tie-breaker (issue #44) rather
// than depending on incidental table/index order.
func TestStore_ListFollowedCats_TieBreaksByCatIDDescending(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	userID := createTestUser(t, ctx, store)
	same := time.Now()

	a := upsertTestCat(t, ctx, store, "a")
	b := upsertTestCat(t, ctx, store, "b")
	for _, id := range []pgtype.UUID{a, b} {
		if err := store.UpdateCatLastUpdateAt(ctx, repository.UpdateCatLastUpdateAtParams{
			ID:           id,
			LastUpdateAt: pgtype.Timestamptz{Time: same, Valid: true},
		}); err != nil {
			t.Fatalf("set last_update_at: %v", err)
		}
		if err := store.CreateFollow(ctx, repository.CreateFollowParams{UserID: userID, CatID: id}); err != nil {
			t.Fatalf("create follow: %v", err)
		}
	}

	rows, err := store.ListFollowedCats(ctx, userID)
	if err != nil {
		t.Fatalf("list follows: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("expected 2 followed cats, got %d", len(rows))
	}

	wantFirst, wantSecond := a, b
	if uuid.UUID(b.Bytes).String() > uuid.UUID(a.Bytes).String() {
		wantFirst, wantSecond = b, a
	}
	if rows[0].ID != wantFirst || rows[1].ID != wantSecond {
		t.Fatalf("expected id-desc tie-break order (%v, %v), got (%v, %v)", wantFirst, wantSecond, rows[0].ID, rows[1].ID)
	}
}

// TestStore_ListFollowedCats_UserIsolation proves one account's follows are
// never returned for another account (issue #65's core auth boundary).
func TestStore_ListFollowedCats_UserIsolation(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	userA := createTestUser(t, ctx, store)
	userB := createTestUser(t, ctx, store)
	catA := upsertTestCat(t, ctx, store, "cat-a")
	catB := upsertTestCat(t, ctx, store, "cat-b")

	if err := store.CreateFollow(ctx, repository.CreateFollowParams{UserID: userA, CatID: catA}); err != nil {
		t.Fatalf("create follow for user A: %v", err)
	}
	if err := store.CreateFollow(ctx, repository.CreateFollowParams{UserID: userB, CatID: catB}); err != nil {
		t.Fatalf("create follow for user B: %v", err)
	}

	rowsA, err := store.ListFollowedCats(ctx, userA)
	if err != nil {
		t.Fatalf("list follows for user A: %v", err)
	}
	if len(rowsA) != 1 || rowsA[0].ID != catA {
		t.Fatalf("expected user A to see only cat A, got %+v", rowsA)
	}

	rowsB, err := store.ListFollowedCats(ctx, userB)
	if err != nil {
		t.Fatalf("list follows for user B: %v", err)
	}
	if len(rowsB) != 1 || rowsB[0].ID != catB {
		t.Fatalf("expected user B to see only cat B, got %+v", rowsB)
	}
}

func TestStore_CatExists_ForFollows(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "tekir")

	exists, err := store.CatExists(ctx, catID)
	if err != nil {
		t.Fatalf("cat exists: %v", err)
	}
	if !exists {
		t.Error("expected existing cat to report exists=true")
	}

	exists, err = store.CatExists(ctx, pgtype.UUID{Bytes: uuid.New(), Valid: true})
	if err != nil {
		t.Fatalf("cat exists (unknown): %v", err)
	}
	if exists {
		t.Error("expected unknown cat to report exists=false")
	}
}
