package service

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// ErrInvalidBounds means the requested viewport is malformed or out of range.
var ErrInvalidBounds = errors.New("invalid bounds")

// ErrInvalidCatID means the cat id path segment isn't a well-formed uuid.
var ErrInvalidCatID = errors.New("invalid cat id")

// ErrCatNotFound means no cat exists for a well-formed id.
var ErrCatNotFound = errors.New("cat not found")

// ErrInvalidCursor means the pagination cursor doesn't decode to a valid position.
var ErrInvalidCursor = errors.New("invalid cursor")

// ErrInvalidLimit means the requested page size is non-positive or exceeds maxUpdatesLimit.
var ErrInvalidLimit = errors.New("invalid limit")

const (
	defaultUpdatesLimit = 20
	maxUpdatesLimit     = 50
)

// needsHelpCategoryLabels is the fixed, closed mvp help-category vocabulary
// and its turkish display label (product-owner decision on issue #4) — a
// check constraint in the database, not a data-driven vocabulary like
// traits, so it's a plain map rather than a repository-backed lookup.
var needsHelpCategoryLabels = map[string]string{
	"injured_or_sick": "yaralı / hasta",
	"food_needed":     "mamaya ihtiyacı var",
	"water_needed":    "suya ihtiyacı var",
	"unsafe_location": "güvenli olmayan konum",
	"trapped":         "mahsur kalmış",
}

// NeedsHelpExpiry is the fixed mvp needs-help lifetime (product-owner
// decision on issue #4): exactly 72 hours, no early/manual resolve. Kept as
// a named constant (not a hardcoded literal at each call site) per
// docs/architecture/api.md's modeling note.
const NeedsHelpExpiry = 72 * time.Hour

// NeedsHelpExpiresAt computes the server-controlled expiry for a needs-help
// update created at createdAt. This must be the only place that expiry gets
// computed — a client-supplied expiry is never accepted (issue #4/#23) — so
// both seed data and, eventually, the write endpoint call this rather than
// each re-deriving createdAt+72h independently.
func NeedsHelpExpiresAt(createdAt time.Time) time.Time {
	return createdAt.Add(NeedsHelpExpiry)
}

// ActiveAlert is the minimum metadata a client needs to render an active
// needs-help alert (issue #4/#23): which category, and enough of the
// lifecycle (created_at/expires_at) to show context — never just a
// boolean. Present only while CreatedAt/ExpiresAt (as decided against the
// service's clock) mean the alert hasn't expired yet.
type ActiveAlert struct {
	Category      string
	CategoryLabel string
	CreatedAt     time.Time
	ExpiresAt     time.Time
}

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

// CatMarker is the minimal shape a map marker needs — plus Name and
// AreaLabel, the minimum extra fields the map's marker-preview sheet needs
// (issue #21 prototype-parity correction) so selecting a marker never has
// to fire a second full-detail fetch.
type CatMarker struct {
	ID           string
	Name         string
	PrimaryPhoto string
	Lat          float64
	Lng          float64
	AreaLabel    *string
	ActiveAlert  *ActiveAlert
	LastUpdateAt *time.Time
}

// CatDetail is the representation shown on the cat-detail view: identity,
// location, and the cat-profile fields that don't depend on issue #4
// (needs-help) or account/follow features that don't exist yet.
type CatDetail struct {
	ID           string
	Name         string
	Lat          float64
	Lng          float64
	AreaLabel    *string
	PrimaryPhoto *string
	Traits       []Trait
	CreatedAt    time.Time
	LastUpdateAt *time.Time
	ActiveAlert  *ActiveAlert
}

// CatUpdate is one entry in a cat's newest-first history: either an
// ordinary status update (issue #3 — one or more structured statuses plus
// an optional free-text comment) or a needs-help update (issue #4/#23 — a
// fixed category plus its own lifecycle). Kind discriminates the two; the
// NeedsHelp* fields are only set when Kind == "needs_help". NeedsHelpActive
// is decided against the service's injected clock, not the caller's own —
// per issue #23, activeness must be deterministic from server time.
type CatUpdate struct {
	ID        string
	Kind      string
	Statuses  []string
	Comment   *string
	CreatedAt time.Time

	NeedsHelpCategory      *string
	NeedsHelpCategoryLabel *string
	NeedsHelpExpiresAt     *time.Time
	NeedsHelpActive        *bool
}

