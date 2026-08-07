package service

import (
	"context"
	"errors"
	"math"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

type fakeCatsLister struct {
	rows []repository.ListCatsInBoundsRow
	err  error

	catRow repository.GetCatByIDRow
	catErr error

	exists    bool
	existsErr error

	updateRows []repository.ListCatUpdatesRow
	updatesErr error

	createRow repository.CreateUpdateRow
	createErr error
	// captured, if non-nil, records the arg the last CreateOrdinaryUpdate
	// call received — a pointer field so the write is visible through the
	// copy of fakeCatsLister that ends up inside CatsService.
	captured *repository.CreateOrdinaryUpdateParams

	createNeedsHelpRow repository.CreateUpdateRow
	createNeedsHelpErr error
	// capturedNeedsHelp mirrors captured above, for CreateNeedsHelpUpdate.
	capturedNeedsHelp *repository.CreateOrdinaryUpdateParams

	idempotencyRow repository.GetCatByIdempotencyKeyRow
	idempotencyErr error

	updateIdempotencyRow repository.GetUpdateByIdempotencyKeyRow
	updateIdempotencyErr error

	nearbyDuplicateRows []repository.ListNearbyCatsForDuplicateCheckRow
	nearbyDuplicateErr  error

	createCatWithMediaRow repository.CreateCatWithMediaRow
	createCatWithMediaErr error
	// capturedCreateCat, if non-nil, records the arg the last
	// CreateCatWithMedia call received, mirroring captured above.
	capturedCreateCat *repository.CreateCatWithMediaParams

	correctRow repository.CorrectOwnUpdateRow
	correctErr error
	// capturedCorrect mirrors captured above, for CorrectOwnUpdate.
	capturedCorrect *repository.CorrectOwnUpdateParams

	deleteRow repository.DeleteOwnUpdateRow
	deleteErr error

	correctionCheckRow repository.GetUpdateForCorrectionCheckRow
	correctionCheckErr error

	distanceRows []repository.ListCatsByDistanceRow
	distanceErr  error
	// capturedDistance mirrors captured above, for ListCatsByDistance.
	capturedDistance *repository.ListCatsByDistanceParams

	needsHelpDistanceRows []repository.ListActiveNeedsHelpCatsByDistanceRow
	needsHelpDistanceErr  error
	// capturedNeedsHelpDistance mirrors captured above, for
	// ListActiveNeedsHelpCatsByDistance.
	capturedNeedsHelpDistance *repository.ListActiveNeedsHelpCatsByDistanceParams

	mediaCount    int64
	mediaCountErr error

	mediaRows []repository.ListCatMediaRow
	mediaErr  error

	userRow repository.User
	userErr error
}

func (f fakeCatsLister) GetUserByID(ctx context.Context, id pgtype.UUID) (repository.User, error) {
	return f.userRow, f.userErr
}

func (f fakeCatsLister) CountCatMedia(ctx context.Context, catID pgtype.UUID) (int64, error) {
	return f.mediaCount, f.mediaCountErr
}

func (f fakeCatsLister) ListCatMedia(ctx context.Context, catID pgtype.UUID) ([]repository.ListCatMediaRow, error) {
	return f.mediaRows, f.mediaErr
}

func (f fakeCatsLister) ListCatsInBounds(ctx context.Context, arg repository.ListCatsInBoundsParams) ([]repository.ListCatsInBoundsRow, error) {
	return f.rows, f.err
}

func (f fakeCatsLister) GetCatByID(ctx context.Context, id pgtype.UUID) (repository.GetCatByIDRow, error) {
	return f.catRow, f.catErr
}

func (f fakeCatsLister) CatExists(ctx context.Context, id pgtype.UUID) (bool, error) {
	return f.exists, f.existsErr
}

func (f fakeCatsLister) ListCatUpdates(ctx context.Context, arg repository.ListCatUpdatesParams) ([]repository.ListCatUpdatesRow, error) {
	return f.updateRows, f.updatesErr
}

func (f fakeCatsLister) CreateOrdinaryUpdate(ctx context.Context, arg repository.CreateOrdinaryUpdateParams) (repository.CreateUpdateRow, error) {
	if arg.NeedsHelpCategory.Valid {
		// the compat needs-help endpoint's write (issue #101) is the only
		// caller that records a category — routed to its own captured/row/
		// err fields so both flows stay independently assertable through
		// this one store method.
		if f.capturedNeedsHelp != nil {
			*f.capturedNeedsHelp = arg
		}
		return f.createNeedsHelpRow, f.createNeedsHelpErr
	}
	if f.captured != nil {
		*f.captured = arg
	}
	return f.createRow, f.createErr
}

func (f fakeCatsLister) GetCatByIdempotencyKey(ctx context.Context, arg repository.GetCatByIdempotencyKeyParams) (repository.GetCatByIdempotencyKeyRow, error) {
	return f.idempotencyRow, f.idempotencyErr
}

func (f fakeCatsLister) GetUpdateByIdempotencyKey(ctx context.Context, arg repository.GetUpdateByIdempotencyKeyParams) (repository.GetUpdateByIdempotencyKeyRow, error) {
	return f.updateIdempotencyRow, f.updateIdempotencyErr
}

func (f fakeCatsLister) ListNearbyCatsForDuplicateCheck(ctx context.Context, arg repository.ListNearbyCatsForDuplicateCheckParams) ([]repository.ListNearbyCatsForDuplicateCheckRow, error) {
	return f.nearbyDuplicateRows, f.nearbyDuplicateErr
}

func (f fakeCatsLister) CreateCatWithMedia(ctx context.Context, arg repository.CreateCatWithMediaParams) (repository.CreateCatWithMediaRow, error) {
	if f.capturedCreateCat != nil {
		*f.capturedCreateCat = arg
	}
	return f.createCatWithMediaRow, f.createCatWithMediaErr
}

func (f fakeCatsLister) CorrectOwnUpdate(ctx context.Context, arg repository.CorrectOwnUpdateParams) (repository.CorrectOwnUpdateRow, error) {
	if f.capturedCorrect != nil {
		*f.capturedCorrect = arg
	}
	return f.correctRow, f.correctErr
}

func (f fakeCatsLister) DeleteOwnUpdate(ctx context.Context, arg repository.DeleteOwnUpdateParams) (repository.DeleteOwnUpdateRow, error) {
	return f.deleteRow, f.deleteErr
}

func (f fakeCatsLister) GetUpdateForCorrectionCheck(ctx context.Context, arg repository.GetUpdateForCorrectionCheckParams) (repository.GetUpdateForCorrectionCheckRow, error) {
	return f.correctionCheckRow, f.correctionCheckErr
}

func (f fakeCatsLister) ListCatsByDistance(ctx context.Context, arg repository.ListCatsByDistanceParams) ([]repository.ListCatsByDistanceRow, error) {
	if f.capturedDistance != nil {
		*f.capturedDistance = arg
	}
	return f.distanceRows, f.distanceErr
}

func (f fakeCatsLister) ListActiveNeedsHelpCatsByDistance(ctx context.Context, arg repository.ListActiveNeedsHelpCatsByDistanceParams) ([]repository.ListActiveNeedsHelpCatsByDistanceRow, error) {
	if f.capturedNeedsHelpDistance != nil {
		*f.capturedNeedsHelpDistance = arg
	}
	return f.needsHelpDistanceRows, f.needsHelpDistanceErr
}

func TestCatsService_ListNearby(t *testing.T) {
	fixedNow := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	id := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	svc := NewCatsService(fakeCatsLister{rows: []repository.ListCatsInBoundsRow{
		{
			ID:                 id,
			Name:               pgtype.Text{String: "tekir", Valid: true},
			PhotoUrl:           "https://placecats.com/millie/300/200",
			Lng:                28.9744,
			Lat:                41.0256,
			AreaLabel:          pgtype.Text{String: "Galata Kulesi çevresi, Beyoğlu", Valid: true},
			NeedsHelpCategory:  pgtype.Text{String: "injured_or_sick", Valid: true},
			NeedsHelpCreatedAt: pgtype.Timestamptz{Time: fixedNow.Add(-time.Hour), Valid: true},
			NeedsHelpExpiresAt: pgtype.Timestamptz{Time: fixedNow.Add(time.Hour), Valid: true},
		},
	}}, WithClock(func() time.Time { return fixedNow }))

	markers, err := svc.ListNearby(context.Background(), Bounds{MinLng: 28, MinLat: 41, MaxLng: 29, MaxLat: 42})
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(markers) != 1 {
		t.Fatalf("expected 1 marker, got %d", len(markers))
	}

	m := markers[0]
	if m.ID != uuid.UUID(id.Bytes).String() {
		t.Errorf("expected id %s, got %s", uuid.UUID(id.Bytes).String(), m.ID)
	}
	if m.ActiveAlert == nil {
		t.Fatal("expected an active alert")
	}
	if m.ActiveAlert.Category != "injured_or_sick" {
		t.Errorf("expected category injured_or_sick, got %q", m.ActiveAlert.Category)
	}
	if m.ActiveAlert.CategoryLabel != "yaralı / hasta" {
		t.Errorf("unexpected category label: %q", m.ActiveAlert.CategoryLabel)
	}
	if m.LastUpdateAt != nil {
		t.Errorf("expected nil last_update_at, got %v", m.LastUpdateAt)
	}
	if m.Name != "tekir" {
		t.Errorf("expected name %q, got %q", "tekir", m.Name)
	}
	if m.AreaLabel == nil || *m.AreaLabel != "Galata Kulesi çevresi, Beyoğlu" {
		t.Errorf("unexpected area label: %v", m.AreaLabel)
	}
}

func TestCatsService_ListNearby_InvalidBounds(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{})

	cases := []struct {
		name   string
		bounds Bounds
	}{
		{"min lat >= max lat", Bounds{MinLng: 28, MinLat: 41, MaxLng: 29, MaxLat: 41}},
		{"min lng >= max lng", Bounds{MinLng: 29, MinLat: 41, MaxLng: 29, MaxLat: 42}},
		{"lat out of range", Bounds{MinLng: 28, MinLat: -91, MaxLng: 29, MaxLat: 42}},
		{"lng out of range", Bounds{MinLng: -181, MinLat: 41, MaxLng: 29, MaxLat: 42}},
		{"nan lat", Bounds{MinLng: 28, MinLat: math.NaN(), MaxLng: 29, MaxLat: 42}},
		{"nan lng", Bounds{MinLng: math.NaN(), MinLat: 41, MaxLng: 29, MaxLat: 42}},
		{"positive infinity", Bounds{MinLng: 28, MinLat: 41, MaxLng: 29, MaxLat: math.Inf(1)}},
		{"negative infinity", Bounds{MinLng: math.Inf(-1), MinLat: 41, MaxLng: 29, MaxLat: 42}},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if _, err := svc.ListNearby(context.Background(), c.bounds); !errors.Is(err, ErrInvalidBounds) {
				t.Fatalf("expected ErrInvalidBounds, got %v", err)
			}
		})
	}
}

