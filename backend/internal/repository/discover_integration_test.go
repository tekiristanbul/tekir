package repository_test

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// upsertTestCatAt is upsertTestCat's shape with a caller-controlled
// (lat, lng) instead of the fixed Galata coordinate — issue #82's discover
// queries have no radius cutoff (unlike ListNearbyCatsForDuplicateCheck),
// so these tests need cats planted at deliberately different distances from
// a shared reference point rather than all stacked on one landmark.
func upsertTestCatAt(t *testing.T, ctx context.Context, store *repository.Store, name string, lat, lng float64) pgtype.UUID {
	t.Helper()
	return upsertTestCatAtWithStatus(t, ctx, store, name, lat, lng, "active")
}

// upsertTestCatAtWithStatus lets a test plant an inactive cat directly
// (status is set at insert time) rather than upserting active-then-updating
// with a second raw statement — *repository.Store deliberately exposes no
// generic raw-exec method, only its generated queries.
func upsertTestCatAtWithStatus(t *testing.T, ctx context.Context, store *repository.Store, name string, lat, lng float64, status string) pgtype.UUID {
	t.Helper()
	id := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.UpsertCat(ctx, repository.UpsertCatParams{
		ID:       id,
		Name:     pgtype.Text{String: name, Valid: true},
		Lng:      lng,
		Lat:      lat,
		PhotoUrl: pgtype.Text{String: "https://placecats.com/" + name + "/300/200", Valid: true},
		Status:   status,
	}); err != nil {
		t.Fatalf("upsert cat %s: %v", name, err)
	}
	return id
}

// fetchAllCatsByDistance walks every page of ListCatsByDistance from
// (lat, lng), one row at a time (pageSize 1, the smallest possible page —
// the sternest test of the keyset predicate), and returns every row it
// ever saw in the order returned. The database in these integration tests
// is shared with every other test in this package/run (no per-test
// isolation, no radius cutoff on this query) — so a caller filters this
// down to its own known ids rather than asserting on the full list.
func fetchAllCatsByDistance(t *testing.T, ctx context.Context, store *repository.Store, lat, lng float64) []repository.ListCatsByDistanceRow {
	t.Helper()
	var all []repository.ListCatsByDistanceRow
	var after pgtype.Float8
	var afterID pgtype.UUID
	for i := 0; i < 10000; i++ {
		rows, err := store.ListCatsByDistance(ctx, repository.ListCatsByDistanceParams{
			Lat: lat, Lng: lng,
			AfterDistanceM: after,
			AfterID:        afterID,
			RowLimit:       1,
		})
		if err != nil {
			t.Fatalf("list by distance (page %d): %v", i, err)
		}
		if len(rows) == 0 {
			return all
		}
		all = append(all, rows[0])
		after = pgtype.Float8{Float64: rows[0].DistanceM, Valid: true}
		afterID = rows[0].ID
	}
	t.Fatal("fetchAllCatsByDistance: exceeded page-walk safety limit — a keyset predicate bug would loop forever")
	return nil
}

// filterKnownDistance keeps only the rows whose id is in ids, in the order
// they appear in rows — the relative order this test actually cares about.
func filterKnownDistance(rows []repository.ListCatsByDistanceRow, ids map[pgtype.UUID]bool) []repository.ListCatsByDistanceRow {
	var out []repository.ListCatsByDistanceRow
	for _, r := range rows {
		if ids[r.ID] {
			out = append(out, r)
		}
	}
	return out
}

func TestStore_ListCatsByDistance_NearestFirstPaginatedNoDuplicates(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	// an isolated area, away from other tests' fixture coordinates
	// (Galata/Kadıköy) — reduces (but given no radius cutoff, can't
	// eliminate) interleaving with unrelated rows in the full result set.
	const centerLat, centerLng = 40.75, 29.35

	nearest := upsertTestCatAt(t, ctx, store, "nearest"+uuid.NewString()[:8], centerLat, centerLng)
	middle := upsertTestCatAt(t, ctx, store, "middle"+uuid.NewString()[:8], centerLat+0.0005, centerLng)    // ~55m
	farthest := upsertTestCatAt(t, ctx, store, "farthest"+uuid.NewString()[:8], centerLat+0.005, centerLng) // ~555m
	inactive := upsertTestCatAtWithStatus(t, ctx, store, "inactive"+uuid.NewString()[:8], centerLat, centerLng, "inactive")

	all := fetchAllCatsByDistance(t, ctx, store, centerLat, centerLng)

	known := map[pgtype.UUID]bool{nearest: true, middle: true, farthest: true, inactive: true}
	got := filterKnownDistance(all, known)

	if len(got) != 3 {
		t.Fatalf("expected exactly 3 of our 4 planted cats (inactive excluded), got %d: %+v", len(got), got)
	}
	if got[0].ID != nearest || got[1].ID != middle || got[2].ID != farthest {
		t.Fatalf("expected nearest-first order [nearest, middle, farthest], got [%v, %v, %v]", got[0].ID, got[1].ID, got[2].ID)
	}
	if got[0].DistanceM >= got[1].DistanceM || got[1].DistanceM >= got[2].DistanceM {
		t.Errorf("expected strictly increasing distance_m, got %v, %v, %v", got[0].DistanceM, got[1].DistanceM, got[2].DistanceM)
	}

	// page-1-at-a-time walking must never repeat a row: verify no id was
	// seen twice across the whole walk (a keyset-predicate-off-by-one bug
	// would show up here as duplicates or an infinite loop).
	seen := make(map[pgtype.UUID]int, len(all))
	for _, r := range all {
		seen[r.ID]++
	}
	for id, count := range seen {
		if count > 1 {
			t.Errorf("row %v was returned %d times across the paginated walk", id, count)
		}
	}
}