// UpdatesPage is one newest-first page of a cat's update history.
// NextCursor is empty when there is no further page.
type UpdatesPage struct {
	Items      []CatUpdate
	NextCursor string
}

// updatesCursor is the decoded, opaque pagination position: the
// (created_at, seq) of the last item on the previous page.
type updatesCursor struct {
	createdAt time.Time
	seq       int64
}

// CatsLister is satisfied by repository.Store; kept as an interface here so
// CatsService stays testable without a real database connection.
type CatsLister interface {
	ListCatsInBounds(ctx context.Context, arg repository.ListCatsInBoundsParams) ([]repository.ListCatsInBoundsRow, error)
	GetCatByID(ctx context.Context, id pgtype.UUID) (repository.GetCatByIDRow, error)
	CatExists(ctx context.Context, id pgtype.UUID) (bool, error)
	ListCatUpdates(ctx context.Context, arg repository.ListCatUpdatesParams) ([]repository.ListCatUpdatesRow, error)
	ListCatTraits(ctx context.Context, catID pgtype.UUID) ([]repository.ListCatTraitsRow, error)
}

type CatsService struct {
	db    CatsLister
	clock func() time.Time
}

// CatsServiceOption configures optional CatsService behavior.
type CatsServiceOption func(*CatsService)

// WithClock overrides the clock used to decide whether a needs-help alert
// is still active (issue #23: "active" is always expires_at compared
// against the current time, never a separately stored flag). Production
// wiring doesn't need this — it defaults to time.Now — but it lets tests
// construct exact expiry-boundary scenarios deterministically, without any
// dependency on wall-clock timing.
func WithClock(clock func() time.Time) CatsServiceOption {
	return func(s *CatsService) { s.clock = clock }
}