func TestCatsService_GetCatDetail(t *testing.T) {
	id := uuid.New()
	created := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	svc := NewCatsService(fakeCatsLister{
		catRow: repository.GetCatByIDRow{
			ID:        pgtype.UUID{Bytes: id, Valid: true},
			Name:      pgtype.Text{String: "tekir", Valid: true},
			Lng:       28.9744,
			Lat:       41.0256,
			AreaLabel: pgtype.Text{String: "Galata Kulesi çevresi, Beyoğlu", Valid: true},
			PhotoUrl:  "https://placecats.com/millie/300/200",
			CreatedAt: pgtype.Timestamptz{Time: created, Valid: true},
		},
	})

	detail, err := svc.GetCatDetail(context.Background(), id.String())
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if detail.ID != id.String() {
		t.Errorf("expected id %s, got %s", id.String(), detail.ID)
	}
	if detail.Name != "tekir" {
		t.Errorf("expected name %q, got %q", "tekir", detail.Name)
	}
	if detail.PrimaryPhoto == nil || *detail.PrimaryPhoto != "https://placecats.com/millie/300/200" {
		t.Errorf("unexpected primary photo: %v", detail.PrimaryPhoto)
	}
	if detail.AreaLabel == nil || *detail.AreaLabel != "Galata Kulesi çevresi, Beyoğlu" {
		t.Errorf("unexpected area label: %v", detail.AreaLabel)
	}
	if !detail.CreatedAt.Equal(created) {
		t.Errorf("expected created_at %v, got %v", created, detail.CreatedAt)
	}
	if detail.LastUpdateAt != nil {
		t.Errorf("expected nil last_update_at, got %v", detail.LastUpdateAt)
	}
}

// TestCatsService_GetCatDetail_MediaCount covers issue #121's cover
// photo-counter parity gap: the count comes straight from CountCatMedia,
// not derived from PrimaryPhoto's presence.
func TestCatsService_GetCatDetail_MediaCount(t *testing.T) {
	id := uuid.New()
	svc := NewCatsService(fakeCatsLister{
		catRow: repository.GetCatByIDRow{
			ID:   pgtype.UUID{Bytes: id, Valid: true},
			Name: pgtype.Text{String: "tekir", Valid: true},
		},
		mediaCount: 3,
	})

	detail, err := svc.GetCatDetail(context.Background(), id.String())
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if detail.MediaCount != 3 {
		t.Errorf("expected media_count 3, got %d", detail.MediaCount)
	}
}

// TestCatsService_GetCatDetail_ThreeStatTimestamps covers issue #121's
// three-stat header fields: each of last_seen_at/last_fed_at/last_water_at
// is independent — a cat can have some, all, or none of them set, and a
// missing one must stay nil rather than falling back to another status's
// timestamp or to last_update_at.
func TestCatsService_GetCatDetail_ThreeStatTimestamps(t *testing.T) {
	id := uuid.New()
	seenAt := time.Date(2026, 1, 3, 8, 0, 0, 0, time.UTC)
	fedAt := time.Date(2026, 1, 2, 9, 0, 0, 0, time.UTC)
	svc := NewCatsService(fakeCatsLister{
		catRow: repository.GetCatByIDRow{
			ID:          pgtype.UUID{Bytes: id, Valid: true},
			Name:        pgtype.Text{String: "tekir", Valid: true},
			LastSeenAt:  pgtype.Timestamptz{Time: seenAt, Valid: true},
			LastFedAt:   pgtype.Timestamptz{Time: fedAt, Valid: true},
			LastWaterAt: pgtype.Timestamptz{},
		},
	})

	detail, err := svc.GetCatDetail(context.Background(), id.String())
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if detail.LastSeenAt == nil || !detail.LastSeenAt.Equal(seenAt) {
		t.Errorf("expected last_seen_at %v, got %v", seenAt, detail.LastSeenAt)
	}
	if detail.LastFedAt == nil || !detail.LastFedAt.Equal(fedAt) {
		t.Errorf("expected last_fed_at %v, got %v", fedAt, detail.LastFedAt)
	}
	if detail.LastWaterAt != nil {
		t.Errorf("expected nil last_water_at, got %v", detail.LastWaterAt)
	}
}

// TestCatsService_GetCatDetail_NoStatusUpdatesYet covers the cat-has-never-
// had-any-structured-status case: all three stat fields stay nil, never a
// zero time.Time.
func TestCatsService_GetCatDetail_NoStatusUpdatesYet(t *testing.T) {
	id := uuid.New()
	svc := NewCatsService(fakeCatsLister{
		catRow: repository.GetCatByIDRow{
			ID:   pgtype.UUID{Bytes: id, Valid: true},
			Name: pgtype.Text{String: "tekir", Valid: true},
		},
	})

	detail, err := svc.GetCatDetail(context.Background(), id.String())
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if detail.LastSeenAt != nil || detail.LastFedAt != nil || detail.LastWaterAt != nil {
		t.Errorf("expected all three stat timestamps nil, got seen=%v fed=%v water=%v", detail.LastSeenAt, detail.LastFedAt, detail.LastWaterAt)
	}
}

func TestCatsService_GetCatDetail_NotFound(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{catErr: pgx.ErrNoRows})

	_, err := svc.GetCatDetail(context.Background(), uuid.New().String())
	if !errors.Is(err, ErrCatNotFound) {
		t.Fatalf("expected ErrCatNotFound, got %v", err)
	}
}

func TestCatsService_GetCatDetail_InvalidID(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{})

	_, err := svc.GetCatDetail(context.Background(), "not-a-uuid")
	if !errors.Is(err, ErrInvalidCatID) {
		t.Fatalf("expected ErrInvalidCatID, got %v", err)
	}
}

func TestCatsService_ListCatUpdates_UnknownCat(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: false})

	_, err := svc.ListCatUpdates(context.Background(), uuid.New().String(), "", 0, "")
	if !errors.Is(err, ErrCatNotFound) {
		t.Fatalf("expected ErrCatNotFound, got %v", err)
	}
}

func TestCatsService_ListCatUpdates_EmptyHistory(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: true})

	page, err := svc.ListCatUpdates(context.Background(), uuid.New().String(), "", 0, "")
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(page.Items) != 0 {
		t.Errorf("expected no items, got %v", page.Items)
	}
	if page.NextCursor != "" {
		t.Errorf("expected empty next cursor, got %q", page.NextCursor)
	}
}

func TestCatsService_ListCatUpdates_PaginatesAndEncodesCursor(t *testing.T) {
	newest := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	middle := time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC)
	oldest := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

	// the service asks for limit+1 rows to detect a next page; the fake
	// simulates that by returning 3 rows for a limit of 2.
	svc := NewCatsService(fakeCatsLister{
		exists: true,
		updateRows: []repository.ListCatUpdatesRow{
			{
				ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
				CreatedAt: pgtype.Timestamptz{Time: newest, Valid: true},
				Seq:       pgtype.Int8{Int64: 3, Valid: true},
				Statuses:  []string{"seen"},
			},
			{
				ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
				CreatedAt: pgtype.Timestamptz{Time: middle, Valid: true},
				Seq:       pgtype.Int8{Int64: 2, Valid: true},
				Comment:   pgtype.Text{String: "topped up water", Valid: true},
				Statuses:  []string{"fed", "water_provided"},
			},
			{
				ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
				CreatedAt: pgtype.Timestamptz{Time: oldest, Valid: true},
				Seq:       pgtype.Int8{Int64: 1, Valid: true},
				Statuses:  []string{"seen"},
			},
		},
	})

	page, err := svc.ListCatUpdates(context.Background(), uuid.New().String(), "", 2, "")
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(page.Items) != 2 {
		t.Fatalf("expected 2 items on the first page, got %d", len(page.Items))
	}
	if page.NextCursor == "" {
		t.Fatal("expected a next cursor, got none")
	}
	if page.Items[1].Comment == nil || *page.Items[1].Comment != "topped up water" {
		t.Errorf("unexpected comment: %v", page.Items[1].Comment)
	}

	// the cursor must round-trip back to the position of the last item served.
	decoded, err := decodeUpdatesCursor(page.NextCursor)
	if err != nil {
		t.Fatalf("expected cursor to decode, got %v", err)
	}
	if !decoded.createdAt.Equal(middle) || decoded.seq != 2 {
		t.Errorf("expected cursor at (%v, 2), got (%v, %d)", middle, decoded.createdAt, decoded.seq)
	}
}

// TestCatsService_ListCatUpdates_AuthorDisplayName covers issue #121's
// timeline-avatar parity gap: an update row with an author who set a
// display name surfaces it, while a row with no author (or an author with
// no display name) stays nil rather than the service inventing one.
func TestCatsService_ListCatUpdates_AuthorDisplayName(t *testing.T) {
	withName := time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC)
	withoutName := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

	svc := NewCatsService(fakeCatsLister{
		exists: true,
		updateRows: []repository.ListCatUpdatesRow{
			{
				ID:                pgtype.UUID{Bytes: uuid.New(), Valid: true},
				CreatedAt:         pgtype.Timestamptz{Time: withName, Valid: true},
				Seq:               pgtype.Int8{Int64: 2, Valid: true},
				Statuses:          []string{"seen"},
				AuthorUserID:      pgtype.UUID{Bytes: uuid.New(), Valid: true},
				AuthorDisplayName: pgtype.Text{String: "asli", Valid: true},
			},
			{
				ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
				CreatedAt: pgtype.Timestamptz{Time: withoutName, Valid: true},
				Seq:       pgtype.Int8{Int64: 1, Valid: true},
				Statuses:  []string{"fed"},
				// no author at all — a pre-#65 or seed row.
			},
		},
	})

	page, err := svc.ListCatUpdates(context.Background(), uuid.New().String(), "", 0, "")
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(page.Items) != 2 {
		t.Fatalf("expected 2 items, got %d", len(page.Items))
	}
	if page.Items[0].AuthorDisplayName == nil || *page.Items[0].AuthorDisplayName != "asli" {
		t.Errorf("expected author_display_name %q, got %v", "asli", page.Items[0].AuthorDisplayName)
	}
	if page.Items[1].AuthorDisplayName != nil {
		t.Errorf("expected nil author_display_name for authorless row, got %v", *page.Items[1].AuthorDisplayName)
	}
}

