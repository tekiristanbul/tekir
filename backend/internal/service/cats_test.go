package service

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

type fakeCatsLister struct {
	rows []repository.ListCatsInBoundsRow
	err  error
}

func (f fakeCatsLister) ListCatsInBounds(ctx context.Context, arg repository.ListCatsInBoundsParams) ([]repository.ListCatsInBoundsRow, error) {
	return f.rows, f.err
}

func TestCatsService_ListNearby(t *testing.T) {
	id := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	svc := NewCatsService(fakeCatsLister{rows: []repository.ListCatsInBoundsRow{
		{
			ID:        id,
			PhotoUrl:  pgtype.Text{String: "https://placecats.com/millie/300/200", Valid: true},
			Lng:       28.9744,
			Lat:       41.0256,
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
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if _, err := svc.ListNearby(context.Background(), c.bounds); !errors.Is(err, ErrInvalidBounds) {
				t.Fatalf("expected ErrInvalidBounds, got %v", err)
			}
		})
	}
}
