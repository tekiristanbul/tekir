package service

import (
	"context"
	"errors"
	"math"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// ErrInvalidBounds means the requested viewport is malformed or out of range.
var ErrInvalidBounds = errors.New("invalid bounds")

// Bounds is the visible map viewport requested by the client, in WGS84 degrees.
type Bounds struct {
	MinLng float64
	MinLat float64
	MaxLng float64
	MaxLat float64
}

func (b Bounds) validate() error {
	// strconv.ParseFloat accepts "NaN"/"Inf" as valid float syntax, and NaN
	// fails every ordered comparison below (silently passing the range/order
	// checks), so both need rejecting explicitly before reaching postgis.
	for _, v := range [...]float64{b.MinLat, b.MaxLat, b.MinLng, b.MaxLng} {
		if math.IsNaN(v) || math.IsInf(v, 0) {
			return ErrInvalidBounds
		}
	}
	if b.MinLat < -90 || b.MaxLat > 90 || b.MinLng < -180 || b.MaxLng > 180 {
		return ErrInvalidBounds
	}
	// strict order only: an antimeridian-crossing viewport (min_lng > max_lng)
	// isn't a case this product needs to handle at istanbul's longitude.
	if b.MinLat >= b.MaxLat || b.MinLng >= b.MaxLng {
		return ErrInvalidBounds
	}
	return nil
}

// CatMarker is the minimal shape a map marker needs.
type CatMarker struct {
	ID           string
	PrimaryPhoto string
	Lat          float64
	Lng          float64
	NeedsHelp    bool
	LastUpdateAt *time.Time
}

// CatsLister is satisfied by repository.Store; kept as an interface here so
// CatsService stays testable without a real database connection.
type CatsLister interface {
	ListCatsInBounds(ctx context.Context, arg repository.ListCatsInBoundsParams) ([]repository.ListCatsInBoundsRow, error)
}

type CatsService struct {
	db CatsLister
}

func NewCatsService(db CatsLister) *CatsService {
	return &CatsService{db: db}
}

// ListNearby returns the active cats inside the requested viewport.
func (s *CatsService) ListNearby(ctx context.Context, bounds Bounds) ([]CatMarker, error) {
	if err := bounds.validate(); err != nil {
		return nil, err
	}

	rows, err := s.db.ListCatsInBounds(ctx, repository.ListCatsInBoundsParams{
		MinLng: bounds.MinLng,
		MinLat: bounds.MinLat,
		MaxLng: bounds.MaxLng,
		MaxLat: bounds.MaxLat,
	})
	if err != nil {
		return nil, err
	}

	markers := make([]CatMarker, 0, len(rows))
	for _, r := range rows {
		markers = append(markers, CatMarker{
			ID:           uuid.UUID(r.ID.Bytes).String(),
			PrimaryPhoto: r.PhotoUrl.String,
			Lat:          r.Lat,
			Lng:          r.Lng,
			NeedsHelp:    r.NeedsHelp.Bool,
			LastUpdateAt: timestamptzPtr(r.LastUpdateAt),
		})
	}
	return markers, nil
}

func timestamptzPtr(ts pgtype.Timestamptz) *time.Time {
	if !ts.Valid {
		return nil
	}
	t := ts.Time
	return &t
}