// TestCatsService_ListCatUpdates_PhotoURL covers issue #121's
// timeline-thumbnail parity gap: a row whose media_id resolves to a media
// url surfaces it, while a row with no media stays nil.
func TestCatsService_ListCatUpdates_PhotoURL(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{
		exists: true,
		updateRows: []repository.ListCatUpdatesRow{
			{
				ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
				CreatedAt: pgtype.Timestamptz{Time: time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC), Valid: true},
				Seq:       pgtype.Int8{Int64: 2, Valid: true},
				Statuses:  []string{"seen"},
				PhotoUrl:  pgtype.Text{String: "https://placecats.com/millie/300/200", Valid: true},
			},
			{
				ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
				CreatedAt: pgtype.Timestamptz{Time: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC), Valid: true},
				Seq:       pgtype.Int8{Int64: 1, Valid: true},
				Statuses:  []string{"fed"},
			},
		},
	})

	page, err := svc.ListCatUpdates(context.Background(), uuid.New().String(), "", 0, "")
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(page.Items) != 2 {
		t.Fatalf("expected 2 items, got %d", len(page.Items))
	}
	if page.Items[0].PhotoURL == nil || *page.Items[0].PhotoURL != "https://placecats.com/millie/300/200" {
		t.Errorf("expected photo_url set, got %v", page.Items[0].PhotoURL)
	}
	if page.Items[1].PhotoURL != nil {
		t.Errorf("expected nil photo_url for medialess row, got %v", *page.Items[1].PhotoURL)
	}
}

func TestCatsService_ListCatUpdates_InvalidLimit(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: true})

	cases := []int{-1, maxUpdatesLimit + 1}
	for _, limit := range cases {
		if _, err := svc.ListCatUpdates(context.Background(), uuid.New().String(), "", limit, ""); !errors.Is(err, ErrInvalidLimit) {
			t.Errorf("limit %d: expected ErrInvalidLimit, got %v", limit, err)
		}
	}
}

func TestCatsService_ListCatUpdates_InvalidCursor(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: true})

	if _, err := svc.ListCatUpdates(context.Background(), uuid.New().String(), "not-base64!!", 0, ""); !errors.Is(err, ErrInvalidCursor) {
		t.Fatalf("expected ErrInvalidCursor, got %v", err)
	}
}

func TestCatsService_ListCatUpdates_InvalidCatID(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{})

	if _, err := svc.ListCatUpdates(context.Background(), "not-a-uuid", "", 0, ""); !errors.Is(err, ErrInvalidCatID) {
		t.Fatalf("expected ErrInvalidCatID, got %v", err)
	}
}

func TestNeedsHelpExpiresAt(t *testing.T) {
	created := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	got := NeedsHelpExpiresAt(created)
	want := created.Add(72 * time.Hour)
	if !got.Equal(want) {
		t.Errorf("expected server-controlled 72h expiry %v, got %v", want, got)
	}
}

func TestNeedsHelpCategoryLabels_AllFiveCategories(t *testing.T) {
	want := []string{"injured_or_sick", "food_needed", "water_needed", "unsafe_location", "trapped"}
	if len(needsHelpCategoryLabels) != len(want) {
		t.Fatalf("expected exactly %d categories, got %d: %v", len(want), len(needsHelpCategoryLabels), needsHelpCategoryLabels)
	}
	for _, category := range want {
		if label, ok := needsHelpCategoryLabels[category]; !ok || label == "" {
			t.Errorf("expected a non-empty turkish label for category %q, got %q (present=%v)", category, label, ok)
		}
	}
}

func TestCatsService_ListNearby_ActiveAlertBoundaries(t *testing.T) {
	fixedNow := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)

	baseRow := func(expiresAt time.Time) repository.ListCatsInBoundsRow {
		return repository.ListCatsInBoundsRow{
			ID:                 pgtype.UUID{Bytes: uuid.New(), Valid: true},
			NeedsHelpCategory:  pgtype.Text{String: "trapped", Valid: true},
			NeedsHelpCreatedAt: pgtype.Timestamptz{Time: expiresAt.Add(-72 * time.Hour), Valid: true},
			NeedsHelpExpiresAt: pgtype.Timestamptz{Time: expiresAt, Valid: true},
		}
	}

	cases := []struct {
		name       string
		expiresAt  time.Time
		wantActive bool
	}{
		{"active before expiry", fixedNow.Add(time.Minute), true},
		{"expired exactly at expiry", fixedNow, false},
		{"expired after expiry", fixedNow.Add(-time.Minute), false},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			svc := NewCatsService(
				fakeCatsLister{rows: []repository.ListCatsInBoundsRow{baseRow(c.expiresAt)}},
				WithClock(func() time.Time { return fixedNow }),
			)
			markers, err := svc.ListNearby(context.Background(), Bounds{MinLng: 28, MinLat: 41, MaxLng: 29, MaxLat: 42})
			if err != nil {
				t.Fatalf("expected no error, got %v", err)
			}
			gotActive := markers[0].ActiveAlert != nil
			if gotActive != c.wantActive {
				t.Errorf("expected active=%v, got active=%v (alert=%+v)", c.wantActive, gotActive, markers[0].ActiveAlert)
			}
		})
	}
}

func TestCatsService_GetCatDetail_ActiveAlert(t *testing.T) {
	fixedNow := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	id := uuid.New()
	svc := NewCatsService(fakeCatsLister{
		catRow: repository.GetCatByIDRow{
			ID:                 pgtype.UUID{Bytes: id, Valid: true},
			NeedsHelpCategory:  pgtype.Text{String: "unsafe_location", Valid: true},
			NeedsHelpCreatedAt: pgtype.Timestamptz{Time: fixedNow.Add(-time.Hour), Valid: true},
			NeedsHelpExpiresAt: pgtype.Timestamptz{Time: fixedNow.Add(time.Hour), Valid: true},
		},
	}, WithClock(func() time.Time { return fixedNow }))

	detail, err := svc.GetCatDetail(context.Background(), id.String())
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if detail.ActiveAlert == nil {
		t.Fatal("expected an active alert")
	}
	if detail.ActiveAlert.Category != "unsafe_location" {
		t.Errorf("expected category unsafe_location, got %q", detail.ActiveAlert.Category)
	}
	if detail.ActiveAlert.CategoryLabel != "güvenli olmayan konum" {
		t.Errorf("unexpected category label: %q", detail.ActiveAlert.CategoryLabel)
	}
}

func TestCatsService_GetCatDetail_NoActiveAlert(t *testing.T) {
	id := uuid.New()
	svc := NewCatsService(fakeCatsLister{
		catRow: repository.GetCatByIDRow{ID: pgtype.UUID{Bytes: id, Valid: true}},
	})

	detail, err := svc.GetCatDetail(context.Background(), id.String())
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if detail.ActiveAlert != nil {
		t.Errorf("expected no active alert, got %+v", detail.ActiveAlert)
	}
}

func TestCatsService_ListCatUpdates_NeedsHelpEntry(t *testing.T) {
	fixedNow := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)

	cases := []struct {
		name       string
		expiresAt  time.Time
		wantActive bool
	}{
		{"active before expiry", fixedNow.Add(time.Hour), true},
		{"expired exactly at expiry", fixedNow, false},
		{"expired after expiry", fixedNow.Add(-time.Hour), false},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			svc := NewCatsService(fakeCatsLister{
				exists: true,
				updateRows: []repository.ListCatUpdatesRow{
					{
						ID:                 pgtype.UUID{Bytes: uuid.New(), Valid: true},
						Kind:               "needs_help",
						NeedsHelp:          true,
						CreatedAt:          pgtype.Timestamptz{Time: c.expiresAt.Add(-72 * time.Hour), Valid: true},
						Seq:                pgtype.Int8{Int64: 1, Valid: true},
						NeedsHelpCategory:  pgtype.Text{String: "food_needed", Valid: true},
						NeedsHelpExpiresAt: pgtype.Timestamptz{Time: c.expiresAt, Valid: true},
						Statuses:           []string{},
					},
				},
			}, WithClock(func() time.Time { return fixedNow }))

			page, err := svc.ListCatUpdates(context.Background(), uuid.New().String(), "", 0, "")
			if err != nil {
				t.Fatalf("expected no error, got %v", err)
			}
			if len(page.Items) != 1 {
				t.Fatalf("expected the needs-help entry to remain in history regardless of expiry, got %d items", len(page.Items))
			}
			item := page.Items[0]
			if item.Kind != "needs_help" {
				t.Errorf("expected kind needs_help, got %q", item.Kind)
			}
			if item.NeedsHelpCategory == nil || *item.NeedsHelpCategory != "food_needed" {
				t.Errorf("unexpected category: %v", item.NeedsHelpCategory)
			}
			if item.NeedsHelpActive == nil || *item.NeedsHelpActive != c.wantActive {
				t.Errorf("expected active=%v, got %v", c.wantActive, item.NeedsHelpActive)
			}
		})
	}
}

func TestCatsService_ListCatUpdates_OrdinaryEntryHasNoNeedsHelpFields(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{
		exists: true,
		updateRows: []repository.ListCatUpdatesRow{
			{
				ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
				Kind:      "ordinary",
				CreatedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
				Seq:       pgtype.Int8{Int64: 1, Valid: true},
				Statuses:  []string{"seen"},
			},
		},
	})

	page, err := svc.ListCatUpdates(context.Background(), uuid.New().String(), "", 0, "")
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	item := page.Items[0]
	if item.NeedsHelpCategory != nil || item.NeedsHelpCategoryLabel != nil || item.NeedsHelpExpiresAt != nil || item.NeedsHelpActive != nil {
		t.Errorf("expected no needs-help fields on an ordinary entry, got %+v", item)
	}
}

