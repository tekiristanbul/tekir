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
	"github.com/tekiristanbul/tekir/backend/internal/service"
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
// needs-help state now lives on the updates themselves (see seedNeedsHelp
// below), not as a per-cat boolean.
var seedCats = []struct {
	id        string
	name      string
	lat, lng  float64
	areaLabel string
}{
	{"00000000-0000-4000-8000-000000000010", "tekir", 41.02561, 28.97440, "Galata Kulesi çevresi, Beyoğlu"},
	{"00000000-0000-4000-8000-000000000011", "boncuk", 41.02575, 28.97455, "Galata Kulesi çevresi, Beyoğlu"},
	{"00000000-0000-4000-8000-000000000012", "duman", 41.02548, 28.97430, "Galata Kulesi çevresi, Beyoğlu"},
	{"00000000-0000-4000-8000-000000000013", "pamuk", 41.02590, 28.97465, "Galata Kulesi çevresi, Beyoğlu"},
	{"00000000-0000-4000-8000-000000000014", "sarman", 41.02530, 28.97410, "Galata Kulesi çevresi, Beyoğlu"},
	{"00000000-0000-4000-8000-000000000015", "minnoş", 41.02605, 28.97480, "Galata Kulesi çevresi, Beyoğlu"},
	{"00000000-0000-4000-8000-000000000016", "zeytin", 41.02515, 28.97395, "Galata Kulesi çevresi, Beyoğlu"},
	{"00000000-0000-4000-8000-000000000017", "taksim kedisi", 41.03700, 28.98500, "Taksim Meydanı, Beyoğlu"},
	{"00000000-0000-4000-8000-000000000018", "cihangir kedisi", 41.03160, 28.98360, "Cihangir, Beyoğlu"},
	{"00000000-0000-4000-8000-000000000019", "kadıköy kedisi", 40.99110, 29.02690, "Moda Sahili, Kadıköy"},
}

// tekir gets a multi-update timeline for the map-to-detail demo: newest
// first, a mix of single/multiple structured statuses, and both a commented
// and a comment-less update. boncuk gets a single update. sarman is left
// with no updates at all, so it demonstrates the empty-history state.
var seedUpdates = []struct {
	id, catID string
	hoursAgo  int
	statuses  []string
	comment   string
}{
	{"00000000-0000-4000-8000-000000000020", "00000000-0000-4000-8000-000000000010", 4, []string{"seen"}, ""},
	{"00000000-0000-4000-8000-000000000021", "00000000-0000-4000-8000-000000000010", 3, []string{"fed"}, "duvarın dibine mama bıraktım"},
	{"00000000-0000-4000-8000-000000000022", "00000000-0000-4000-8000-000000000010", 2, []string{"seen", "water_provided"}, ""},
	{"00000000-0000-4000-8000-000000000023", "00000000-0000-4000-8000-000000000010", 1, []string{"seen"}, "hâlâ kulenin çevresinde dolaşıyor"},
	{"00000000-0000-4000-8000-000000000024", "00000000-0000-4000-8000-000000000011", 1, []string{"seen"}, "merdivenlerin orada gördüm"},
}

// seedNeedsHelp (issue #4/#23) deterministically covers every boundary
// case the 72-hour, no-resolve expiry model needs demonstrated:
//   - duman: comfortably active (created 1h ago).
//   - kadıköy kedisi: active, but right at the edge of the 72h window
//     (created 71h30m ago — expires in 30 minutes).
//   - tekir: expired exactly at the 72h boundary (created exactly 72h ago).
//   - boncuk: expired long ago, well past the boundary, and carries no
//     other active alert.
//
// sarman and every other seeded cat intentionally get no needs-help update
// at all, covering the "no active alert, no history of one either" case.
// expires_at is computed here exactly the way the (not-yet-built) write
// endpoint will: created_at + 72h, server-side, never client-supplied.
var seedNeedsHelp = []struct {
	id, catID  string
	createdAgo time.Duration
	category   string
}{
	{"00000000-0000-4000-8000-000000000030", "00000000-0000-4000-8000-000000000012", 1 * time.Hour, "injured_or_sick"},
	{"00000000-0000-4000-8000-000000000031", "00000000-0000-4000-8000-000000000019", 71*time.Hour + 30*time.Minute, "trapped"},
	{"00000000-0000-4000-8000-000000000032", "00000000-0000-4000-8000-000000000010", 72 * time.Hour, "food_needed"},
	{"00000000-0000-4000-8000-000000000033", "00000000-0000-4000-8000-000000000011", 100 * time.Hour, "water_needed"},
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
		Message: "tekir workspace seeded",
		Lng:     28.9784, // istanbul
		Lat:     41.0082,
	})
	if err != nil {
		return err
	}

	log.Printf("seeded workspace_pings row %s: %q", row.ID, row.Message)

	now := time.Now()
	for i, c := range seedCats {
		cat, err := store.UpsertCat(ctx, repository.UpsertCatParams{
			ID:           pgtype.UUID{Bytes: uuid.MustParse(c.id), Valid: true},
			Name:         pgtype.Text{String: c.name, Valid: true},
			Lng:          c.lng,
			Lat:          c.lat,
			AreaLabel:    pgtype.Text{String: c.areaLabel, Valid: true},
			PhotoUrl:     pgtype.Text{String: seedPhotos[i%len(seedPhotos)], Valid: true},
			Status:       "active",
			LastUpdateAt: pgtype.Timestamptz{Time: now.Add(-time.Duration(i) * time.Hour), Valid: true},
		})
		if err != nil {
			return err
		}
		log.Printf("seeded cat %s: %q", cat, c.name)
	}

	for _, u := range seedUpdates {
		var comment pgtype.Text
		if u.comment != "" {
			comment = pgtype.Text{String: u.comment, Valid: true}
		}

		update, err := store.CreateUpdate(ctx, repository.CreateUpdateParams{
			ID:        pgtype.UUID{Bytes: uuid.MustParse(u.id), Valid: true},
			CatID:     pgtype.UUID{Bytes: uuid.MustParse(u.catID), Valid: true},
			Kind:      "ordinary",
			Comment:   comment,
			CreatedAt: pgtype.Timestamptz{Time: now.Add(-time.Duration(u.hoursAgo) * time.Hour), Valid: true},
		})
		if err != nil {
			return err
		}
		for _, status := range u.statuses {
			if err := store.CreateUpdateStatus(ctx, repository.CreateUpdateStatusParams{
				UpdateID: update.ID,
				Status:   status,
			}); err != nil {
				return err
			}
		}
		log.Printf("seeded update %s for cat %s: %v", update.ID, u.catID, u.statuses)
	}

	for _, n := range seedNeedsHelp {
		createdAt := now.Add(-n.createdAgo)
		update, err := store.CreateUpdate(ctx, repository.CreateUpdateParams{
			ID:                 pgtype.UUID{Bytes: uuid.MustParse(n.id), Valid: true},
			CatID:              pgtype.UUID{Bytes: uuid.MustParse(n.catID), Valid: true},
			Kind:               "needs_help",
			CreatedAt:          pgtype.Timestamptz{Time: createdAt, Valid: true},
			NeedsHelpCategory:  pgtype.Text{String: n.category, Valid: true},
			NeedsHelpExpiresAt: pgtype.Timestamptz{Time: service.NeedsHelpExpiresAt(createdAt), Valid: true},
		})
		if err != nil {
			return err
		}
		log.Printf("seeded needs-help update %s for cat %s: %s", update.ID, n.catID, n.category)
	}

	return nil
}
