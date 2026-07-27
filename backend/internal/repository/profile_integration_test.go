package repository_test

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// TestStore_ListUserOrdinaryUpdatesForBadges_ExcludesOtherUsersAndDeleted
// proves the badge-derivation query is scoped to exactly one account's own
// non-deleted ordinary updates, oldest first.
func TestStore_ListUserOrdinaryUpdatesForBadges_ExcludesOtherUsersAndDeleted(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "badge derivation cat")
	me := createTestUser(t, ctx, store)
	someoneElse := createTestUser(t, ctx, store)

	base := time.Date(2026, 4, 1, 9, 0, 0, 0, time.UTC)
	mine := createTestOwnedUpdate(t, ctx, store, catID, me, base, []string{"seen"}, "mine")
	createTestOwnedUpdate(t, ctx, store, catID, someoneElse, base.Add(time.Minute), []string{"fed"}, "not mine")
	toDelete := createTestOwnedUpdate(t, ctx, store, catID, me, base.Add(2*time.Minute), []string{"fed"}, "will be deleted")

	if _, err := store.DeleteOwnUpdate(ctx, repository.DeleteOwnUpdateParams{
		ID: toDelete, CatID: catID, AuthorUserID: me,
		DeletedAt:   pgtype.Timestamptz{Time: base.Add(3 * time.Minute), Valid: true},
		WindowStart: pgtype.Timestamptz{Time: base.Add(-time.Minute), Valid: true},
	}); err != nil {
		t.Fatalf("delete: %v", err)
	}

	rows, err := store.ListUserOrdinaryUpdatesForBadges(ctx, me)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 1 || rows[0].CatID != catID {
		t.Fatalf("expected exactly the one live update authored by me, got %+v", rows)
	}
	// the surviving row must be the first ("mine"), not the second,
	// soft-deleted one — both share author/cat, so distinguish by statuses.
	if len(rows[0].Statuses) != 1 || rows[0].Statuses[0] != "seen" {
		t.Errorf("expected the surviving row to be the first ('seen') update, got statuses %v", rows[0].Statuses)
	}
	_ = mine
}

func TestStore_ListUserNeedsHelpUpdatesForBadges_ScopedToAuthor(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "needs-help badge cat")
	me := createTestUser(t, ctx, store)
	someoneElse := createTestUser(t, ctx, store)

	createdAt := time.Now()
	if _, err := store.CreateUpdate(ctx, repository.CreateUpdateParams{
		ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}, CatID: catID, Kind: "needs_help",
		CreatedAt:          pgtype.Timestamptz{Time: createdAt, Valid: true},
		NeedsHelpCategory:  pgtype.Text{String: "trapped", Valid: true},
		NeedsHelpExpiresAt: pgtype.Timestamptz{Time: createdAt.Add(72 * time.Hour), Valid: true},
		AuthorUserID:       me,
	}); err != nil {
		t.Fatalf("seed my needs-help update: %v", err)
	}
	if _, err := store.CreateUpdate(ctx, repository.CreateUpdateParams{
		ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}, CatID: catID, Kind: "needs_help",
		CreatedAt:          pgtype.Timestamptz{Time: createdAt, Valid: true},
		NeedsHelpCategory:  pgtype.Text{String: "food_needed", Valid: true},
		NeedsHelpExpiresAt: pgtype.Timestamptz{Time: createdAt.Add(72 * time.Hour), Valid: true},
		AuthorUserID:       someoneElse,
	}); err != nil {
		t.Fatalf("seed someone else's needs-help update: %v", err)
	}

	rows, err := store.ListUserNeedsHelpUpdatesForBadges(ctx, me)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 1 || rows[0].NeedsHelpCategory.String != "trapped" {
		t.Fatalf("expected exactly my one needs-help update, got %+v", rows)
	}
}

func TestStore_ListUserCreatedCatsForBadges_ScopedToCreator(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	me := createTestUser(t, ctx, store)
	catID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.CreateCat(ctx, repository.CreateCatParams{
		ID: catID, Name: pgtype.Text{String: "created by me", Valid: true},
		Lng: 28.9744, Lat: 41.0256, CreatedByUserID: me,
	}); err != nil {
		t.Fatalf("create cat: %v", err)
	}
	// a cat created by someone else (or seeded with no creator at all) must
	// never show up in my own created-cats list.
	upsertTestCat(t, ctx, store, "not created by me")

	rows, err := store.ListUserCreatedCatsForBadges(ctx, me)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 1 || rows[0].CatID != catID {
		t.Fatalf("expected exactly the one cat I created, got %+v", rows)
	}
}

func TestStore_GetCatSummariesByIDs_ResolvesPrimaryPhoto(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "summary target")

	rows, err := store.GetCatSummariesByIDs(ctx, []pgtype.UUID{catID})
	if err != nil {
		t.Fatalf("get summaries: %v", err)
	}
	if len(rows) != 1 || rows[0].Name.String != "summary target" {
		t.Fatalf("unexpected summaries: %+v", rows)
	}
	if rows[0].PhotoUrl == "" {
		t.Error("expected a resolved primary photo for a seeded cat with photo_url set")
	}
}