// ── CreateOrdinaryUpdate (issue #36) ──────────────────────────────────────────

func TestCatsService_CreateOrdinaryUpdate_Success(t *testing.T) {
	catID := uuid.New()
	userID := uuid.New()
	deviceID := uuid.New()
	returnedID := uuid.New()
	fixedNow := time.Date(2026, 1, 5, 8, 0, 0, 0, time.UTC)
	var captured repository.CreateOrdinaryUpdateParams
	svc := NewCatsService(fakeCatsLister{
		exists:    true,
		createRow: repository.CreateUpdateRow{ID: pgtype.UUID{Bytes: returnedID, Valid: true}},
		captured:  &captured,
	}, WithClock(func() time.Time { return fixedNow }))

	comment := "mama verildi, su tazelendi"
	update, err := svc.CreateOrdinaryUpdate(context.Background(), catID.String(), userID.String(), deviceID.String(), nil, []string{"water_provided", "fed"}, false, &comment)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}

	if update.ID != returnedID.String() {
		t.Errorf("expected id %s, got %s", returnedID.String(), update.ID)
	}
	if update.Kind != "ordinary" {
		t.Errorf("expected kind ordinary, got %q", update.Kind)
	}
	if update.Comment == nil || *update.Comment != comment {
		t.Errorf("unexpected comment: %v", update.Comment)
	}
	if !update.CreatedAt.Equal(fixedNow) {
		t.Errorf("expected server-derived created_at %v, got %v", fixedNow, update.CreatedAt)
	}
	// statuses come back sorted, regardless of submission order.
	if len(update.Statuses) != 2 || update.Statuses[0] != "fed" || update.Statuses[1] != "water_provided" {
		t.Errorf("expected sorted statuses [fed water_provided], got %v", update.Statuses)
	}
	// issue #80: a freshly created update is always the caller's own and
	// always inside its own correction window at creation time — the
	// client must see this immediately, not only after a reload.
	if !update.AuthorIsMe {
		t.Error("expected AuthorIsMe true on a freshly created update")
	}
	wantExpiresAt := fixedNow.Add(updateCorrectionWindow)
	if update.CorrectionExpiresAt == nil || !update.CorrectionExpiresAt.Equal(wantExpiresAt) {
		t.Errorf("expected correction_expires_at %v, got %v", wantExpiresAt, update.CorrectionExpiresAt)
	}

	if uuid.UUID(captured.CatID.Bytes).String() != catID.String() {
		t.Errorf("unexpected repository cat id: %v", captured.CatID)
	}
	if uuid.UUID(captured.AuthorDeviceID.Bytes).String() != deviceID.String() {
		t.Errorf("unexpected repository author device id: %v", captured.AuthorDeviceID)
	}
	if uuid.UUID(captured.AuthorUserID.Bytes).String() != userID.String() {
		t.Errorf("unexpected repository author user id: %v", captured.AuthorUserID)
	}
	if !captured.CreatedAt.Time.Equal(fixedNow) {
		t.Errorf("expected repository created_at %v, got %v", fixedNow, captured.CreatedAt.Time)
	}
	if !captured.Comment.Valid || captured.Comment.String != comment {
		t.Errorf("unexpected repository comment: %v", captured.Comment)
	}
}

func TestCatsService_CreateOrdinaryUpdate_NoComment(t *testing.T) {
	var captured repository.CreateOrdinaryUpdateParams
	svc := NewCatsService(fakeCatsLister{exists: true, captured: &captured})

	update, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String(), nil, []string{"seen"}, false, nil)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if update.Comment != nil {
		t.Errorf("expected nil comment, got %v", *update.Comment)
	}
	if captured.Comment.Valid {
		t.Errorf("expected repository comment to stay unset, got %v", captured.Comment)
	}
}

func TestCatsService_CreateOrdinaryUpdate_WithoutDeviceToken_StillSucceeds(t *testing.T) {
	var captured repository.CreateOrdinaryUpdateParams
	svc := NewCatsService(fakeCatsLister{exists: true, captured: &captured})

	userID := uuid.New()
	if _, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), userID.String(), "", nil, []string{"seen"}, false, nil); err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if captured.AuthorDeviceID.Valid {
		t.Errorf("expected no author device id captured, got %v", captured.AuthorDeviceID)
	}
	if uuid.UUID(captured.AuthorUserID.Bytes).String() != userID.String() {
		t.Errorf("unexpected repository author user id: %v", captured.AuthorUserID)
	}
}

func TestCatsService_CreateOrdinaryUpdate_InvalidUserID(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: true})
	_, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), "not-a-uuid", "", nil, []string{"seen"}, false, nil)
	if err == nil {
		t.Fatal("expected error for invalid user id, got nil")
	}
}

func TestCatsService_CreateOrdinaryUpdate_InvalidDeviceID(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: true})
	_, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), uuid.New().String(), "not-a-uuid", nil, []string{"seen"}, false, nil)
	if err == nil {
		t.Fatal("expected error for invalid device id, got nil")
	}
}

func TestCatsService_CreateOrdinaryUpdate_InvalidStatuses(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: true})

	cases := []struct {
		name     string
		statuses []string
	}{
		{"empty", []string{}},
		{"nil", nil},
		{"unknown value", []string{"flying"}},
		{"duplicate", []string{"seen", "seen"}},
		{"one valid one unknown", []string{"seen", "flying"}},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if _, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String(), nil, c.statuses, false, nil); !errors.Is(err, ErrInvalidStatuses) {
				t.Fatalf("expected ErrInvalidStatuses, got %v", err)
			}
		})
	}
}

func TestCatsService_CreateOrdinaryUpdate_InvalidCatID(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{})

	_, err := svc.CreateOrdinaryUpdate(context.Background(), "not-a-uuid", uuid.New().String(), uuid.New().String(), nil, []string{"seen"}, false, nil)
	if !errors.Is(err, ErrInvalidCatID) {
		t.Fatalf("expected ErrInvalidCatID, got %v", err)
	}
}

func TestCatsService_CreateOrdinaryUpdate_UnknownCat(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: false})

	_, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String(), nil, []string{"seen"}, false, nil)
	if !errors.Is(err, ErrCatNotFound) {
		t.Fatalf("expected ErrCatNotFound, got %v", err)
	}
}

func TestCatsService_CreateOrdinaryUpdate_RepositoryFailure(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: true, createErr: errors.New("connection refused")})

	_, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String(), nil, []string{"seen"}, false, nil)
	if err == nil {
		t.Fatal("expected an error, got nil")
	}
}

func TestCatsService_CreateOrdinaryUpdate_IdempotentRetryReturnsExistingWithoutWrite(t *testing.T) {
	existingID := uuid.New()
	existingComment := "already recorded"
	var captured repository.CreateOrdinaryUpdateParams
	svc := NewCatsService(fakeCatsLister{
		exists: true,
		updateIdempotencyRow: repository.GetUpdateByIdempotencyKeyRow{
			ID:        pgtype.UUID{Bytes: existingID, Valid: true},
			Statuses:  []string{"seen"},
			Comment:   pgtype.Text{String: existingComment, Valid: true},
			CreatedAt: pgtype.Timestamptz{Time: time.Date(2026, 3, 1, 9, 0, 0, 0, time.UTC), Valid: true},
		},
		captured: &captured,
	})

	key := "seen-tap-key"
	update, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), uuid.New().String(), "", &key, []string{"seen"}, false, nil)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if update.ID != existingID.String() {
		t.Errorf("expected the existing update's id %s, got %s", existingID.String(), update.ID)
	}
	if update.Comment == nil || *update.Comment != existingComment {
		t.Errorf("expected the existing update's comment %q, got %v", existingComment, update.Comment)
	}
	if captured.ID.Valid {
		t.Error("expected CreateOrdinaryUpdate to never be called on an idempotent retry")
	}
}

func TestCatsService_CreateOrdinaryUpdate_NoExistingKeyProceedsToCreate(t *testing.T) {
	newID := uuid.New()
	var captured repository.CreateOrdinaryUpdateParams
	svc := NewCatsService(fakeCatsLister{
		exists:               true,
		updateIdempotencyErr: pgx.ErrNoRows,
		createRow:            repository.CreateUpdateRow{ID: pgtype.UUID{Bytes: newID, Valid: true}},
		captured:             &captured,
	})

	key := "first-attempt-key"
	update, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), uuid.New().String(), "", &key, []string{"seen"}, false, nil)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if update.ID != newID.String() {
		t.Errorf("expected the freshly created update's id %s, got %s", newID.String(), update.ID)
	}
	if !captured.ID.Valid {
		t.Error("expected CreateOrdinaryUpdate to be called when no existing key match was found")
	}
	if captured.IdempotencyKey.String != key {
		t.Errorf("expected the idempotency key %q to be threaded through, got %q", key, captured.IdempotencyKey.String)
	}
}

// statefulUpdateLister lets a test vary GetUpdateByIdempotencyKey's answer
// across calls (first miss, then hit after a simulated concurrent winner),
// mirroring statefulCatsLister above for CreateCatWithMedia's own race.
type statefulUpdateLister struct {
	fakeCatsLister
	onGetIdempotency func() (repository.GetUpdateByIdempotencyKeyRow, error)
}

func (s statefulUpdateLister) GetUpdateByIdempotencyKey(_ context.Context, _ repository.GetUpdateByIdempotencyKeyParams) (repository.GetUpdateByIdempotencyKeyRow, error) {
	return s.onGetIdempotency()
}

func TestCatsService_CreateOrdinaryUpdate_RaceOnIdempotencyKeyRecoversExisting(t *testing.T) {
	existingID := uuid.New()
	firstCall := true
	lister := statefulUpdateLister{
		fakeCatsLister: fakeCatsLister{
			exists:    true,
			createErr: &pgconn.PgError{Code: "23505"},
		},
		onGetIdempotency: func() (repository.GetUpdateByIdempotencyKeyRow, error) {
			if firstCall {
				firstCall = false
				return repository.GetUpdateByIdempotencyKeyRow{}, pgx.ErrNoRows
			}
			return repository.GetUpdateByIdempotencyKeyRow{
				ID:        pgtype.UUID{Bytes: existingID, Valid: true},
				Statuses:  []string{"seen"},
				CreatedAt: pgtype.Timestamptz{Time: time.Date(2026, 3, 1, 9, 5, 0, 0, time.UTC), Valid: true},
			}, nil
		},
	}
	svc := NewCatsService(lister)

	key := "race-seen-key"
	update, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), uuid.New().String(), "", &key, []string{"seen"}, false, nil)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if update.ID != existingID.String() {
		t.Errorf("expected the concurrently-created update to be returned, got %s", update.ID)
	}
}

