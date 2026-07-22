// Command seed loads repeatable fixture data for local development.
// It is idempotent: running it twice leaves the same rows in place.
package main

import (
	"context"
	"log"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/okanck/catsofistanbul/backend/internal/config"
	"github.com/okanck/catsofistanbul/backend/internal/repository"
)

// fixed so re-running the seed updates the same row instead of duplicating it.
var seedPingID = pgtype.UUID{
	Bytes: uuid.MustParse("00000000-0000-4000-8000-000000000001"),
	Valid: true,
}

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	ctx := context.Background()
	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()

	store := repository.NewStore(pool)

	row, err := store.UpsertWorkspacePing(ctx, repository.UpsertWorkspacePingParams{
		ID:      seedPingID,
		Message: "cats of istanbul workspace seeded",
		Lng:     28.9784, // istanbul
		Lat:     41.0082,
	})
	if err != nil {
		return err
	}

	log.Printf("seeded workspace_pings row %s: %q", row.ID, row.Message)
	return nil
}
