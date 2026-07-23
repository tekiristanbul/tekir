// Command seed loads repeatable fixture data for local development.
// It is idempotent: running it twice leaves the same rows in place.
package main

import (
	"context"
	"log"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/tekiristanbul/tekir/backend/internal/config"
	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// fixed so re-running the seed updates the same row instead of duplicating it.
var seedPingID = pgtype.UUID{
	Bytes: uuid.MustParse("00000000-0000-4000-8000-000000000001"),
	Valid: true,
}

// wikimedia commons photos, cycled across fixture cats. placecats.com was
// tried first but sends no Access-Control-Allow-Origin header, which the
// flutter web build needs to fetch and decode marker images; commons serves
// every file with `access-control-allow-origin: *`.
var seedPhotos = []string{
	"https://upload.wikimedia.org/wikipedia/commons/thumb/0/01/Calico_cat%2C_-_Assisi%2C_Italy.jpg/500px-Calico_cat%2C_-_Assisi%2C_Italy.jpg",
	"https://upload.wikimedia.org/wikipedia/commons/thumb/4/4d/Cat_November_2010-1a.jpg/500px-Cat_November_2010-1a.jpg",
	"https://upload.wikimedia.org/wikipedia/commons/thumb/4/46/Cat_Street_Tokyo_2.JPG/500px-Cat_Street_Tokyo_2.JPG",
	"https://upload.wikimedia.org/wikipedia/commons/thumb/2/2a/Cat_in_Efremov%2C_Russia1.jpg/500px-Cat_in_Efremov%2C_Russia1.jpg",
	"https://upload.wikimedia.org/wikipedia/commons/thumb/e/ed/Cat_nose_face.jpg/500px-Cat_nose_face.jpg",
	"https://upload.wikimedia.org/wikipedia/commons/thumb/7/72/Cat_playing_with_a_lizard.jpg/500px-Cat_playing_with_a_lizard.jpg",
}

// a tight cluster near galata tower (walking distance apart, for clustering)
// plus a few cats further out (taksim, cihangir, kadıköy across the strait)
// so panning the map away from the cluster demonstrates the bbox refetch.
var seedCats = []struct {
	id        string
	name      string
	lat, lng  float64
	needsHelp bool
}{
	{"00000000-0000-4000-8000-000000000010", "tekir", 41.02561, 28.97440, false},
	{"00000000-0000-4000-8000-000000000011", "boncuk", 41.02575, 28.97455, false},
	{"00000000-0000-4000-8000-000000000012", "duman", 41.02548, 28.97430, true},
	{"00000000-0000-4000-8000-000000000013", "pamuk", 41.02590, 28.97465, false},
	{"00000000-0000-4000-8000-000000000014", "sarman", 41.02530, 28.97410, false},
	{"00000000-0000-4000-8000-000000000015", "minnoş", 41.02605, 28.97480, false},
	{"00000000-0000-4000-8000-000000000016", "zeytin", 41.02515, 28.97395, false},
	{"00000000-0000-4000-8000-000000000017", "taksim kedisi", 41.03700, 28.98500, false},
	{"00000000-0000-4000-8000-000000000018", "cihangir kedisi", 41.03160, 28.98360, false},
	{"00000000-0000-4000-8000-000000000019", "kadıköy kedisi", 40.99110, 29.02690, true},
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

	now := time.Now()
	for i, c := range seedCats {
		var needsHelpUntil pgtype.Timestamptz
		if c.needsHelp {
			needsHelpUntil = pgtype.Timestamptz{Time: now.Add(2 * time.Hour), Valid: true}
		}

		cat, err := store.UpsertCat(ctx, repository.UpsertCatParams{
			ID:             pgtype.UUID{Bytes: uuid.MustParse(c.id), Valid: true},
			Name:           pgtype.Text{String: c.name, Valid: true},
			Lng:            c.lng,
			Lat:            c.lat,
			PhotoUrl:       pgtype.Text{String: seedPhotos[i%len(seedPhotos)], Valid: true},
			Status:         "active",
			LastUpdateAt:   pgtype.Timestamptz{Time: now.Add(-time.Duration(i) * time.Hour), Valid: true},
			NeedsHelpUntil: needsHelpUntil,
		})
		if err != nil {
			return err
		}
		log.Printf("seeded cat %s: %q", cat, c.name)
	}

	return nil
}