func TestCatsService_CreateNeedsHelpUpdate_Success(t *testing.T) {
	catID := uuid.New()
	userID := uuid.New()
	deviceID := uuid.New()
	returnedID := uuid.New()
	fixedNow := time.Date(2026, 3, 1, 10, 0, 0, 0, time.UTC)
	var captured repository.CreateOrdinaryUpdateParams
	svc := NewCatsService(fakeCatsLister{
		exists:             true,
		createNeedsHelpRow: repository.CreateUpdateRow{ID: pgtype.UUID{Bytes: returnedID, Valid: true}},
		capturedNeedsHelp:  &captured,
	}, WithClock(func() time.Time { return fixedNow }))

	comment := "sağ arka ayağını basamıyor"
	update, err := svc.CreateNeedsHelpUpdate(context.Background(), catID.String(), userID.String(), deviceID.String(), "injured_or_sick", &comment)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}

	if update.ID != returnedID.String() {
		t.Errorf("expected id %s, got %s", returnedID.String(), update.ID)
	}
	if update.Kind != "needs_help" {
		t.Errorf("expected kind needs_help, got %q", update.Kind)
	}
	if update.NeedsHelpCategory == nil || *update.NeedsHelpCategory != "injured_or_sick" {
		t.Errorf("unexpected needs-help category: %v", update.NeedsHelpCategory)
	}
	if update.NeedsHelpCategoryLabel == nil || *update.NeedsHelpCategoryLabel != needsHelpCategoryLabels["injured_or_sick"] {
		t.Errorf("unexpected needs-help category label: %v", update.NeedsHelpCategoryLabel)
	}
	wantExpiresAt := fixedNow.Add(NeedsHelpExpiry)
	if update.NeedsHelpExpiresAt == nil || !update.NeedsHelpExpiresAt.Equal(wantExpiresAt) {
		t.Errorf("expected expires_at %v, got %v", wantExpiresAt, update.NeedsHelpExpiresAt)
	}
	if update.NeedsHelpActive == nil || !*update.NeedsHelpActive {
		t.Errorf("expected a freshly created needs-help update to be active, got %v", update.NeedsHelpActive)
	}
	if !update.CreatedAt.Equal(fixedNow) {
		t.Errorf("expected server-derived created_at %v, got %v", fixedNow, update.CreatedAt)
	}
	// Statuses must be []string{}, never nil — a nil slice marshals to json
	// `null`, but ListCatUpdates' row.Statuses (a sql coalesce(..., '{}'))
	// never sends null over the wire, and Flutter's CatUpdateEntry.fromJson
	// casts statuses as a non-nullable List.
	if update.Statuses == nil || len(update.Statuses) != 0 {
		t.Errorf("expected non-nil empty statuses, got %v", update.Statuses)
	}

	if uuid.UUID(captured.CatID.Bytes).String() != catID.String() {
		t.Errorf("unexpected repository cat id: %v", captured.CatID)
	}
	if uuid.UUID(captured.AuthorUserID.Bytes).String() != userID.String() {
		t.Errorf("unexpected repository author user id: %v", captured.AuthorUserID)
	}
	if captured.NeedsHelpCategory.String != "injured_or_sick" {
		t.Errorf("unexpected repository category: %q", captured.NeedsHelpCategory.String)
	}
	if !captured.NeedsHelpExpiresAt.Time.Equal(wantExpiresAt) {
		t.Errorf("expected repository expires_at %v, got %v", wantExpiresAt, captured.NeedsHelpExpiresAt.Time)
	}
}

func TestCatsService_CreateNeedsHelpUpdate_InvalidCategory(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: true})

	cases := []string{"", "flying", "INJURED_OR_SICK", "injured_sick"}
	for _, category := range cases {
		t.Run(category, func(t *testing.T) {
			if _, err := svc.CreateNeedsHelpUpdate(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String(), category, nil); !errors.Is(err, ErrInvalidNeedsHelpCategory) {
				t.Fatalf("expected ErrInvalidNeedsHelpCategory, got %v", err)
			}
		})
	}
}

func TestCatsService_CreateNeedsHelpUpdate_InvalidUserID(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: true})
	_, err := svc.CreateNeedsHelpUpdate(context.Background(), uuid.New().String(), "not-a-uuid", "", "trapped", nil)
	if err == nil {
		t.Fatal("expected error for invalid user id, got nil")
	}
}

func TestCatsService_CreateNeedsHelpUpdate_InvalidCatID(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{})
	_, err := svc.CreateNeedsHelpUpdate(context.Background(), "not-a-uuid", uuid.New().String(), uuid.New().String(), "trapped", nil)
	if !errors.Is(err, ErrInvalidCatID) {
		t.Fatalf("expected ErrInvalidCatID, got %v", err)
	}
}

func TestCatsService_CreateNeedsHelpUpdate_UnknownCat(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: false})
	_, err := svc.CreateNeedsHelpUpdate(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String(), "trapped", nil)
	if !errors.Is(err, ErrCatNotFound) {
		t.Fatalf("expected ErrCatNotFound, got %v", err)
	}
}

func TestCatsService_CreateNeedsHelpUpdate_RepositoryFailure(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: true, createNeedsHelpErr: errors.New("connection refused")})
	_, err := svc.CreateNeedsHelpUpdate(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String(), "trapped", nil)
	if err == nil {
		t.Fatal("expected an error, got nil")
	}
}

// istanbulLat/istanbulLng are inside istanbulBounds (Kadıköy-ish); parisLat/
// parisLng are well outside it, for area-validation tests.
const (
	istanbulLat = 41.03
	istanbulLng = 28.98
	parisLat    = 48.85
	parisLng    = 2.35
)

func TestCatsService_Create_Success(t *testing.T) {
	userID := uuid.New()
	deviceID := uuid.New()
	createdCatID := uuid.New()
	createdMediaID := uuid.New()
	fixedNow := time.Date(2026, 2, 1, 10, 0, 0, 0, time.UTC)

	var captured repository.CreateCatWithMediaParams
	store := &fakeObjectStore{}
	name := "Boncuk"
	svc := NewCatsService(fakeCatsLister{
		createCatWithMediaRow: repository.CreateCatWithMediaRow{
			Cat: repository.CreateCatRow{
				ID:        pgtype.UUID{Bytes: createdCatID, Valid: true},
				Name:      pgtype.Text{String: name, Valid: true},
				Lat:       istanbulLat,
				Lng:       istanbulLng,
				CreatedAt: pgtype.Timestamptz{Time: fixedNow, Valid: true},
			},
			Media: repository.Medium{ID: pgtype.UUID{Bytes: createdMediaID, Valid: true}, Url: "/v1/media/objects/new.jpg"},
		},
		capturedCreateCat: &captured,
	}, WithCatsMediaPipeline(store, 1<<20), WithClock(func() time.Time { return fixedNow }))

	cat, err := svc.Create(context.Background(), userID.String(), deviceID.String(), nil, istanbulLat, istanbulLng, &name, true, validJPEGBytes(t))
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if cat.ID != createdCatID.String() {
		t.Errorf("expected cat id %s, got %s", createdCatID.String(), cat.ID)
	}
	if len(store.puts) != 1 {
		t.Fatalf("expected exactly one object stored, got %d", len(store.puts))
	}
	wantURL := "/v1/media/objects/" + store.puts[0]
	if cat.PrimaryPhoto == nil || *cat.PrimaryPhoto != wantURL {
		t.Errorf("expected primary photo url %q from the just-uploaded media, got %v", wantURL, cat.PrimaryPhoto)
	}
	if uuid.UUID(captured.Cat.CreatedByUserID.Bytes).String() != userID.String() {
		t.Errorf("expected created_by_user_id %s, got %v", userID.String(), captured.Cat.CreatedByUserID)
	}
	if uuid.UUID(captured.Cat.CreatedByDeviceID.Bytes).String() != deviceID.String() {
		t.Errorf("expected created_by_device_id %s, got %v", deviceID.String(), captured.Cat.CreatedByDeviceID)
	}
	if uuid.UUID(captured.Media.UploadedByUserID.Bytes).String() != userID.String() {
		t.Errorf("expected uploaded_by_user_id %s, got %v", userID.String(), captured.Media.UploadedByUserID)
	}
}

func TestCatsService_Create_InvalidArea(t *testing.T) {
	store := &fakeObjectStore{}
	svc := NewCatsService(fakeCatsLister{}, WithCatsMediaPipeline(store, 1<<20))

	_, err := svc.Create(context.Background(), uuid.New().String(), "", nil, parisLat, parisLng, nil, true, validJPEGBytes(t))
	if !errors.Is(err, ErrInvalidArea) {
		t.Fatalf("expected ErrInvalidArea, got %v", err)
	}
	if len(store.puts) != 0 {
		t.Error("expected no upload attempt for an out-of-bounds area")
	}
}

func TestCatsService_Create_MissingPhoto(t *testing.T) {
	store := &fakeObjectStore{}
	svc := NewCatsService(fakeCatsLister{}, WithCatsMediaPipeline(store, 1<<20))

	_, err := svc.Create(context.Background(), uuid.New().String(), "", nil, istanbulLat, istanbulLng, nil, true, nil)
	if !errors.Is(err, ErrMissingPhoto) {
		t.Fatalf("expected ErrMissingPhoto, got %v", err)
	}
}

func TestCatsService_Create_NoPipelineConfiguredFailsGracefully(t *testing.T) {
	// NewCatsService without WithCatsMediaPipeline — Create must return a
	// clear error, not panic on a nil s.pipeline dereference.
	svc := NewCatsService(fakeCatsLister{})

	_, err := svc.Create(context.Background(), uuid.New().String(), "", nil, istanbulLat, istanbulLng, nil, true, []byte("x"))
	if !errors.Is(err, ErrMediaPipelineNotConfigured) {
		t.Fatalf("expected ErrMediaPipelineNotConfigured, got %v", err)
	}
}

