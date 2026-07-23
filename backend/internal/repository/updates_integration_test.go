package repository_test

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// newTestStore connects to DATABASE_URL, skipping the test if it isn't set
// (mirrors cats_integration_test.go: requires a real, migrated database).
func newTestStore(t *testing.T) *repository.Store {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set, skipping integration test")
	}

	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)

	return repository.NewStore(pool)
}

func upsertTestCat(t *testing.T, ctx context.Context, store *repository.Store, name string) pgtype.UUID {
	t.Helper()
	id := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.UpsertCat(ctx, repository.UpsertCatParams{
		ID:       id,
		Name:     pgtype.Text{String: name, Valid: true},
		Lng:      28.9744,
		Lat:      41.0256,
		PhotoUrl: pgtype.Text{String: "https://placecats.com/millie/300/200", Valid: true},
		Status:   "active",
	}); err != nil {
		t.Fatalf("upsert cat %s: %v", name, err)
	}
	return id
}

func createTestUpdate(t *testing.T, ctx context.Context, store *repository.Store, catID pgtype.UUID, createdAt time.Time, statuses []string, comment string) {
	t.Helper()
	var commentText pgtype.Text
	if comment != "" {
		commentText = pgtype.Text{String: comment, Valid: true}
	}

	row, err := store.CreateUpdate(ctx, repository.CreateUpdateParams{
		ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
		CatID:     catID,
		Comment:   commentText,
		CreatedAt: pgtype.Timestamptz{Time: createdAt, Valid: true},
	})
	if err != nil {
		t.Fatalf("create update: %v", err)
	}
	for _, status := range statuses {
		if err := store.CreateUpdateStatus(ctx, repository.CreateUpdateStatusParams{
			UpdateID: row.ID,
			Status:   status,
		}); err != nil {
			t.Fatalf("create update status %s: %v", status, err)
		}
	}
}

func TestStore_GetCatByID(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "tekir")

	row, err := store.GetCatByID(ctx, id)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if row.Name.String != "tekir" {
		t.Errorf("expected name %q, got %q", "tekir", row.Name.String)
	}
}

func TestStore_GetCatByID_UnknownCat(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	_, err := store.GetCatByID(ctx, pgtype.UUID{Bytes: uuid.New(), Valid: true})
	if !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("expected pgx.ErrNoRows, got %v", err)
	}
}

func TestStore_CatExists(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "tekir")

	exists, err := store.CatExists(ctx, id)
	if err != nil {
		t.Fatalf("exists: %v", err)
	}
	if !exists {
		t.Error("expected existing cat to report exists=true")
	}

	exists, err = store.CatExists(ctx, pgtype.UUID{Bytes: uuid.New(), Valid: true})
	if err != nil {
		t.Fatalf("exists: %v", err)
	}
	if exists {
		t.Error("expected unknown cat to report exists=false")
	}
}

func TestStore_ListCatUpdates_EmptyHistory(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "no history yet")

	rows, err := store.ListCatUpdates(ctx, repository.ListCatUpdatesParams{CatID: id, RowLimit: 20})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 0 {
		t.Errorf("expected no updates, got %d", len(rows))
	}
}

func TestStore_ListCatUpdates_NewestFirstWithTieBreaker(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "with history")

	base := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	// two updates share the exact same created_at: seq must break the tie.
	createTestUpdate(t, ctx, store, id, base.Add(-time.Hour), []string{"seen"}, "")
	createTestUpdate(t, ctx, store, id, base, []string{"fed"}, "")
	createTestUpdate(t, ctx, store, id, base, []string{"seen", "water_provided"}, "topped up water")

	rows, err := store.ListCatUpdates(ctx, repository.ListCatUpdatesParams{CatID: id, RowLimit: 20})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 3 {
		t.Fatalf("expected 3 updates, got %d", len(rows))
	}

	// newest first: the two same-created_at rows come before the older one,
	// ordered between themselves by seq desc (insertion order, since seq is
	// a bigserial) — i.e. the later insert (with the comment) comes first.
	if rows[0].Comment.String != "topped up water" {
		t.Errorf("expected the most recently inserted same-timestamp row first, got comment %q", rows[0].Comment.String)
	}
	if rows[1].Seq.Int64 >= rows[0].Seq.Int64 {
		t.Errorf("expected seq to strictly decrease across the tie, got %d then %d", rows[0].Seq.Int64, rows[1].Seq.Int64)
	}
	if !rows[2].CreatedAt.Time.Equal(base.Add(-time.Hour)) {
		t.Errorf("expected the oldest update last, got created_at %v", rows[2].CreatedAt.Time)
	}
}

func TestStore_ListCatUpdates_Pagination(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "paginated")

	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	for i := 0; i < 5; i++ {
		createTestUpdate(t, ctx, store, id, base.Add(time.Duration(i)*time.Hour), []string{"seen"}, "")
	}

	firstPage, err := store.ListCatUpdates(ctx, repository.ListCatUpdatesParams{CatID: id, RowLimit: 2})
	if err != nil {
		t.Fatalf("first page: %v", err)
	}
	if len(firstPage) != 2 {
		t.Fatalf("expected 2 rows on the first page, got %d", len(firstPage))
	}
	// newest first: hour 4, then hour 3.
	if !firstPage[0].CreatedAt.Time.Equal(base.Add(4 * time.Hour)) {
		t.Errorf("expected newest update first, got %v", firstPage[0].CreatedAt.Time)
	}
	if !firstPage[1].CreatedAt.Time.Equal(base.Add(3 * time.Hour)) {
		t.Errorf("expected second-newest update second, got %v", firstPage[1].CreatedAt.Time)
	}

	last := firstPage[len(firstPage)-1]
	secondPage, err := store.ListCatUpdates(ctx, repository.ListCatUpdatesParams{
		CatID:           id,
		RowLimit:        2,
		BeforeCreatedAt: last.CreatedAt,
		BeforeSeq:       last.Seq,
	})
	if err != nil {
		t.Fatalf("second page: %v", err)
	}
	if len(secondPage) != 2 {
		t.Fatalf("expected 2 rows on the second page, got %d", len(secondPage))
	}
	if !secondPage[0].CreatedAt.Time.Equal(base.Add(2 * time.Hour)) {
		t.Errorf("expected hour 2 update first on second page, got %v", secondPage[0].CreatedAt.Time)
	}
	if !secondPage[1].CreatedAt.Time.Equal(base.Add(1 * time.Hour)) {
		t.Errorf("expected hour 1 update second on second page, got %v", secondPage[1].CreatedAt.Time)
	}

	// no overlap between pages.
	for _, r := range secondPage {
		if r.ID == firstPage[0].ID || r.ID == firstPage[1].ID {
			t.Error("second page must not repeat a row already served on the first page")
		}
	}
}

func TestStore_ListCatUpdates_NoCommentIsNull(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "quiet visit")
	createTestUpdate(t, ctx, store, id, time.Now(), []string{"seen"}, "")

	rows, err := store.ListCatUpdates(ctx, repository.ListCatUpdatesParams{CatID: id, RowLimit: 20})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 update, got %d", len(rows))
	}
	if rows[0].Comment.Valid {
		t.Errorf("expected no comment, got %q", rows[0].Comment.String)
	}
}
