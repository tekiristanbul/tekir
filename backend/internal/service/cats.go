package service

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"sort"
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

// ErrInvalidStatuses means the submitted status set is empty, contains a
// value outside the closed mvp vocabulary, or repeats a value — issue #36
// requires all three to reject with the same 400, so one sentinel is
// enough; the handler doesn't need to distinguish which rule failed.
var ErrInvalidStatuses = errors.New("invalid statuses")

// ErrInvalidNeedsHelpCategory means the submitted category falls outside
// needsHelpCategoryLabels' fixed 5-value mvp vocabulary (issue #78) — the
// same closed-vocabulary rejection ErrInvalidStatuses gives ordinary
// updates, enforced here too even though updates_kind_fields_ck would also
// reject an unrecognized value at the database level: failing before any
// write starts means an invalid category never allocates an id or opens a
// transaction.
var ErrInvalidNeedsHelpCategory = errors.New("invalid needs-help category")

// ErrInvalidArea means the submitted location falls outside the product's
// geographic boundary (istanbulBounds below) or isn't well-formed
// (nan/inf/out-of-range lat/lng).
var ErrInvalidArea = errors.New("invalid area")

// ErrMissingPhoto means POST /v1/cats was submitted without the required
// initial photo (docs/product/cats.md: "the minimum information to add a
// cat is a photo and a location").
var ErrMissingPhoto = errors.New("missing photo")

// ErrMediaPipelineNotConfigured means Create was called on a CatsService
// built without WithCatsMediaPipeline — a wiring mistake (cmd/api/main.go
// always supplies one), not a client input problem. Create is a public
// method, so this fails with a clear error rather than a nil-pointer panic
// on first use.
var ErrMediaPipelineNotConfigured = errors.New("cats service media pipeline not configured")

// ErrUpdateNotFound means no update exists for the given (cat_id, update_id)
// pair, or the update exists but is kind = 'needs_help' — issue #80's
// correction/delete endpoints don't recognize a needs-help report as a
// correctable resource at all (it has its own fixed 72h lifecycle), so it
// is treated identically to "doesn't exist" rather than inventing a new
// status code for that scope exclusion.
var ErrUpdateNotFound = errors.New("update not found")

// ErrNotUpdateAuthor means the update exists under this cat but the caller
// isn't its author (issue #80). Not collapsed into ErrUpdateNotFound: the
// full update history is already public (docs/product/privacy.md), so
// confirming "this exists, but isn't yours" leaks nothing a guest couldn't
// already see on the public timeline.
var ErrNotUpdateAuthor = errors.New("not the update author")

// ErrCorrectionWindowExpired means the caller is the update's author but
// the fixed 10-minute correction window (docs/product/updates.md) has
// closed — mirrors the otp/verify 410 convention (docs/architecture/api.md).
var ErrCorrectionWindowExpired = errors.New("correction window expired")

// updateCorrectionWindow is the fixed mvp grace period during which an
// ordinary update's author may correct or delete it (docs/product/updates.md,
// issue #80) — never configurable per-request or per-account.
const updateCorrectionWindow = 10 * time.Minute

const (
	defaultUpdatesLimit = 20
	maxUpdatesLimit     = 50

	// duplicateCheckRadiusMeters matches docs/architecture/api.md's
	// GET /v1/cats/nearby?radius=50 sketch — the same radius backs both the
	// standalone duplicate-candidate endpoint and POST /v1/cats' own
	// server-side duplicate check (see Create).
	duplicateCheckRadiusMeters = 50
)

// istanbulBounds is the product's one existing geographic-boundary
// definition — app/lib/core/geo/istanbul_bounds.dart's istanbulBounds,
// shared by the main map screen and the add-cat location picker, which
// already keeps the map camera from panning out to a city/country
// view. docs/architecture/api.md and db.md don't define their own boundary
// constant, and issue #70 requires enforcing "the current Istanbul/product
// boundary if defined by the current docs... do not invent a broader
// geography rule" — reusing these exact numbers, rather than picking new
// ones, is what that requires.
var istanbulBounds = struct{ MinLat, MaxLat, MinLng, MaxLng float64 }{
	MinLat: 40.80, MaxLat: 41.40, MinLng: 28.35, MaxLng: 29.55,
}