func TestCatsService_Create_DuplicateCandidatesNonBlocking(t *testing.T) {
	nearbyID := uuid.New()
	store := &fakeObjectStore{}
	var captured repository.CreateCatWithMediaParams
	svc := NewCatsService(fakeCatsLister{
		nearbyDuplicateRows: []repository.ListNearbyCatsForDuplicateCheckRow{
			{ID: pgtype.UUID{Bytes: nearbyID, Valid: true}, Name: pgtype.Text{String: "existing cat", Valid: true}, PhotoUrl: "https://example.com/cat.jpg"},
		},
		capturedCreateCat: &captured,
	}, WithCatsMediaPipeline(store, 1<<20))

	_, err := svc.Create(context.Background(), uuid.New().String(), "", nil, istanbulLat, istanbulLng, nil, false, validJPEGBytes(t))

	var dupErr *DuplicateCandidatesError
	if !errors.As(err, &dupErr) {
		t.Fatalf("expected *DuplicateCandidatesError, got %v", err)
	}
	if len(dupErr.Candidates) != 1 || dupErr.Candidates[0].ID != nearbyID.String() {
		t.Errorf("unexpected candidates: %+v", dupErr.Candidates)
	}
	// advisory only: creation must not have been attempted, and nothing uploaded.
	if len(store.puts) != 0 {
		t.Error("expected no upload when short-circuited by duplicate candidates")
	}
	if captured.Cat.ID.Valid {
		t.Error("expected CreateCatWithMedia to never be called when duplicates block (non-confirmed) submission")
	}
}

func TestCatsService_Create_ConfirmedNewBypassesDuplicateCheck(t *testing.T) {
	store := &fakeObjectStore{}
	var captured repository.CreateCatWithMediaParams
	svc := NewCatsService(fakeCatsLister{
		nearbyDuplicateRows: []repository.ListNearbyCatsForDuplicateCheckRow{
			{ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}, Name: pgtype.Text{String: "existing cat", Valid: true}},
		},
		createCatWithMediaRow: repository.CreateCatWithMediaRow{
			Cat:   repository.CreateCatRow{ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}},
			Media: repository.Medium{ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}, Url: "/v1/media/objects/x.jpg"},
		},
		capturedCreateCat: &captured,
	}, WithCatsMediaPipeline(store, 1<<20))

	_, err := svc.Create(context.Background(), uuid.New().String(), "", nil, istanbulLat, istanbulLng, nil, true, validJPEGBytes(t))
	if err != nil {
		t.Fatalf("expected confirmed_new to bypass duplicate candidates, got error: %v", err)
	}
	if !captured.Cat.ID.Valid {
		t.Error("expected CreateCatWithMedia to be called when confirmedNew is true")
	}
}

func TestCatsService_Create_IdempotentRetryReturnsExistingWithoutReupload(t *testing.T) {
	existingID := uuid.New()
	store := &fakeObjectStore{}
	var captured repository.CreateCatWithMediaParams
	svc := NewCatsService(fakeCatsLister{
		idempotencyRow: repository.GetCatByIdempotencyKeyRow{
			ID: pgtype.UUID{Bytes: existingID, Valid: true}, Lat: istanbulLat, Lng: istanbulLng,
		},
		catRow: repository.GetCatByIDRow{
			ID: pgtype.UUID{Bytes: existingID, Valid: true}, Lat: istanbulLat, Lng: istanbulLng,
			PhotoUrl: "/v1/media/objects/already-created.jpg",
		},
		capturedCreateCat: &captured,
	}, WithCatsMediaPipeline(store, 1<<20))

	key := "cat-idem-key"
	cat, err := svc.Create(context.Background(), uuid.New().String(), "", &key, istanbulLat, istanbulLng, nil, true, validJPEGBytes(t))
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if cat.ID != existingID.String() {
		t.Errorf("expected the existing cat's id %s, got %s", existingID.String(), cat.ID)
	}
	if len(store.puts) != 0 {
		t.Error("expected no upload on an idempotent retry")
	}
	if captured.Cat.ID.Valid {
		t.Error("expected CreateCatWithMedia to never be called on an idempotent retry")
	}
}

func TestCatsService_Create_CompensatesOnDBFailure(t *testing.T) {
	store := &fakeObjectStore{}
	svc := NewCatsService(fakeCatsLister{
		createCatWithMediaErr: errors.New("db exploded"),
	}, WithCatsMediaPipeline(store, 1<<20))

	if _, err := svc.Create(context.Background(), uuid.New().String(), "", nil, istanbulLat, istanbulLng, nil, true, validJPEGBytes(t)); err == nil {
		t.Fatal("expected an error")
	}
	if len(store.puts) != 1 {
		t.Fatalf("expected the object to have been uploaded once, got %v", store.puts)
	}
	if len(store.deletes) != 1 || store.deletes[0] != store.puts[0] {
		t.Errorf("expected the uploaded object to be compensated (deleted) after the db failure, got puts=%v deletes=%v", store.puts, store.deletes)
	}
}

// statefulCatsLister lets a test vary GetCatByIdempotencyKey's answer across
// calls (first miss, then hit) without a full mock framework — mirrors
// statefulMediaStore in media_test.go.
type statefulCatsLister struct {
	fakeCatsLister
	onGetIdempotency func() (repository.GetCatByIdempotencyKeyRow, error)
}

func (s statefulCatsLister) GetCatByIdempotencyKey(_ context.Context, _ repository.GetCatByIdempotencyKeyParams) (repository.GetCatByIdempotencyKeyRow, error) {
	return s.onGetIdempotency()
}

func TestCatsService_Create_RaceOnIdempotencyKeyRecoversExisting(t *testing.T) {
	existingID := uuid.New()
	store := &fakeObjectStore{}
	firstCall := true
	lister := statefulCatsLister{
		fakeCatsLister: fakeCatsLister{
			createCatWithMediaErr: pgx.ErrNoRows,
			catRow: repository.GetCatByIDRow{
				ID: pgtype.UUID{Bytes: existingID, Valid: true}, Lat: istanbulLat, Lng: istanbulLng,
				PhotoUrl: "/v1/media/objects/won-the-race.jpg",
			},
		},
		onGetIdempotency: func() (repository.GetCatByIdempotencyKeyRow, error) {
			if firstCall {
				firstCall = false
				return repository.GetCatByIdempotencyKeyRow{}, pgx.ErrNoRows
			}
			return repository.GetCatByIdempotencyKeyRow{ID: pgtype.UUID{Bytes: existingID, Valid: true}}, nil
		},
	}
	svc := NewCatsService(lister, WithCatsMediaPipeline(store, 1<<20))

	key := "race-cat-key"
	cat, err := svc.Create(context.Background(), uuid.New().String(), "", &key, istanbulLat, istanbulLng, nil, true, validJPEGBytes(t))
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if cat.ID != existingID.String() {
		t.Errorf("expected the concurrently-created cat to be returned, got %s", cat.ID)
	}
	if len(store.deletes) != 1 {
		t.Errorf("expected this attempt's own upload to be cleaned up, got %v", store.deletes)
	}
}

func TestCatsService_ListNearbyDuplicates_Success(t *testing.T) {
	nearbyID := uuid.New()
	svc := NewCatsService(fakeCatsLister{
		nearbyDuplicateRows: []repository.ListNearbyCatsForDuplicateCheckRow{
			{ID: pgtype.UUID{Bytes: nearbyID, Valid: true}, Name: pgtype.Text{String: "tekir", Valid: true}, PhotoUrl: "https://example.com/cat.jpg"},
		},
	})

	candidates, err := svc.ListNearbyDuplicates(context.Background(), istanbulLat, istanbulLng)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(candidates) != 1 || candidates[0].ID != nearbyID.String() {
		t.Errorf("unexpected candidates: %+v", candidates)
	}
}

func TestCatsService_ListNearbyDuplicates_InvalidArea(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{})

	if _, err := svc.ListNearbyDuplicates(context.Background(), parisLat, parisLng); !errors.Is(err, ErrInvalidArea) {
		t.Fatalf("expected ErrInvalidArea, got %v", err)
	}
}

// statusCorrection builds the presence-aware correction most tests need:
// an explicit status replacement with no comment or help-flag change.
func statusCorrection(statuses ...string) UpdateCorrection {
	return UpdateCorrection{Statuses: &statuses}
}

func TestCatsService_CorrectOwnUpdate_Success(t *testing.T) {
	catID := uuid.New()
	updateID := uuid.New()
	userID := uuid.New()
	createdAt := time.Date(2026, 1, 5, 8, 0, 0, 0, time.UTC)
	fixedNow := createdAt.Add(3 * time.Minute)

	var captured repository.CorrectOwnUpdateParams
	svc := NewCatsService(fakeCatsLister{
		correctRow: repository.CorrectOwnUpdateRow{
			CorrectOrdinaryUpdateRow: repository.CorrectOrdinaryUpdateRow{
				ID:        pgtype.UUID{Bytes: updateID, Valid: true},
				CreatedAt: pgtype.Timestamptz{Time: createdAt, Valid: true},
				UpdatedAt: pgtype.Timestamptz{Time: fixedNow, Valid: true},
			},
			Statuses: []string{"fed", "water_provided"},
		},
		capturedCorrect: &captured,
	}, WithClock(func() time.Time { return fixedNow }))

	comment := "düzeltildi"
	statuses := []string{"water_provided", "fed"}
	update, err := svc.CorrectOwnUpdate(context.Background(), catID.String(), updateID.String(), userID.String(), UpdateCorrection{
		Statuses:   &statuses,
		SetComment: true,
		Comment:    &comment,
	})
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if update.ID != updateID.String() {
		t.Errorf("expected id %s, got %s", updateID.String(), update.ID)
	}
	if !update.AuthorIsMe {
		t.Error("expected AuthorIsMe true on a successful own-correction")
	}
	if update.CorrectionExpiresAt == nil || !update.CorrectionExpiresAt.Equal(createdAt.Add(updateCorrectionWindow)) {
		t.Errorf("expected correction_expires_at %v, got %v", createdAt.Add(updateCorrectionWindow), update.CorrectionExpiresAt)
	}
	if update.UpdatedAt == nil || !update.UpdatedAt.Equal(fixedNow) {
		t.Errorf("expected updated_at %v, got %v", fixedNow, update.UpdatedAt)
	}
	// statuses come back sorted, mirroring CreateOrdinaryUpdate.
	if len(update.Statuses) != 2 || update.Statuses[0] != "fed" || update.Statuses[1] != "water_provided" {
		t.Errorf("expected sorted statuses [fed water_provided], got %v", update.Statuses)
	}

	if !captured.ReplaceStatuses {
		t.Error("expected ReplaceStatuses true when the request supplied a status set")
	}
	if len(captured.Statuses) != 2 || captured.Statuses[0] != "fed" || captured.Statuses[1] != "water_provided" {
		t.Errorf("expected repository statuses sorted [fed water_provided], got %v", captured.Statuses)
	}
	if !captured.SetComment {
		t.Error("expected SetComment true when the request supplied a comment")
	}
	if uuid.UUID(captured.AuthorUserID.Bytes).String() != userID.String() {
		t.Errorf("unexpected repository author user id: %v", captured.AuthorUserID)
	}
	wantWindowStart := fixedNow.Add(-updateCorrectionWindow)
	if !captured.WindowStart.Time.Equal(wantWindowStart) {
		t.Errorf("expected window_start %v (now - 10m), got %v", wantWindowStart, captured.WindowStart.Time)
	}
}

