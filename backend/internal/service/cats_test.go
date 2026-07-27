package service

import (
	"context"
	"errors"
	"math"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
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
	capturedNeedsHelp *repository.CreateNeedsHelpUpdateParams

	idempotencyRow repository.GetCatByIdempotencyKeyRow
	idempotencyErr error

	nearbyDuplicateRows []repository.ListNearbyCatsForDuplicateCheckRow
	nearbyDuplicateErr  error

	createCatWithMediaRow repository.CreateCatWithMediaRow
	createCatWithMediaErr error
	// capturedCreateCat, if non-nil, records the arg the last
	// CreateCatWithMedia call received, mirroring captured above.
	capturedCreateCat *repository.CreateCatWithMediaParams

	correctRow repository.CorrectOrdinaryUpdateRow
	correctErr error
	// capturedCorrect mirrors captured above, for CorrectOwnUpdate.
	capturedCorrect *repository.CorrectOwnUpdateParams

	deleteRow repository.DeleteOwnUpdateRow
	deleteErr error

	correctionCheckRow repository.GetUpdateForCorrectionCheckRow
	correctionCheckErr error
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
	if f.captured != nil {
		*f.captured = arg
	}
	return f.createRow, f.createErr
}

func (f fakeCatsLister) CreateNeedsHelpUpdate(ctx context.Context, arg repository.CreateNeedsHelpUpdateParams) (repository.CreateUpdateRow, error) {
	if f.capturedNeedsHelp != nil {
		*f.capturedNeedsHelp = arg
	}
	return f.createNeedsHelpRow, f.createNeedsHelpErr
}

func (f fakeCatsLister) GetCatByIdempotencyKey(ctx context.Context, arg repository.GetCatByIdempotencyKeyParams) (repository.GetCatByIdempotencyKeyRow, error) {
	return f.idempotencyRow, f.idempotencyErr
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

func (f fakeCatsLister) CorrectOwnUpdate(ctx context.Context, arg repository.CorrectOwnUpdateParams) (repository.CorrectOrdinaryUpdateRow, error) {
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
	update, err := svc.CreateOrdinaryUpdate(context.Background(), catID.String(), userID.String(), deviceID.String(), []string{"water_provided", "fed"}, &comment)
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

	update, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String(), []string{"seen"}, nil)
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
	if _, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), userID.String(), "", []string{"seen"}, nil); err != nil {
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
	_, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), "not-a-uuid", "", []string{"seen"}, nil)
	if err == nil {
		t.Fatal("expected error for invalid user id, got nil")
	}
}

func TestCatsService_CreateOrdinaryUpdate_InvalidDeviceID(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: true})
	_, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), uuid.New().String(), "not-a-uuid", []string{"seen"}, nil)
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
			if _, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String(), c.statuses, nil); !errors.Is(err, ErrInvalidStatuses) {
				t.Fatalf("expected ErrInvalidStatuses, got %v", err)
			}
		})
	}
}

func TestCatsService_CreateOrdinaryUpdate_InvalidCatID(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{})

	_, err := svc.CreateOrdinaryUpdate(context.Background(), "not-a-uuid", uuid.New().String(), uuid.New().String(), []string{"seen"}, nil)
	if !errors.Is(err, ErrInvalidCatID) {
		t.Fatalf("expected ErrInvalidCatID, got %v", err)
	}
}

func TestCatsService_CreateOrdinaryUpdate_UnknownCat(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: false})

	_, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String(), []string{"seen"}, nil)
	if !errors.Is(err, ErrCatNotFound) {
		t.Fatalf("expected ErrCatNotFound, got %v", err)
	}
}

func TestCatsService_CreateOrdinaryUpdate_RepositoryFailure(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: true, createErr: errors.New("connection refused")})

	_, err := svc.CreateOrdinaryUpdate(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String(), []string{"seen"}, nil)
	if err == nil {
		t.Fatal("expected an error, got nil")
	}
}

func TestCatsService_CreateNeedsHelpUpdate_Success(t *testing.T) {
	catID := uuid.New()
	userID := uuid.New()
	deviceID := uuid.New()
	returnedID := uuid.New()
	fixedNow := time.Date(2026, 3, 1, 10, 0, 0, 0, time.UTC)
	var captured repository.CreateNeedsHelpUpdateParams
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
	if captured.NeedsHelpCategory != "injured_or_sick" {
		t.Errorf("unexpected repository category: %q", captured.NeedsHelpCategory)
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

func TestCatsService_CorrectOwnUpdate_Success(t *testing.T) {
	catID := uuid.New()
	updateID := uuid.New()
	userID := uuid.New()
	createdAt := time.Date(2026, 1, 5, 8, 0, 0, 0, time.UTC)
	fixedNow := createdAt.Add(3 * time.Minute)

	var captured repository.CorrectOwnUpdateParams
	svc := NewCatsService(fakeCatsLister{
		correctRow: repository.CorrectOrdinaryUpdateRow{
			ID:        pgtype.UUID{Bytes: updateID, Valid: true},
			CreatedAt: pgtype.Timestamptz{Time: createdAt, Valid: true},
			UpdatedAt: pgtype.Timestamptz{Time: fixedNow, Valid: true},
		},
		capturedCorrect: &captured,
	}, WithClock(func() time.Time { return fixedNow }))

	comment := "düzeltildi"
	update, err := svc.CorrectOwnUpdate(context.Background(), catID.String(), updateID.String(), userID.String(), []string{"water_provided", "fed"}, &comment)
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
	_, err := svc.CorrectOwnUpdate(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String(), []string{"not_a_real_status"}, nil)
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

	_, err := svc.CorrectOwnUpdate(context.Background(), catID.String(), updateID.String(), stranger.String(), []string{"seen"}, nil)
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

	_, err := svc.CorrectOwnUpdate(context.Background(), catID.String(), updateID.String(), userID.String(), []string{"seen"}, nil)
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

	_, err := svc.CorrectOwnUpdate(context.Background(), catID.String(), updateID.String(), userID.String(), []string{"seen"}, nil)
	if !errors.Is(err, ErrUpdateNotFound) {
		t.Fatalf("expected ErrUpdateNotFound for a needs-help update, got %v", err)
	}
}

func TestCatsService_CorrectOwnUpdate_UnknownUpdateIsNotFound(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{
		correctErr:         pgx.ErrNoRows,
		correctionCheckErr: pgx.ErrNoRows,
	})

	_, err := svc.CorrectOwnUpdate(context.Background(), uuid.New().String(), uuid.New().String(), uuid.New().String(), []string{"seen"}, nil)
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
