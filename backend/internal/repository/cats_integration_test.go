package repository_test

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// requires a real, migrated database: run `make migrate-up` against the
// docker-compose postgres first, or let CI's postgres service do it.
func TestStore_ListCatsInBounds(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set, skipping integration test")
	}

	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer pool.Close()

	store := repository.NewStore(pool)

	// galata tower, istanbul.
	const centerLat, centerLng = 41.0256, 28.9744

	insideID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.UpsertCat(ctx, repository.UpsertCatParams{
		ID:           insideID,
		Name:         pgtype.Text{String: "inside cat", Valid: true},
		Lng:          centerLng,
		Lat:          centerLat,
		AreaLabel:    pgtype.Text{String: "Galata Kulesi çevresi, Beyoğlu", Valid: true},
		PhotoUrl:     pgtype.Text{String: "https://placecats.com/millie/300/200", Valid: true},
		Status:       "active",
		LastUpdateAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}); err != nil {
		t.Fatalf("upsert inside cat: %v", err)
	}

	// kadıköy, across the strait — well outside the galata bbox below.
	outsideID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.UpsertCat(ctx, repository.UpsertCatParams{
		ID:           outsideID,
		Name:         pgtype.Text{String: "outside cat", Valid: true},
		Lng:          29.0269,
		Lat:          40.9911,
		PhotoUrl:     pgtype.Text{String: "https://placecats.com/neo/300/200", Valid: true},
		Status:       "active",
		LastUpdateAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}); err != nil {
		t.Fatalf("upsert outside cat: %v", err)
	}

	// inactive cat inside the bbox: must not appear on the map.
	inactiveID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.UpsertCat(ctx, repository.UpsertCatParams{
		ID:           inactiveID,
		Name:         pgtype.Text{String: "inactive cat", Valid: true},
		Lng:          centerLng,
		Lat:          centerLat,
		PhotoUrl:     pgtype.Text{String: "https://placecats.com/bella/300/200", Valid: true},
		Status:       "inactive",
		LastUpdateAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}); err != nil {
		t.Fatalf("upsert inactive cat: %v", err)
	}

	rows, err := store.ListCatsInBounds(ctx, repository.ListCatsInBoundsParams{
		MinLng: 28.9700,
		MinLat: 41.0200,
		MaxLng: 28.9800,
		MaxLat: 41.0300,
	})
	if err != nil {
		t.Fatalf("list: %v", err)
	}

	seen := make(map[pgtype.UUID]bool, len(rows))
	byID := make(map[pgtype.UUID]repository.ListCatsInBoundsRow, len(rows))
	for _, r := range rows {
		seen[r.ID] = true
		byID[r.ID] = r
	}

	if !seen[insideID] {
		t.Error("expected cat inside the bounds to be returned")
	}
	if row, ok := byID[insideID]; ok {
		if row.Name.String != "inside cat" {
			t.Errorf("expected name %q, got %q", "inside cat", row.Name.String)
		}
		if !row.AreaLabel.Valid || row.AreaLabel.String != "Galata Kulesi çevresi, Beyoğlu" {
			t.Errorf("unexpected area_label: %v", row.AreaLabel)
		}
	}
	if seen[outsideID] {
		t.Error("expected cat outside the bounds not to be returned")
	}
	if seen[inactiveID] {
		t.Error("expected inactive cat inside the bounds not to be returned")
	}
}