func withinIstanbul(lat, lng float64) bool {
	if math.IsNaN(lat) || math.IsNaN(lng) || math.IsInf(lat, 0) || math.IsInf(lng, 0) {
		return false
	}
	return lat >= istanbulBounds.MinLat && lat <= istanbulBounds.MaxLat &&
		lng >= istanbulBounds.MinLng && lng <= istanbulBounds.MaxLng
}

// approvedStatuses is the closed mvp status vocabulary (issue #3/#36,
// docs/product/updates.md): the only values an ordinary update's
// update_statuses rows may carry. Also enforced by the database's own check
// constraint on update_statuses.status — this copy lets the service reject
// an invalid submission with a 400 before ever reaching the database.
var approvedStatuses = map[string]bool{
	"seen":           true,
	"fed":            true,
	"water_provided": true,
}

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

// DuplicateCandidate is one nearby existing cat the add-cat flow shows
// before final submission (issue #70, docs/product/cats.md/trust.md —
// advisory only, never blocks creation on its own).
type DuplicateCandidate struct {
	ID           string
	Name         string
	PrimaryPhoto string
}

// DuplicateCandidatesError carries the nearby candidates Create found when
// the caller hasn't yet confirmed the cat is different (confirmedNew
// false) — the handler answers 409 with this list instead of creating a
// cat, per docs/architecture/api.md. Candidates are advisory: a second call
// with confirmedNew true always proceeds regardless of what this contains.
type DuplicateCandidatesError struct {
	Candidates []DuplicateCandidate
}