func TestStore_ListCatsByDistance_DeterministicTieBreak(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	const lat, lng = 40.76, 29.36 // another isolated area

	a := upsertTestCatAt(t, ctx, store, "tie-a-"+uuid.NewString()[:8], lat, lng)
	b := upsertTestCatAt(t, ctx, store, "tie-b-"+uuid.NewString()[:8], lat, lng) // identical coordinates: distance_m ties exactly

	all := fetchAllCatsByDistance(t, ctx, store, lat, lng)
	known := map[pgtype.UUID]bool{a: true, b: true}
	got := filterKnownDistance(all, known)

	if len(got) != 2 {
		t.Fatalf("expected both tied cats, got %d", len(got))
	}
	if got[0].DistanceM != got[1].DistanceM {
		t.Fatalf("expected an exact distance tie, got %v and %v", got[0].DistanceM, got[1].DistanceM)
	}

	// the tie-break is c.id ascending (see ListCatsByDistance's query
	// comment) — deterministic and repeatable, not "whichever the
	// database feels like on a given call".
	wantFirst, wantSecond := a, b
	if uuid.UUID(b.Bytes).String() < uuid.UUID(a.Bytes).String() {
		wantFirst, wantSecond = b, a
	}
	if got[0].ID != wantFirst || got[1].ID != wantSecond {
		t.Errorf("expected id-ascending tie-break order [%v, %v], got [%v, %v]", wantFirst, wantSecond, got[0].ID, got[1].ID)
	}
}

func TestStore_ListActiveNeedsHelpCatsByDistance_FiltersAndOrders(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	const centerLat, centerLng = 40.77, 29.37
	now := time.Now()

	activeNear := upsertTestCatAt(t, ctx, store, "active-near-"+uuid.NewString()[:8], centerLat, centerLng)
	createNeedsHelpUpdateAt(t, ctx, store, activeNear, now.Add(-time.Hour), "injured_or_sick", now.Add(time.Hour))

	activeFar := upsertTestCatAt(t, ctx, store, "active-far-"+uuid.NewString()[:8], centerLat+0.005, centerLng)
	createNeedsHelpUpdateAt(t, ctx, store, activeFar, now.Add(-time.Hour), "trapped", now.Add(time.Hour))

	expired := upsertTestCatAt(t, ctx, store, "expired-"+uuid.NewString()[:8], centerLat+0.0002, centerLng)
	createNeedsHelpUpdateAt(t, ctx, store, expired, now.Add(-73*time.Hour), "food_needed", now.Add(-time.Hour))

	noAlert := upsertTestCatAt(t, ctx, store, "no-alert-"+uuid.NewString()[:8], centerLat+0.0003, centerLng)

	rows, err := store.ListActiveNeedsHelpCatsByDistance(ctx, repository.ListActiveNeedsHelpCatsByDistanceParams{
		Lat: centerLat, Lng: centerLng,
		Now:      pgtype.Timestamptz{Time: now, Valid: true},
		RowLimit: 10000,
	})
	if err != nil {
		t.Fatalf("list active needs-help by distance: %v", err)
	}

	known := map[pgtype.UUID]bool{activeNear: true, activeFar: true, expired: true, noAlert: true}
	var got []repository.ListActiveNeedsHelpCatsByDistanceRow
	for _, r := range rows {
		if known[r.ID] {
			got = append(got, r)
		}
	}

	if len(got) != 2 {
		t.Fatalf("expected exactly the 2 cats with a currently active alert, got %d: %+v", len(got), got)
	}
	if got[0].ID != activeNear || got[1].ID != activeFar {
		t.Fatalf("expected nearest-first order [activeNear, activeFar], got [%v, %v]", got[0].ID, got[1].ID)
	}
	for _, r := range got {
		if !r.NeedsHelpExpiresAt.Valid || !r.NeedsHelpExpiresAt.Time.After(now) {
			t.Errorf("expected an unexpired needs_help_expires_at for %v, got %v", r.ID, r.NeedsHelpExpiresAt)
		}
	}
}

// createNeedsHelpUpdateAt mirrors createNeedsHelpUpdate (updates_integration_test.go)
// but accepts an explicit expiresAt instead of always createdAt+72h, so this
// test can construct an already-expired needs-help update directly rather
// than waiting 72 real hours.
func createNeedsHelpUpdateAt(t *testing.T, ctx context.Context, store *repository.Store, catID pgtype.UUID, createdAt time.Time, category string, expiresAt time.Time) {
	t.Helper()
	_, err := store.CreateUpdate(ctx, repository.CreateUpdateParams{
		ID:                 pgtype.UUID{Bytes: uuid.New(), Valid: true},
		CatID:              catID,
		Kind:               "needs_help",
		CreatedAt:          pgtype.Timestamptz{Time: createdAt, Valid: true},
		NeedsHelpCategory:  pgtype.Text{String: category, Valid: true},
		NeedsHelpExpiresAt: pgtype.Timestamptz{Time: expiresAt, Valid: true},
	})
	if err != nil {
		t.Fatalf("create needs-help update: %v", err)
	}
}
