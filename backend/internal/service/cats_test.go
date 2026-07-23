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

	traitRows []repository.ListCatTraitsRow
	traitsErr error
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

func (f fakeCatsLister) ListCatTraits(ctx context.Context, catID pgtype.UUID) ([]repository.ListCatTraitsRow, error) {
	return f.traitRows, f.traitsErr
}

func TestCatsService_ListNearby(t *testing.T) {
	id := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	svc := NewCatsService(fakeCatsLister{rows: []repository.ListCatsInBoundsRow{
		{
			ID:        id,
			Name:      pgtype.Text{String: "tekir", Valid: true},
			PhotoUrl:  pgtype.Text{String: "https://placecats.com/millie/300/200", Valid: true},
			Lng:       28.9744,
			Lat:       41.0256,
			AreaLabel: pgtype.Text{String: "Galata Kulesi çevresi, Beyoğlu", Valid: true},
			NeedsHelp: pgtype.Bool{Bool: true, Valid: true},
		},
	}})

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
	if !m.NeedsHelp {
		t.Error("expected needs_help to be true")
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
			PhotoUrl:  pgtype.Text{String: "https://placecats.com/millie/300/200", Valid: true},
			CreatedAt: pgtype.Timestamptz{Time: created, Valid: true},
		},
		traitRows: []repository.ListCatTraitsRow{
			{Key: "friendly", DisplayName: "Friendly"},
			{Key: "playful", DisplayName: "Playful"},
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
	if len(detail.Traits) != 2 || detail.Traits[0].Key != "friendly" || detail.Traits[0].Label != "Friendly" {
		t.Errorf("expected [friendly/Friendly playful/Playful], got %v", detail.Traits)
	}
	if !detail.CreatedAt.Equal(created) {
		t.Errorf("expected created_at %v, got %v", created, detail.CreatedAt)
	}
	if detail.LastUpdateAt != nil {
		t.Errorf("expected nil last_update_at, got %v", detail.LastUpdateAt)
	}
}

func TestCatsService_GetCatDetail_TraitsRepositoryFailure(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{
		catRow:    repository.GetCatByIDRow{ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}},
		traitsErr: errors.New("connection refused"),
	})

	_, err := svc.GetCatDetail(context.Background(), uuid.New().String())
	if err == nil {
		t.Fatal("expected an error, got nil")
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

	_, err := svc.ListCatUpdates(context.Background(), uuid.New().String(), "", 0)
	if !errors.Is(err, ErrCatNotFound) {
		t.Fatalf("expected ErrCatNotFound, got %v", err)
	}
}

func TestCatsService_ListCatUpdates_EmptyHistory(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: true})

	page, err := svc.ListCatUpdates(context.Background(), uuid.New().String(), "", 0)
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

	page, err := svc.ListCatUpdates(context.Background(), uuid.New().String(), "", 2)
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
		if _, err := svc.ListCatUpdates(context.Background(), uuid.New().String(), "", limit); !errors.Is(err, ErrInvalidLimit) {
			t.Errorf("limit %d: expected ErrInvalidLimit, got %v", limit, err)
		}
	}
}

func TestCatsService_ListCatUpdates_InvalidCursor(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{exists: true})

	if _, err := svc.ListCatUpdates(context.Background(), uuid.New().String(), "not-base64!!", 0); !errors.Is(err, ErrInvalidCursor) {
		t.Fatalf("expected ErrInvalidCursor, got %v", err)
	}
}

func TestCatsService_ListCatUpdates_InvalidCatID(t *testing.T) {
	svc := NewCatsService(fakeCatsLister{})

	if _, err := svc.ListCatUpdates(context.Background(), "not-a-uuid", "", 0); !errors.Is(err, ErrInvalidCatID) {
		t.Fatalf("expected ErrInvalidCatID, got %v", err)
	}
}