func (e *DuplicateCandidatesError) Error() string {
	return "nearby duplicate candidates exist"
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
	UpdatedAt *time.Time

	NeedsHelpCategory      *string
	NeedsHelpCategoryLabel *string
	NeedsHelpExpiresAt     *time.Time
	NeedsHelpActive        *bool

	// AuthorIsMe (issue #80) is true only when ListCatUpdates was called
	// with the caller's own authenticated user id and it matches this
	// entry's author — always false for a guest read (no caller id at
	// all). Server-derived so a client never has to compare ids itself.
	AuthorIsMe bool
	// CorrectionExpiresAt is non-nil only when AuthorIsMe && Kind ==
	// "ordinary" — created_at + the fixed 10-minute correction window
	// (docs/product/updates.md). A client uses this only to decide
	// whether to show the correction affordance/countdown; the server
	// remains the sole authority on whether a correction attempt actually
	// succeeds (see CorrectOwnUpdate/DeleteOwnUpdate below).
	CorrectionExpiresAt *time.Time
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

// CatsStore is satisfied by repository.Store; kept as an interface here so
// CatsService stays testable without a real database connection.
type CatsStore interface {
	ListCatsInBounds(ctx context.Context, arg repository.ListCatsInBoundsParams) ([]repository.ListCatsInBoundsRow, error)
	GetCatByID(ctx context.Context, id pgtype.UUID) (repository.GetCatByIDRow, error)
	CatExists(ctx context.Context, id pgtype.UUID) (bool, error)
	ListCatUpdates(ctx context.Context, arg repository.ListCatUpdatesParams) ([]repository.ListCatUpdatesRow, error)
	CreateOrdinaryUpdate(ctx context.Context, arg repository.CreateOrdinaryUpdateParams) (repository.CreateUpdateRow, error)
	CreateNeedsHelpUpdate(ctx context.Context, arg repository.CreateNeedsHelpUpdateParams) (repository.CreateUpdateRow, error)
	CorrectOwnUpdate(ctx context.Context, arg repository.CorrectOwnUpdateParams) (repository.CorrectOrdinaryUpdateRow, error)
	DeleteOwnUpdate(ctx context.Context, arg repository.DeleteOwnUpdateParams) (repository.DeleteOwnUpdateRow, error)
	GetUpdateForCorrectionCheck(ctx context.Context, arg repository.GetUpdateForCorrectionCheckParams) (repository.GetUpdateForCorrectionCheckRow, error)
	GetCatByIdempotencyKey(ctx context.Context, arg repository.GetCatByIdempotencyKeyParams) (repository.GetCatByIdempotencyKeyRow, error)
	ListNearbyCatsForDuplicateCheck(ctx context.Context, arg repository.ListNearbyCatsForDuplicateCheckParams) ([]repository.ListNearbyCatsForDuplicateCheckRow, error)
	CreateCatWithMedia(ctx context.Context, arg repository.CreateCatWithMediaParams) (repository.CreateCatWithMediaRow, error)
}

type CatsService struct {
	db       CatsStore
	clock    func() time.Time
	pipeline *mediaPipeline
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

// WithCatsMediaPipeline wires the validation+storage pipeline Create uses
// for a new cat's required photo (issue #70) — the same pipeline shape
// MediaService uses for standalone POST /v1/media, sharing store and
// maxBytes so both endpoints enforce identical media rules. Only Create
// needs this; every other CatsService method works without it, so tests
// exercising just those don't need to supply one.
func WithCatsMediaPipeline(store ObjectStore, maxBytes int) CatsServiceOption {
	return func(s *CatsService) { s.pipeline = newMediaPipeline(store, maxBytes) }
}

func NewCatsService(db CatsStore, opts ...CatsServiceOption) *CatsService {
	s := &CatsService{db: db, clock: time.Now}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

// deriveActiveAlert turns a (possibly absent, possibly expired) latest
// needs-help update into the alert a client should render — nil whenever
// there is no needs-help update at all, or the one that exists has expired
// as of clock(). This is the one place "active" gets decided; the database
// and the client both stay out of that decision entirely. Package-level
// (not a CatsService method) so FollowsService's own ListFollows — which
// needs the identical map/detail cat-summary shape, per issue #44 — derives
// active-vs-expired the same way, against its own injected clock, without
// duplicating this logic.
func deriveActiveAlert(clock func() time.Time, category pgtype.Text, createdAt, expiresAt pgtype.Timestamptz) *ActiveAlert {
	if !category.Valid || !expiresAt.Valid {
		return nil
	}
	if !expiresAt.Time.After(clock()) {
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
			PrimaryPhoto: r.PhotoUrl,
			Lat:          r.Lat,
			Lng:          r.Lng,
			AreaLabel:    textPtr(r.AreaLabel),
			ActiveAlert:  deriveActiveAlert(s.clock, r.NeedsHelpCategory, r.NeedsHelpCreatedAt, r.NeedsHelpExpiresAt),
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

// nonEmptyStringPtr turns coalesce(cats.photo_url, media.url)'s plain
// string result (sqlc infers coalesce as non-nullable — see ListCatsInBounds/
// GetCatByID's query comments) back into the *string GetCatDetail's
// nullable "primary_photo|null" api field expects. Every real cat has a
// primary photo (seed data sets photo_url; POST /v1/cats requires one), so
// an empty string here would only mean pre-#70 seed data missed it —
// treated the same as null rather than surfaced as a literal empty photo url.
func nonEmptyStringPtr(s string) *string {
	if s == "" {
		return nil
	}
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

// optionalUUID parses id as a device identity that may be absent (issue
// #65: X-Device-Token is optional on the follow and ordinary-update write
// paths, since authorization now comes from the bearer session, not the
// device). An empty string yields the zero, invalid pgtype.UUID — recorded
// as sql null — rather than an error; a non-empty, malformed value is still
// rejected.
func optionalUUID(id string) (pgtype.UUID, error) {
	if id == "" {
		return pgtype.UUID{}, nil
	}
	parsed, err := uuid.Parse(id)
	if err != nil {
		return pgtype.UUID{}, err
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

	return CatDetail{
		ID:           uuid.UUID(row.ID.Bytes).String(),
		Name:         row.Name.String,
		Lat:          row.Lat,
		Lng:          row.Lng,
		AreaLabel:    textPtr(row.AreaLabel),
		PrimaryPhoto: nonEmptyStringPtr(row.PhotoUrl),
		CreatedAt:    row.CreatedAt.Time,
		LastUpdateAt: timestamptzPtr(row.LastUpdateAt),
		ActiveAlert:  deriveActiveAlert(s.clock, row.NeedsHelpCategory, row.NeedsHelpCreatedAt, row.NeedsHelpExpiresAt),
	}, nil
}

// ListCatUpdates returns one newest-first page of id's update history.
// cursor is the opaque token from a previous page's NextCursor, or "" for
// the first page. limit <= 0 falls back to defaultUpdatesLimit; anything
// outside (0, maxUpdatesLimit] is rejected rather than silently clamped, so
// a caller relying on a specific page size finds out instead of getting a
// different one back. callerUserID (issue #80) is the optional bearer
// caller's own account id — "" for a guest read or an absent/invalid
// bearer (GET /v1/cats/{cat_id}/updates uses OptionalBearer, never
// RequireBearer, so this endpoint stays guest-readable) — used only to
// derive AuthorIsMe/CorrectionExpiresAt per item, never to filter which
// updates are returned.
func (s *CatsService) ListCatUpdates(ctx context.Context, id, cursor string, limit int, callerUserID string) (UpdatesPage, error) {
	catID, err := parseCatID(id)
	if err != nil {
		return UpdatesPage{}, err
	}

	// a malformed callerUserID (shouldn't happen — RequireBearer/
	// OptionalBearer only ever place a well-formed uuid or nothing at all
	// in context) simply never matches any author, rather than erroring
	// a guest-readable endpoint over a caller-side identity concern.
	var callerUUID uuid.UUID
	var haveCaller bool
	if callerUserID != "" {
		if parsed, err := uuid.Parse(callerUserID); err == nil {
			callerUUID = parsed
			haveCaller = true
		}
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
		if haveCaller && r.AuthorUserID.Valid && uuid.UUID(r.AuthorUserID.Bytes) == callerUUID {
			item.AuthorIsMe = true
			if r.Kind == "ordinary" {
				expiresAt := r.CreatedAt.Time.Add(updateCorrectionWindow)
				item.CorrectionExpiresAt = &expiresAt
			}
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

// CreateOrdinaryUpdate records a new ordinary status update for cat id,
// attributed to the authenticated account identified by userID (issue #65
// — a valid bearer session is required; an optional X-Device-Token is
// recorded alongside it purely for installation/abuse-control association,
// never as authorization). statuses must be a non-empty set drawn from the
// closed mvp vocabulary with no duplicates; comment is optional and never
// sufficient on its own. kind, media, needs-help fields, timestamps,
// sequence, and author identity are never accepted from the caller — kind
// is always "ordinary" here, created_at/author_user_id/author_device_id
// are server-derived, and the update row, its statuses, and the cat's
// last_update_at commit as one transaction (see
// repository.Store.CreateOrdinaryUpdate).
func (s *CatsService) CreateOrdinaryUpdate(ctx context.Context, id, userID, deviceID string, statuses []string, comment *string) (CatUpdate, error) {
	catID, err := parseCatID(id)
	if err != nil {
		return CatUpdate{}, err
	}

	if err := validateStatuses(statuses); err != nil {
		return CatUpdate{}, err
	}

	// userID comes from the authenticated bearer context the
	// RequireBearer middleware places on the request — it is always a
	// well-formed uuid the middleware itself resolved, never
	// client-supplied input to re-validate against a sentinel error here.
	// deviceID (from the optional device-token context) may be "".
	authorUserID, err := uuid.Parse(userID)
	if err != nil {
		return CatUpdate{}, err
	}
	authorDeviceID, err := optionalUUID(deviceID)
	if err != nil {
		return CatUpdate{}, err
	}

	exists, err := s.db.CatExists(ctx, catID)
	if err != nil {
		return CatUpdate{}, err
	}
	if !exists {
		return CatUpdate{}, ErrCatNotFound
	}

	sorted := append([]string(nil), statuses...)
	sort.Strings(sorted)

	createdAt := s.clock()
	row, err := s.db.CreateOrdinaryUpdate(ctx, repository.CreateOrdinaryUpdateParams{
		ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
		CatID:          catID,
		AuthorDeviceID: authorDeviceID,
		AuthorUserID:   pgtype.UUID{Bytes: authorUserID, Valid: true},
		Comment:        nullableText(comment),
		CreatedAt:      pgtype.Timestamptz{Time: createdAt, Valid: true},
		Statuses:       sorted,
	})
	if err != nil {
		return CatUpdate{}, err
	}

	return CatUpdate{
		ID:        uuid.UUID(row.ID.Bytes).String(),
		Kind:      "ordinary",
		Statuses:  sorted,
		Comment:   comment,
		CreatedAt: createdAt,
	}, nil
}

// CreateNeedsHelpUpdate records a new needs-help report for cat id,
// attributed to the authenticated account identified by userID — the same
// bearer-required, optional-device-association shape as
// CreateOrdinaryUpdate (issue #78 reuses #65's authorization model
// unchanged). category must be one of needsHelpCategoryLabels' fixed 5
// values; comment is optional. expires_at is always computed here as
// createdAt + NeedsHelpExpiry (issue #4's fixed 72h, no early/manual
// resolve) — never accepted from the caller. The update row and its
// notification_outbox enqueue commit as one transaction (see
// repository.Store.CreateNeedsHelpUpdate); which followers, if any, that
// outbox row eventually notifies is NotificationService.DispatchPending's
// decision, not this method's.
func (s *CatsService) CreateNeedsHelpUpdate(ctx context.Context, id, userID, deviceID, category string, comment *string) (CatUpdate, error) {
	catID, err := parseCatID(id)
	if err != nil {
		return CatUpdate{}, err
	}

	if _, ok := needsHelpCategoryLabels[category]; !ok {
		return CatUpdate{}, ErrInvalidNeedsHelpCategory
	}

	// userID comes from the authenticated bearer context RequireBearer
	// placed on the request — always a well-formed uuid, never
	// client-supplied input to re-validate against a sentinel error here.
	authorUserID, err := uuid.Parse(userID)
	if err != nil {
		return CatUpdate{}, err
	}
	authorDeviceID, err := optionalUUID(deviceID)
	if err != nil {
		return CatUpdate{}, err
	}

	exists, err := s.db.CatExists(ctx, catID)
	if err != nil {
		return CatUpdate{}, err
	}
	if !exists {
		return CatUpdate{}, ErrCatNotFound
	}

	createdAt := s.clock()
	expiresAt := NeedsHelpExpiresAt(createdAt)
	row, err := s.db.CreateNeedsHelpUpdate(ctx, repository.CreateNeedsHelpUpdateParams{
		ID:                 pgtype.UUID{Bytes: uuid.New(), Valid: true},
		CatID:              catID,
		AuthorDeviceID:     authorDeviceID,
		AuthorUserID:       pgtype.UUID{Bytes: authorUserID, Valid: true},
		Comment:            nullableText(comment),
		CreatedAt:          pgtype.Timestamptz{Time: createdAt, Valid: true},
		NeedsHelpCategory:  category,
		NeedsHelpExpiresAt: pgtype.Timestamptz{Time: expiresAt, Valid: true},
	})
	if err != nil {
		return CatUpdate{}, err
	}

	label := needsHelpCategoryLabels[category]
	active := true
	return CatUpdate{
		ID:   uuid.UUID(row.ID.Bytes).String(),
		Kind: "needs_help",
		// always []string{}, never nil: ListCatUpdates' row.Statuses is a sql
		// coalesce(..., '{}') and so is never null over the wire either — a
		// needs-help update has no statuses of its own, but the response
		// shape (and Flutter's CatUpdateEntry.fromJson, which casts statuses
		// as a non-nullable List) must stay identical to that read path's.
		Statuses:               []string{},
		Comment:                comment,
		CreatedAt:              createdAt,
		NeedsHelpCategory:      &category,
		NeedsHelpCategoryLabel: &label,
		NeedsHelpExpiresAt:     &expiresAt,
		NeedsHelpActive:        &active,
	}, nil
}

// parseUpdateID mirrors parseCatID's shape for the update_id path segment
// (issue #80's correction endpoints).
func parseUpdateID(raw string) (pgtype.UUID, error) {
	id, err := uuid.Parse(raw)
	if err != nil {
		return pgtype.UUID{}, ErrUpdateNotFound
	}
	return pgtype.UUID{Bytes: id, Valid: true}, nil
}

// resolveCorrectionFailure runs only after CorrectOrdinaryUpdate/
// DeleteOwnUpdate affected zero rows, to turn that single ambiguous
// outcome into the right sentinel error — or, for an already-deleted row,
// into a signal the caller (handler) should treat as an idempotent
// success rather than an error at all (mirroring this repo's existing
// idempotent-retry convention for POST /v1/auth/logout and
// POST /v1/me/notifications/{id}/read). alreadyDeleted is true exactly
// when the caller should treat the zero-rows outcome as success.
func (s *CatsService) resolveCorrectionFailure(ctx context.Context, catID, updateID pgtype.UUID, authorUserID uuid.UUID, windowStart time.Time) (alreadyDeleted bool, err error) {
	check, err := s.db.GetUpdateForCorrectionCheck(ctx, repository.GetUpdateForCorrectionCheckParams{ID: updateID, CatID: catID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, ErrUpdateNotFound
		}
		return false, err
	}
	if check.Kind != "ordinary" {
		return false, ErrUpdateNotFound
	}
	if !check.AuthorUserID.Valid || uuid.UUID(check.AuthorUserID.Bytes) != authorUserID {
		return false, ErrNotUpdateAuthor
	}
	if check.DeletedAt.Valid {
		return true, nil
	}
	if !check.CreatedAt.Time.After(windowStart) {
		return false, ErrCorrectionWindowExpired
	}
	// every condition the conditional update itself checks held true here,
	// yet it still affected zero rows — shouldn't happen outside a genuine
	// race (e.g. concurrently deleted between the two statements); surface
	// as "not found" rather than panicking on an assumption that can't hold.
	return false, ErrUpdateNotFound
}

// CorrectOwnUpdate applies an in-window correction to the caller's own
// ordinary update (issue #80): statuses and/or comment. kind, author
// identity, and created_at are never alterable through this path — only
// comment/statuses change, and updated_at is server-derived exactly like
// CreateOrdinaryUpdate's created_at. windowStart is computed against s.clock,
// never the caller's own notion of time, matching every other time-relative
// decision in this service.
func (s *CatsService) CorrectOwnUpdate(ctx context.Context, catID, updateID, userID string, statuses []string, comment *string) (CatUpdate, error) {
	catUUID, err := parseCatID(catID)
	if err != nil {
		return CatUpdate{}, err
	}
	updateUUID, err := parseUpdateID(updateID)
	if err != nil {
		return CatUpdate{}, err
	}
	if err := validateStatuses(statuses); err != nil {
		return CatUpdate{}, err
	}
	// userID is always a well-formed uuid from RequireBearer's context —
	// never client-supplied input to re-validate against a sentinel error.
	authorUserID, err := uuid.Parse(userID)
	if err != nil {
		return CatUpdate{}, err
	}

	now := s.clock()
	windowStart := now.Add(-updateCorrectionWindow)
	sorted := append([]string(nil), statuses...)
	sort.Strings(sorted)

	row, err := s.db.CorrectOwnUpdate(ctx, repository.CorrectOwnUpdateParams{
		ID:           updateUUID,
		CatID:        catUUID,
		AuthorUserID: pgtype.UUID{Bytes: authorUserID, Valid: true},
		Comment:      nullableText(comment),
		UpdatedAt:    pgtype.Timestamptz{Time: now, Valid: true},
		WindowStart:  pgtype.Timestamptz{Time: windowStart, Valid: true},
		Statuses:     sorted,
	})
	if err != nil {
		if !errors.Is(err, pgx.ErrNoRows) {
			return CatUpdate{}, err
		}
		if _, resolveErr := s.resolveCorrectionFailure(ctx, catUUID, updateUUID, authorUserID, windowStart); resolveErr != nil {
			return CatUpdate{}, resolveErr
		}
		// an already-deleted row: a correction (unlike delete) has nothing
		// idempotent to return, since there's no longer a live update to
		// describe — this shouldn't be reachable from a client following
		// CorrectionExpiresAt (a deleted update is never listed with one),
		// but treat it the same as any other now-uncorrectable state.
		return CatUpdate{}, ErrUpdateNotFound
	}

	updatedAt := row.UpdatedAt.Time
	createdAt := row.CreatedAt.Time
	expiresAt := createdAt.Add(updateCorrectionWindow)
	return CatUpdate{
		ID:                  uuid.UUID(row.ID.Bytes).String(),
		Kind:                "ordinary",
		Statuses:            sorted,
		Comment:             comment,
		CreatedAt:           createdAt,
		UpdatedAt:           &updatedAt,
		AuthorIsMe:          true,
		CorrectionExpiresAt: &expiresAt,
	}, nil
}

// DeleteOwnUpdate soft-deletes the caller's own ordinary update within the
// correction window (issue #80). A retry against an already-deleted row
// succeeds as a no-op (nil error) rather than erroring, mirroring this
// repo's existing idempotent-delete convention (POST /v1/auth/logout,
// POST /v1/me/notifications/{id}/read).
func (s *CatsService) DeleteOwnUpdate(ctx context.Context, catID, updateID, userID string) error {
	catUUID, err := parseCatID(catID)
	if err != nil {
		return err
	}
	updateUUID, err := parseUpdateID(updateID)
	if err != nil {
		return err
	}
	authorUserID, err := uuid.Parse(userID)
	if err != nil {
		return err
	}

	now := s.clock()
	windowStart := now.Add(-updateCorrectionWindow)
	_, err = s.db.DeleteOwnUpdate(ctx, repository.DeleteOwnUpdateParams{
		ID:           updateUUID,
		CatID:        catUUID,
		AuthorUserID: pgtype.UUID{Bytes: authorUserID, Valid: true},
		DeletedAt:    pgtype.Timestamptz{Time: now, Valid: true},
		WindowStart:  pgtype.Timestamptz{Time: windowStart, Valid: true},
	})
	if err == nil {
		return nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	alreadyDeleted, resolveErr := s.resolveCorrectionFailure(ctx, catUUID, updateUUID, authorUserID, windowStart)
	if alreadyDeleted {
		return nil
	}
	return resolveErr
}

// ListNearbyDuplicates answers GET /v1/cats/nearby: the active cats within
// duplicateCheckRadiusMeters of (lat, lng), nearest first — the add-cat
// flow's standalone, non-blocking duplicate-candidate check
// (docs/architecture/api.md). Public: this is advisory information a guest
// browsing the add-cat flow up to the auth gate can see the same as anyone.
func (s *CatsService) ListNearbyDuplicates(ctx context.Context, lat, lng float64) ([]DuplicateCandidate, error) {
	if !withinIstanbul(lat, lng) {
		return nil, ErrInvalidArea
	}
	rows, err := s.db.ListNearbyCatsForDuplicateCheck(ctx, repository.ListNearbyCatsForDuplicateCheckParams{
		Lat: lat, Lng: lng, RadiusM: duplicateCheckRadiusMeters,
	})
	if err != nil {
		return nil, err
	}
	return toDuplicateCandidates(rows), nil
}

func toDuplicateCandidates(rows []repository.ListNearbyCatsForDuplicateCheckRow) []DuplicateCandidate {
	candidates := make([]DuplicateCandidate, 0, len(rows))
	for _, r := range rows {
		candidates = append(candidates, DuplicateCandidate{
			ID:           uuid.UUID(r.ID.Bytes).String(),
			Name:         r.Name.String,
			PrimaryPhoto: r.PhotoUrl,
		})
	}
	return candidates
}

// Create adds a new cat (issue #70), attributed to the authenticated
// account identified by userID (never client-supplied) with deviceID
// (optional, installation/abuse-control association only) recorded
// alongside it. photoBytes is required (docs/product/cats.md: "the minimum
// information to add a cat is a photo and a location") and is validated and
// stored exactly like a standalone POST /v1/media upload (see
// service.mediaPipeline) — Create just also writes the resulting media row
// and the new cats row together in one transaction (see
// repository.Store.CreateCatWithMedia).
//
// Duplicate handling (docs/product/cats.md/trust.md: advisory, never
// blocking): when confirmedNew is false, an existing nearby cat within
// duplicateCheckRadiusMeters short-circuits with *DuplicateCandidatesError
// before any photo is uploaded or any row written — the caller (handler)
// answers 409 with the candidate list. Passing confirmedNew true always
// proceeds regardless of what's nearby.
//
// idempotencyKey, when non-nil, makes a retried call with the same key
// return the original result instead of creating a second cat, a second
// media row, or a second stored object — checked first, before any
// validation, upload, or duplicate query, so a retry is always cheap and
// side-effect-free.
func (s *CatsService) Create(ctx context.Context, userID, deviceID string, idempotencyKey *string, lat, lng float64, name *string, confirmedNew bool, photoBytes []byte) (CatDetail, error) {
	if s.pipeline == nil {
		return CatDetail{}, ErrMediaPipelineNotConfigured
	}
	uid, err := uuid.Parse(userID)
	if err != nil {
		return CatDetail{}, err
	}
	authorDeviceID, err := optionalUUID(deviceID)
	if err != nil {
		return CatDetail{}, err
	}
	ownerUUID := pgtype.UUID{Bytes: uid, Valid: true}
	idemKey := nullableText(idempotencyKey)

	if idemKey.Valid {
		existing, err := s.db.GetCatByIdempotencyKey(ctx, repository.GetCatByIdempotencyKeyParams{
			CreatedByUserID: ownerUUID,
			IdempotencyKey:  idemKey,
		})
		if err == nil {
			return s.GetCatDetail(ctx, uuid.UUID(existing.ID.Bytes).String())
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return CatDetail{}, err
		}
	}

	if !withinIstanbul(lat, lng) {
		return CatDetail{}, ErrInvalidArea
	}
	if len(photoBytes) == 0 {
		return CatDetail{}, ErrMissingPhoto
	}

	if !confirmedNew {
		candidates, err := s.ListNearbyDuplicates(ctx, lat, lng)
		if err != nil {
			return CatDetail{}, err
		}
		if len(candidates) > 0 {
			return CatDetail{}, &DuplicateCandidatesError{Candidates: candidates}
		}
	}

	processed, err := s.pipeline.process(photoBytes)
	if err != nil {
		return CatDetail{}, err
	}
	objectKey, url, err := s.pipeline.upload(ctx, processed)
	if err != nil {
		return CatDetail{}, err
	}

	row, err := s.db.CreateCatWithMedia(ctx, repository.CreateCatWithMediaParams{
		Media: repository.CreateMediaParams{
			ID:                 pgtype.UUID{Bytes: uuid.New(), Valid: true},
			ObjectKey:          objectKey,
			Url:                url,
			ContentType:        processed.contentType,
			ByteSize:           int32(len(processed.data)),
			UploadedByUserID:   ownerUUID,
			UploadedByDeviceID: authorDeviceID,
		},
		Cat: repository.CreateCatParams{
			ID:                pgtype.UUID{Bytes: uuid.New(), Valid: true},
			Name:              nullableText(name),
			Lng:               lng,
			Lat:               lat,
			CreatedByUserID:   ownerUUID,
			CreatedByDeviceID: authorDeviceID,
			IdempotencyKey:    idemKey,
		},
	})
	if err != nil {
		return s.recoverFromCreateCatFailure(ctx, err, objectKey, ownerUUID, idemKey)
	}

	return CatDetail{
		ID:           uuid.UUID(row.Cat.ID.Bytes).String(),
		Name:         row.Cat.Name.String,
		Lat:          row.Cat.Lat,
		Lng:          row.Cat.Lng,
		AreaLabel:    textPtr(row.Cat.AreaLabel),
		PrimaryPhoto: &url,
		CreatedAt:    row.Cat.CreatedAt.Time,
		LastUpdateAt: timestamptzPtr(row.Cat.LastUpdateAt),
	}, nil
}

// recoverFromCreateCatFailure runs after CreateCatWithMedia fails: if the
// failure was the cats-table idempotency conflict (no row returned — see
// CreateCat's comment), it fetches and returns the cat an earlier,
// successful call already created (a concurrent identical retry, or a
// caller that lost the first response); otherwise it's a genuine error.
// Either way, the transaction rolled back the media row that would have
// pointed at the object just uploaded, so it's deleted best-effort — a
// failed cleanup is logged, not escalated, mirroring
// MediaService.recoverFromCreateFailure.
func (s *CatsService) recoverFromCreateCatFailure(ctx context.Context, createErr error, objectKey string, ownerUUID pgtype.UUID, idemKey pgtype.Text) (CatDetail, error) {
	var result CatDetail
	var err error
	if errors.Is(createErr, pgx.ErrNoRows) && idemKey.Valid {
		existing, getErr := s.db.GetCatByIdempotencyKey(ctx, repository.GetCatByIdempotencyKeyParams{
			CreatedByUserID: ownerUUID,
			IdempotencyKey:  idemKey,
		})
		if getErr != nil {
			err = getErr
		} else {
			result, err = s.GetCatDetail(ctx, uuid.UUID(existing.ID.Bytes).String())
		}
	} else {
		err = createErr
	}

	if delErr := s.pipeline.store.Delete(ctx, objectKey); delErr != nil {
		slog.Error("failed to clean up media object after cat create failure", "key", objectKey, "error", delErr)
	}
	return result, err
}

// validateStatuses enforces issue #36's status-set rules: at least one
// status, every value drawn from the closed mvp vocabulary, no duplicates.
// All three collapse to the same 400 via ErrInvalidStatuses.
func validateStatuses(statuses []string) error {
	if len(statuses) == 0 {
		return ErrInvalidStatuses
	}
	seen := make(map[string]bool, len(statuses))
	for _, st := range statuses {
		if !approvedStatuses[st] {
			return ErrInvalidStatuses
		}
		if seen[st] {
			return ErrInvalidStatuses
		}
		seen[st] = true
	}
	return nil
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
