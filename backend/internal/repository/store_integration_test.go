package repository_test

import (
	"context"
	"os"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/okanck/catsofistanbul/backend/internal/repository"
)

// requires a real, migrated database: run `make migrate-up` against the
// docker-compose postgres first, or let CI's postgres service do it.
func TestStore_UpsertAndListWorkspacePings(t *testing.T) {
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

	if err := store.Ping(ctx); err != nil {
		t.Fatalf("ping: %v", err)
	}

	id := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	created, err := store.UpsertWorkspacePing(ctx, repository.UpsertWorkspacePingParams{
		ID:      id,
		Message: "integration test ping",
		Lng:     28.9784,
		Lat:     41.0082,
	})
	if err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if created.Message != "integration test ping" {
		t.Fatalf("expected message to round-trip, got %q", created.Message)
	}

	rows, err := store.ListWorkspacePings(ctx)
	if err != nil {
		t.Fatalf("list: %v", err)
	}

	found := false
	for _, r := range rows {
		if r.ID == id {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("expected seeded row to appear in list")
	}
}