func NewCatsService(db CatsLister, opts ...CatsServiceOption) *CatsService {
	s := &CatsService{db: db, clock: time.Now}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

// deriveActiveAlert turns a (possibly absent, possibly expired) latest
// needs-help update into the alert a client should render — nil whenever
// there is no needs-help update at all, or the one that exists has expired
// as of s.clock(). This is the one place "active" gets decided; the
// database and the client both stay out of that decision entirely.
func (s *CatsService) deriveActiveAlert(category pgtype.Text, createdAt, expiresAt pgtype.Timestamptz) *ActiveAlert {
	if !category.Valid || !expiresAt.Valid {
		return nil
	}
	if !expiresAt.Time.After(s.clock()) {
		return nil
	}
	return &ActiveAlert{
		Category:      category.String,
		CategoryLabel: needsHelpCategoryLabels[category.String],
		CreatedAt:     createdAt.Time,
		ExpiresAt:     expiresAt.Time,
	}
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
			Name:         r.Name.String,
			PrimaryPhoto: r.PhotoUrl.String,
			Lat:          r.Lat,
			Lng:          r.Lng,
			AreaLabel:    textPtr(r.AreaLabel),
			ActiveAlert:  s.deriveActiveAlert(r.NeedsHelpCategory, r.NeedsHelpCreatedAt, r.NeedsHelpExpiresAt),
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

func textPtr(t pgtype.Text) *string {
	if !t.Valid {
		return nil
	}
	s := t.String
	return &s
}

// parseCatID rejects a malformed uuid before it ever reaches the database.
func parseCatID(id string) (pgtype.UUID, error) {
	parsed, err := uuid.Parse(id)
	if err != nil {
		return pgtype.UUID{}, ErrInvalidCatID
	}
	return pgtype.UUID{Bytes: parsed, Valid: true}, nil
}

// GetCatDetail returns the cat-detail representation for id, or ErrCatNotFound
// if no cat exists with that id.
func (s *CatsService) GetCatDetail(ctx context.Context, id string) (CatDetail, error) {
	catID, err := parseCatID(id)
	if err != nil {
		return CatDetail{}, err
	}

	row, err := s.db.GetCatByID(ctx, catID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return CatDetail{}, ErrCatNotFound
		}
		return CatDetail{}, err
	}

	traitRows, err := s.db.ListCatTraits(ctx, catID)
	if err != nil {
		return CatDetail{}, err
	}
	traits := make([]Trait, 0, len(traitRows))
	for _, t := range traitRows {
		traits = append(traits, Trait{Key: t.Key, Label: t.DisplayName})
	}

	return CatDetail{
		ID:           uuid.UUID(row.ID.Bytes).String(),
		Name:         row.Name.String,
		Lat:          row.Lat,
		Lng:          row.Lng,
		AreaLabel:    textPtr(row.AreaLabel),
		PrimaryPhoto: textPtr(row.PhotoUrl),
		Traits:       traits,
		CreatedAt:    row.CreatedAt.Time,
		LastUpdateAt: timestamptzPtr(row.LastUpdateAt),
		ActiveAlert:  s.deriveActiveAlert(row.NeedsHelpCategory, row.NeedsHelpCreatedAt, row.NeedsHelpExpiresAt),
	}, nil
}

// ListCatUpdates returns one newest-first page of id's update history.
// cursor is the opaque token from a previous page's NextCursor, or "" for
// the first page. limit <= 0 falls back to defaultUpdatesLimit; anything
// outside (0, maxUpdatesLimit] is rejected rather than silently clamped, so
// a caller relying on a specific page size finds out instead of getting a
// different one back.
func (s *CatsService) ListCatUpdates(ctx context.Context, id, cursor string, limit int) (UpdatesPage, error) {
	catID, err := parseCatID(id)
	if err != nil {
		return UpdatesPage{}, err
	}

	if limit == 0 {
		limit = defaultUpdatesLimit
	}
	if limit < 0 || limit > maxUpdatesLimit {
		return UpdatesPage{}, ErrInvalidLimit
	}

	decoded, err := decodeUpdatesCursor(cursor)
	if err != nil {
		return UpdatesPage{}, err
	}

	exists, err := s.db.CatExists(ctx, catID)
	if err != nil {
		return UpdatesPage{}, err
	}
	if !exists {
		return UpdatesPage{}, ErrCatNotFound
	}

	params := repository.ListCatUpdatesParams{
		CatID: catID,
		// fetch one extra row to detect a next page without a separate count query.
		RowLimit: int32(limit + 1),
	}
	if decoded != nil {
		params.BeforeCreatedAt = pgtype.Timestamptz{Time: decoded.createdAt, Valid: true}
		params.BeforeSeq = pgtype.Int8{Int64: decoded.seq, Valid: true}
	}

	rows, err := s.db.ListCatUpdates(ctx, params)
	if err != nil {
		return UpdatesPage{}, err
	}

	hasMore := len(rows) > limit
	if hasMore {
		rows = rows[:limit]
	}

	items := make([]CatUpdate, 0, len(rows))
	for _, r := range rows {
		item := CatUpdate{
			ID:        uuid.UUID(r.ID.Bytes).String(),
			Kind:      r.Kind,
			Statuses:  r.Statuses,
			Comment:   textPtr(r.Comment),
			CreatedAt: r.CreatedAt.Time,
		}
		if r.Kind == "needs_help" {
			category := r.NeedsHelpCategory.String
			label := needsHelpCategoryLabels[category]
			expiresAt := r.NeedsHelpExpiresAt.Time
			active := expiresAt.After(s.clock())
			item.NeedsHelpCategory = &category
			item.NeedsHelpCategoryLabel = &label
			item.NeedsHelpExpiresAt = &expiresAt
			item.NeedsHelpActive = &active
		}
		items = append(items, item)
	}

	page := UpdatesPage{Items: items}
	if hasMore {
		last := rows[len(rows)-1]
		page.NextCursor = encodeUpdatesCursor(updatesCursor{createdAt: last.CreatedAt.Time, seq: last.Seq.Int64})
	}
	return page, nil
}

// encodeUpdatesCursor and decodeUpdatesCursor keep the (created_at, seq)
// keyset position opaque to clients — it's a pagination implementation
// detail, not part of the api contract.
func encodeUpdatesCursor(c updatesCursor) string {
	raw := fmt.Sprintf("%d:%d", c.createdAt.UnixNano(), c.seq)
	return base64.RawURLEncoding.EncodeToString([]byte(raw))
}

func decodeUpdatesCursor(raw string) (*updatesCursor, error) {
	if raw == "" {
		return nil, nil
	}
	decoded, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return nil, ErrInvalidCursor
	}
	nanosPart, seqPart, ok := strings.Cut(string(decoded), ":")
	if !ok {
		return nil, ErrInvalidCursor
	}
	nanos, err := strconv.ParseInt(nanosPart, 10, 64)
	if err != nil {
		return nil, ErrInvalidCursor
	}
	seq, err := strconv.ParseInt(seqPart, 10, 64)
	if err != nil {
		return nil, ErrInvalidCursor
	}
	return &updatesCursor{createdAt: time.Unix(0, nanos).UTC(), seq: seq}, nil
}