func TestCatsService_CorrectOwnUpdate_InvalidStatusesNeverReachesStore(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{})
	_, err := svc.CorrectOwnUpdate(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String(), statusCorrection("not_a_real_status"))
	if !errors.Is(err, ErrInvalidStatuses) {
		t.Fatalf("expected ErrInvalidStatuses, got %v", err)
	}
}

func TestCatsService_CorrectOwnUpdate_WrongAuthor(t *testing.T) {
	catID := uuid.New()
	updateID := uuid.New()
	realAuthor := uuid.New()
	stranger := uuid.New()
	createdAt := time.Now()

	svc := NewCatsService(fakeCatsLister{
		correctErr: pgx.ErrNoRows,
		correctionCheckRow: repository.GetUpdateForCorrectionCheckRow{
			ID:           pgtype.UUID{Bytes: updateID, Valid: true},
			CatID:        pgtype.UUID{Bytes: catID, Valid: true},
			AuthorUserID: pgtype.UUID{Bytes: realAuthor, Valid: true},
			Kind:         "ordinary",
			CreatedAt:    pgtype.Timestamptz{Time: createdAt, Valid: true},
		},
	}, WithClock(func() time.Time { return createdAt.Add(time.Minute) }))

	_, err := svc.CorrectOwnUpdate(context.Background(), catID.String(), updateID.String(), stranger.String(), statusCorrection("seen"))
	if !errors.Is(err, ErrNotUpdateAuthor) {
		t.Fatalf("expected ErrNotUpdateAuthor, got %v", err)
	}
}

func TestCatsService_CorrectOwnUpdate_WindowExpired(t *testing.T) {
	catID := uuid.New()
	updateID := uuid.New()
	userID := uuid.New()
	createdAt := time.Date(2026, 1, 5, 8, 0, 0, 0, time.UTC)
	fixedNow := createdAt.Add(11 * time.Minute)

	svc := NewCatsService(fakeCatsLister{
		correctErr: pgx.ErrNoRows,
		correctionCheckRow: repository.GetUpdateForCorrectionCheckRow{
			ID:           pgtype.UUID{Bytes: updateID, Valid: true},
			CatID:        pgtype.UUID{Bytes: catID, Valid: true},
			AuthorUserID: pgtype.UUID{Bytes: userID, Valid: true},
			Kind:         "ordinary",
			CreatedAt:    pgtype.Timestamptz{Time: createdAt, Valid: true},
		},
	}, WithClock(func() time.Time { return fixedNow }))

	_, err := svc.CorrectOwnUpdate(context.Background(), catID.String(), updateID.String(), userID.String(), statusCorrection("seen"))
	if !errors.Is(err, ErrCorrectionWindowExpired) {
		t.Fatalf("expected ErrCorrectionWindowExpired, got %v", err)
	}
}

func TestCatsService_CorrectOwnUpdate_NeedsHelpKindIsNotFound(t *testing.T) {
	catID := uuid.New()
	updateID := uuid.New()
	userID := uuid.New()
	createdAt := time.Now()

	svc := NewCatsService(fakeCatsLister{
		correctErr: pgx.ErrNoRows,
		correctionCheckRow: repository.GetUpdateForCorrectionCheckRow{
			ID:           pgtype.UUID{Bytes: updateID, Valid: true},
			CatID:        pgtype.UUID{Bytes: catID, Valid: true},
			AuthorUserID: pgtype.UUID{Bytes: userID, Valid: true},
			Kind:         "needs_help",
			CreatedAt:    pgtype.Timestamptz{Time: createdAt, Valid: true},
		},
	}, WithClock(func() time.Time { return createdAt.Add(time.Minute) }))

	_, err := svc.CorrectOwnUpdate(context.Background(), catID.String(), updateID.String(), userID.String(), statusCorrection("seen"))
	if !errors.Is(err, ErrUpdateNotFound) {
		t.Fatalf("expected ErrUpdateNotFound for a needs-help update, got %v", err)
	}
}

func TestCatsService_CorrectOwnUpdate_UnknownUpdateIsNotFound(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{
		correctErr:         pgx.ErrNoRows,
		correctionCheckErr: pgx.ErrNoRows,
	})

	_, err := svc.CorrectOwnUpdate(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String(), statusCorrection("seen"))
	if !errors.Is(err, ErrUpdateNotFound) {
		t.Fatalf("expected ErrUpdateNotFound for an unknown update id, got %v", err)
	}
}

func TestCatsService_DeleteOwnUpdate_Success(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{
		deleteRow: repository.DeleteOwnUpdateRow{ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}},
	})
	if err := svc.DeleteOwnUpdate(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String()); err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
}

func TestCatsService_DeleteOwnUpdate_RetryAfterDeleteIsIdempotent(t *testing.T) {
	userID := uuid.New()
	svc := NewCatsService(fakeCatsLister{
		deleteErr: pgx.ErrNoRows,
		correctionCheckRow: repository.GetUpdateForCorrectionCheckRow{
			AuthorUserID: pgtype.UUID{Bytes: userID, Valid: true},
			Kind:         "ordinary",
			CreatedAt:    pgtype.Timestamptz{Time: time.Now(), Valid: true},
			DeletedAt:    pgtype.Timestamptz{Time: time.Now(), Valid: true},
		},
	})

	if err := svc.DeleteOwnUpdate(context.Background(), uuid.New().String(), uuid.New().String(), userID.String()); err != nil {
		t.Fatalf("expected a retry against an already-deleted update to succeed as a no-op, got %v", err)
	}
}

func TestCatsService_DeleteOwnUpdate_WrongAuthor(t *testing.T) {
	realAuthor := uuid.New()
	stranger := uuid.New()
	svc := NewCatsService(fakeCatsLister{
		deleteErr: pgx.ErrNoRows,
		correctionCheckRow: repository.GetUpdateForCorrectionCheckRow{
			AuthorUserID: pgtype.UUID{Bytes: realAuthor, Valid: true},
			Kind:         "ordinary",
			CreatedAt:    pgtype.Timestamptz{Time: time.Now(), Valid: true},
		},
	})

	err := svc.DeleteOwnUpdate(context.Background(), uuid.New().String(), uuid.New().String(), stranger.String())
	if !errors.Is(err, ErrNotUpdateAuthor) {
		t.Fatalf("expected ErrNotUpdateAuthor, got %v", err)
	}
}

func TestCatsService_DeleteOwnUpdate_WindowExpired(t *testing.T) {
	userID := uuid.New()
	createdAt := time.Date(2026, 1, 5, 8, 0, 0, 0, time.UTC)
	svc := NewCatsService(fakeCatsLister{
		deleteErr: pgx.ErrNoRows,
		correctionCheckRow: repository.GetUpdateForCorrectionCheckRow{
			AuthorUserID: pgtype.UUID{Bytes: userID, Valid: true},
			Kind:         "ordinary",
			CreatedAt:    pgtype.Timestamptz{Time: createdAt, Valid: true},
		},
	}, WithClock(func() time.Time { return createdAt.Add(11 * time.Minute) }))

	err := svc.DeleteOwnUpdate(context.Background(), uuid.New().String(), uuid.New().String(), userID.String())
	if !errors.Is(err, ErrCorrectionWindowExpired) {
		t.Fatalf("expected ErrCorrectionWindowExpired, got %v", err)
	}
}

// galataLat/galataLng are a real inside-istanbulBounds coordinate (Galata
// Kulesi), reused across ListDiscover tests exactly like
// TestCatsService_ListNearby above reuses the same landmark for its own
// fixture coordinates.
const (
	galataLat = 41.0256
	galataLng = 28.9744
)

func TestCatsService_ListDiscover_InvalidFilter(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{})

	_, err := svc.ListDiscover(context.Background(), "popular", galataLat, galataLng, "", 0)
	if !errors.Is(err, ErrInvalidDiscoverFilter) {
		t.Fatalf("expected ErrInvalidDiscoverFilter, got %v", err)
	}
}

func TestCatsService_ListDiscover_InvalidArea(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{})

	// well outside istanbulBounds (e.g. ankara).
	_, err := svc.ListDiscover(context.Background(), discoverFilterNearby, 39.93, 32.85, "", 0)
	if !errors.Is(err, ErrInvalidArea) {
		t.Fatalf("expected ErrInvalidArea, got %v", err)
	}
}

func TestCatsService_ListDiscover_InvalidLimit(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{})

	for _, limit := range []int{-1, maxDiscoverLimit + 1} {
		if _, err := svc.ListDiscover(context.Background(), discoverFilterNearby, galataLat, galataLng, "", limit); !errors.Is(err, ErrInvalidLimit) {
			t.Errorf("limit %d: expected ErrInvalidLimit, got %v", limit, err)
		}
	}
}

func TestCatsService_ListDiscover_InvalidCursor(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{})

	_, err := svc.ListDiscover(context.Background(), discoverFilterNearby, galataLat, galataLng, "not-base64!!", 0)
	if !errors.Is(err, ErrInvalidCursor) {
		t.Fatalf("expected ErrInvalidCursor, got %v", err)
	}
}

func TestCatsService_ListDiscover_Nearby_PaginatesAndEncodesCursor(t *testing.T) {
	nearID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	midID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	farID := pgtype.UUID{Bytes: uuid.New(), Valid: true}

	var captured repository.ListCatsByDistanceParams
	svc := NewCatsService(fakeCatsLister{
		capturedDistance: &captured,
		// limit+1 rows, exactly like ListCatUpdates' own pagination test.
		distanceRows: []repository.ListCatsByDistanceRow{
			{ID: nearID, Name: pgtype.Text{String: "tekir", Valid: true}, PhotoUrl: "https://placecats.com/a/200/200", DistanceM: 50},
			{ID: midID, Name: pgtype.Text{String: "boncuk", Valid: true}, PhotoUrl: "https://placecats.com/b/200/200", DistanceM: 120},
			{ID: farID, Name: pgtype.Text{String: "pamuk", Valid: true}, PhotoUrl: "https://placecats.com/c/200/200", DistanceM: 900},
		},
	})

	page, err := svc.ListDiscover(context.Background(), discoverFilterNearby, galataLat, galataLng, "", 2)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(page.Items) != 2 {
		t.Fatalf("expected 2 items on the first page, got %d", len(page.Items))
	}
	if page.Items[0].DistanceMeters != 50 || page.Items[1].DistanceMeters != 120 {
		t.Errorf("unexpected distances: %v, %v", page.Items[0].DistanceMeters, page.Items[1].DistanceMeters)
	}
	if page.NextCursor == "" {
		t.Fatal("expected a next cursor, got none")
	}

	// the request reaching the store must ask for limit+1 rows and carry
	// the caller's own lat/lng through untouched.
	if captured.RowLimit != 3 {
		t.Errorf("expected row_limit 3 (limit+1), got %d", captured.RowLimit)
	}
	if captured.Lat != galataLat || captured.Lng != galataLng {
		t.Errorf("expected lat/lng %v/%v, got %v/%v", galataLat, galataLng, captured.Lat, captured.Lng)
	}
	if captured.AfterDistanceM.Valid {
		t.Errorf("expected no after_distance_m on the first page, got %v", captured.AfterDistanceM)
	}

	// the cursor must round-trip back to the position of the last item served.
	decoded, err := decodeDiscoverCursor(page.NextCursor)
	if err != nil {
		t.Fatalf("expected cursor to decode, got %v", err)
	}
	if decoded.distanceMeters != 120 || decoded.id != uuid.UUID(midID.Bytes).String() {
		t.Errorf("expected cursor at (120, %s), got (%v, %s)", uuid.UUID(midID.Bytes).String(), decoded.distanceMeters, decoded.id)
	}

	// a second page, presenting that cursor, must decode it back into the
	// after_distance_m/after_id the store receives — real windowing (the
	// store actually honoring that predicate to return the next rows) is
	// postgres's job, exercised by the repository integration test, not
	// this fake, which always returns the same fixed rows regardless of
	// what it was asked for.
	if _, err := svc.ListDiscover(context.Background(), discoverFilterNearby, galataLat, galataLng, page.NextCursor, 2); err != nil {
		t.Fatalf("expected no error on second page, got %v", err)
	}
	if !captured.AfterDistanceM.Valid || captured.AfterDistanceM.Float64 != 120 {
		t.Errorf("expected after_distance_m 120, got %v", captured.AfterDistanceM)
	}
	if uuid.UUID(captured.AfterID.Bytes).String() != uuid.UUID(midID.Bytes).String() {
		t.Errorf("expected after_id %s, got %s", uuid.UUID(midID.Bytes).String(), uuid.UUID(captured.AfterID.Bytes).String())
	}
}

func TestCatsService_ListDiscover_Nearby_NoNextPageWhenExactlyLimitRows(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{
		distanceRows: []repository.ListCatsByDistanceRow{
			{ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}, DistanceM: 50},
		},
	})

	page, err := svc.ListDiscover(context.Background(), discoverFilterNearby, galataLat, galataLng, "", 5)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(page.Items) != 1 {
		t.Fatalf("expected 1 item, got %d", len(page.Items))
	}
	if page.NextCursor != "" {
		t.Errorf("expected no next cursor when fewer rows than limit+1 came back, got %q", page.NextCursor)
	}
}

func TestCatsService_ListDiscover_NeedsHelp_PassesClockAsNow(t *testing.T) {
	fixedNow := time.Date(2026, 2, 1, 10, 0, 0, 0, time.UTC)
	var captured repository.ListActiveNeedsHelpCatsByDistanceParams
	svc := NewCatsService(fakeCatsLister{
		capturedNeedsHelpDistance: &captured,
		needsHelpDistanceRows: []repository.ListActiveNeedsHelpCatsByDistanceRow{
			{
				ID:                 pgtype.UUID{Bytes: uuid.New(), Valid: true},
				NeedsHelpCategory:  pgtype.Text{String: "injured_or_sick", Valid: true},
				NeedsHelpCreatedAt: pgtype.Timestamptz{Time: fixedNow.Add(-time.Hour), Valid: true},
				NeedsHelpExpiresAt: pgtype.Timestamptz{Time: fixedNow.Add(time.Hour), Valid: true},
				DistanceM:          200,
			},
		},
	}, WithClock(func() time.Time { return fixedNow }))

	page, err := svc.ListDiscover(context.Background(), discoverFilterNeedsHelp, galataLat, galataLng, "", 0)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if !captured.Now.Valid || !captured.Now.Time.Equal(fixedNow) {
		t.Fatalf("expected the query's now param to equal the service's own clock, got %v", captured.Now)
	}
	if len(page.Items) != 1 {
		t.Fatalf("expected 1 item, got %d", len(page.Items))
	}
	if page.Items[0].ActiveAlert == nil {
		t.Fatal("expected an active alert to be derived for a row the needs_help query already filtered as active")
	}
	if page.Items[0].ActiveAlert.Category != "injured_or_sick" {
		t.Errorf("unexpected category: %s", page.Items[0].ActiveAlert.Category)
	}
}

// TestCatsService_ListDiscover_NeedsHelp_ExactExpiryBoundary mirrors
// TestCatsService_ListNearby_ActiveAlertBoundaries: deriveActiveAlert treats
// an update expiring at exactly the clock's current instant as no longer
// active (!expiresAt.After(clock()), not >=) — this only matters here
// because ListDiscover reuses one pinned `now` reading (see its own
// comment) for both the query param an integration-tested database would
// filter on and this in-process derivation; a row that (in a real database)
// could never actually be returned by the needs_help query at this exact
// boundary is still exercised here to prove the Go-side derivation agrees
// with the SQL-side boundary rather than drifting a moment later.
func TestCatsService_ListDiscover_NeedsHelp_ExactExpiryBoundary(t *testing.T) {
	fixedNow := time.Date(2026, 2, 1, 10, 0, 0, 0, time.UTC)
	svc := NewCatsService(fakeCatsLister{
		needsHelpDistanceRows: []repository.ListActiveNeedsHelpCatsByDistanceRow{
			{
				ID:                 pgtype.UUID{Bytes: uuid.New(), Valid: true},
				NeedsHelpCategory:  pgtype.Text{String: "trapped", Valid: true},
				NeedsHelpCreatedAt: pgtype.Timestamptz{Time: fixedNow.Add(-time.Hour), Valid: true},
				NeedsHelpExpiresAt: pgtype.Timestamptz{Time: fixedNow, Valid: true},
				DistanceM:          75,
			},
		},
	}, WithClock(func() time.Time { return fixedNow }))

	page, err := svc.ListDiscover(context.Background(), discoverFilterNeedsHelp, galataLat, galataLng, "", 0)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if page.Items[0].ActiveAlert != nil {
		t.Error("expected no active alert exactly at the expiry boundary")
	}
}

func TestCatsService_ListDiscover_EmptyResult(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{})

	page, err := svc.ListDiscover(context.Background(), discoverFilterNearby, galataLat, galataLng, "", 0)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(page.Items) != 0 {
		t.Fatalf("expected no items, got %d", len(page.Items))
	}
	if page.NextCursor != "" {
		t.Errorf("expected no next cursor for an empty result, got %v", page.NextCursor)
	}
}

// TestCatsService_ListCatMedia covers issue #121's media-archive parity
// gap: the archive comes back newest-first with the cover entry flagged.
func TestCatsService_ListCatMedia(t *testing.T) {
	coverID := uuid.New()
	otherID := uuid.New()
	newest := time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC)
	oldest := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

	svc := NewCatsService(fakeCatsLister{
		exists: true,
		mediaRows: []repository.ListCatMediaRow{
			{ID: pgtype.UUID{Bytes: otherID, Valid: true}, Url: "https://placecats.com/a/300/200", CreatedAt: pgtype.Timestamptz{Time: newest, Valid: true}, IsCover: false},
			{ID: pgtype.UUID{Bytes: coverID, Valid: true}, Url: "https://placecats.com/millie/300/200", CreatedAt: pgtype.Timestamptz{Time: oldest, Valid: true}, IsCover: true},
		},
	})

	items, err := svc.ListCatMedia(context.Background(), uuid.New().String())
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(items) != 2 {
		t.Fatalf("expected 2 items, got %d", len(items))
	}
	if items[1].ID != coverID.String() || !items[1].IsCover {
		t.Errorf("expected the second item to be the flagged cover, got %+v", items[1])
	}
	if items[0].IsCover {
		t.Errorf("expected the first item not to be flagged as cover, got %+v", items[0])
	}
}

func TestCatsService_ListCatMedia_UnknownCat(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: false})

	if _, err := svc.ListCatMedia(context.Background(), uuid.New().String()); !errors.Is(err, ErrCatNotFound) {
		t.Errorf("expected ErrCatNotFound, got %v", err)
	}
}

func TestCatsService_ListCatMedia_InvalidCatID(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{})

	if _, err := svc.ListCatMedia(context.Background(), "not-a-uuid"); !errors.Is(err, ErrInvalidCatID) {
		t.Errorf("expected ErrInvalidCatID, got %v", err)
	}
}
