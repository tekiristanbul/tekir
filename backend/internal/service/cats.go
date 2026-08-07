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
// transaction. Post-#101 only the compat needs-help endpoint still accepts
// a category at all.
var ErrInvalidNeedsHelpCategory = errors.New("invalid needs-help category")

// ErrNoteTooLong means a help-carrying update's optional note exceeds
// needsHelpNoteMaxChars (issue #100's note constraint, applied by #101).
// Scoped to the help note only — an ordinary update's comment predates the
// contract and stays unconstrained here.
var ErrNoteTooLong = errors.New("needs-help note too long")

// ErrInvalidArea means the submitted location falls outside the product's
// geographic boundary (istanbulBounds below) or isn't well-formed
// (nan/inf/out-of-range lat/lng).
var ErrInvalidArea = errors.New("invalid area")

// ErrInvalidDiscoverFilter means GET /v1/cats/discover's filter query param
// (issue #82) wasn't one of the two mvp discovery views this endpoint
// serves — "nearby" or "needs_help". "following" isn't a value this
// endpoint recognizes at all: followed cats stay on GET /v1/me/follows
// (docs/product/discovery.md's third surface is private, account-owned
// state, not a location-aware read).
var ErrInvalidDiscoverFilter = errors.New("invalid discover filter")

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

// ErrNotCatOwner means the caller isn't the cat's owning account (issue
// #156: only the account that created a cat may change its cover photo).
// Not collapsed into ErrCatNotFound: a cat's ownership isn't private —
// GetCatDetail's own is_owner field already tells any reader, including a
// guest, whether they own it, so confirming "this exists, but isn't yours"
// leaks nothing a caller couldn't already see on the public detail read.
var ErrNotCatOwner = errors.New("not the cat owner")

// ErrInvalidMediaID means the media_id submitted to PATCH
// /v1/cats/{cat_id}/cover isn't a well-formed uuid.
var ErrInvalidMediaID = errors.New("invalid media id")

// ErrMediaNotInGallery means the submitted media_id isn't part of the cat's
// own cat_media archive (issue #156: the owner may only promote an existing
// gallery photo — one already attached to this cat via cat creation or an
// update — to cover, never point the cover at a stray media row uploaded
// for something else or belonging to a different cat).
var ErrMediaNotInGallery = errors.New("media not in cat gallery")

// ErrCorrectionWindowExpired means the caller is the update's author but
// the fixed 10-minute correction window (docs/product/updates.md) has
// closed — mirrors the otp/verify 410 convention (docs/architecture/api.md).
var ErrCorrectionWindowExpired = errors.New("correction window expired")

// ErrMediaNotFound means the caller supplied a media_id (issue #153) that
// either doesn't exist or wasn't uploaded by them. Both cases collapse into
// the same error and the same 404 — unlike ErrNotUpdateAuthor's public
// timeline, media ownership is never public, so confirming "this media
// exists, but isn't yours" would leak information a caller has no way to
// see otherwise.
var ErrMediaNotFound = errors.New("media not found")

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

	// defaultDiscoverLimit/maxDiscoverLimit (issue #82) mirror
	// defaultUpdatesLimit/maxUpdatesLimit's exact shape for
	// GET /v1/cats/discover's own page size.
	defaultDiscoverLimit = 20
	maxDiscoverLimit     = 50
)

// discoverFilterNearby/discoverFilterNeedsHelp are the only two values
// GET /v1/cats/discover's filter query param accepts (issue #82) — a plain
// string rather than a Go-side enum type, since it crosses the http
// boundary as one anyway and this keeps ListDiscover's dispatch a single
// switch rather than a parse-then-switch.
const (
	discoverFilterNearby    = "nearby"
	discoverFilterNeedsHelp = "needs_help"
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

// needsHelpCategoryLabels is the fixed, closed 0.1 help-category vocabulary
// and its turkish display label (product-owner decision on issue #4) — a
// check constraint in the database, not a data-driven vocabulary like
// traits, so it's a plain map rather than a repository-backed lookup.
// Post-#101 (issue #100's simplified help contract) this is a legacy
// vocabulary: it validates only the compat needs-help endpoint's input and
// labels stored legacy categories on reads. The combined update write path
// never touches it.
var needsHelpCategoryLabels = map[string]string{
	"injured_or_sick": "yaralı / hasta",
	"food_needed":     "mamaya ihtiyacı var",
	"water_needed":    "suya ihtiyacı var",
	"unsafe_location": "güvenli olmayan konum",
	"trapped":         "mahsur kalmış",
}

// needsHelpCompatCategory/-Label are what a category-less (post-#101) help
// mark serves in the response fields 0.1 clients require to be non-null
// (docs/product/alerts.md's mixed-client rule): active_alert.category/
// category_label and the timeline's needs_help_category/-_label. Never a
// valid submission value — needsHelpCategoryLabels above deliberately does
// not contain it. A 0.1 client's own analytics clamps "unspecified" to its
// existing `unknown` bucket, so no invalid closed-enum value is ever
// emitted (issue #101 acceptance).
const (
	needsHelpCompatCategory      = "unspecified"
	needsHelpCompatCategoryLabel = "Yardıma ihtiyacı var"
)

// needsHelpCategoryLabel resolves the display label for a stored legacy
// category, or the compat label when the row carries none.
func needsHelpCategoryLabel(category string) string {
	if label, ok := needsHelpCategoryLabels[category]; ok {
		return label
	}
	return needsHelpCompatCategoryLabel
}

// needsHelpNoteMaxChars caps the optional free-text note on a help mark
// (issue #100's note constraint: at most 500 unicode characters), counted
// in runes, not bytes.
const needsHelpNoteMaxChars = 500

// wireUpdateKind derives the response `kind` from the help flag (issue
// #101): "needs_help" for any help-carrying update, "ordinary" otherwise —
// regardless of the stored legacy kind column, which no longer reaches the
// wire.
func wireUpdateKind(needsHelp bool) string {
	if needsHelp {
		return "needs_help"
	}
	return "ordinary"
}

// validateNeedsHelpNote enforces the note cap on a help-carrying update's
// optional comment.
func validateNeedsHelpNote(comment *string) error {
	if comment == nil {
		return nil
	}
	if len([]rune(*comment)) > needsHelpNoteMaxChars {
		return ErrNoteTooLong
	}
	return nil
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

// ActiveAlert is the metadata a client needs to render an active help
// state: the reporter's optional note plus enough lifecycle
// (created_at/expires_at) to show context. Present only while ExpiresAt
// (as decided against the service's clock) means the state hasn't expired
// yet. Category/CategoryLabel are 0.1 compatibility fields (issue #101):
// a legacy row serves its stored vocabulary value, a post-#101 mark serves
// the fixed needsHelpCompatCategory pair — 0.2 clients ignore both and
// read Comment instead.
type ActiveAlert struct {
	Category      string
	CategoryLabel string
	Comment       *string
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

// DiscoverCat is one entry of GET /v1/cats/discover's paginated result
// (issue #82): the same map-marker-preview fields ListNearby/ListFollows
// already return, minus lat/lng (this is a distance-ordered list, not a
// viewport — a client that needs a cat's coordinates fetches its detail),
// plus DistanceMeters, the one field this endpoint adds. ActiveAlert is
// always non-nil for a "needs_help"-filter result (the query itself only
// returns cats with a currently active alert) and may be nil or non-nil
// for a "nearby"-filter result, exactly like CatMarker's.
type DiscoverCat struct {
	ID             string
	Name           string
	PrimaryPhoto   string
	AreaLabel      *string
	DistanceMeters float64
	ActiveAlert    *ActiveAlert
	LastUpdateAt   *time.Time
}

// DiscoverPage is one nearest-first page of GET /v1/cats/discover.
// NextCursor is empty when there is no further page — mirrors UpdatesPage.
type DiscoverPage struct {
	Items      []DiscoverCat
	NextCursor string
}

// discoverCursor is the decoded, opaque keyset pagination position: the
// (distance_m, id) of the last item on the previous page. Distinct from
// updatesCursor (created_at/seq) — this list is ordered by a computed
// distance, not a stored timestamp.
type discoverCursor struct {
	distanceMeters float64
	id             string
}

// encodeDiscoverCursor/decodeDiscoverCursor keep the pagination position
// opaque to clients, mirroring encode/decodeUpdatesCursor's exact shape —
// distance is encoded via strconv.FormatFloat's shortest-round-trip format
// ('g', precision -1), the same convention Go's own %v/json float
// formatting relies on to guarantee ParseFloat(FormatFloat(x)) == x, so
// re-decoding a page boundary's own distance can never drift from the
// float64 the database returned it as.
func encodeDiscoverCursor(c discoverCursor) string {
	raw := strconv.FormatFloat(c.distanceMeters, 'g', -1, 64) + ":" + c.id
	return base64.RawURLEncoding.EncodeToString([]byte(raw))
}

func decodeDiscoverCursor(raw string) (*discoverCursor, error) {
	if raw == "" {
		return nil, nil
	}
	decoded, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return nil, ErrInvalidCursor
	}
	distPart, idPart, ok := strings.Cut(string(decoded), ":")
	if !ok {
		return nil, ErrInvalidCursor
	}
	dist, err := strconv.ParseFloat(distPart, 64)
	if err != nil || math.IsNaN(dist) || math.IsInf(dist, 0) || dist < 0 {
		return nil, ErrInvalidCursor
	}
	if _, err := uuid.Parse(idPart); err != nil {
		return nil, ErrInvalidCursor
	}
	return &discoverCursor{distanceMeters: dist, id: idPart}, nil
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
// LastSeenAt/LastFedAt/LastWaterAt (issue #121's three-stat header parity
// gap) are each the cat's most recent update carrying that structured
// status — independent from LastUpdateAt (the cat's most recent update of
// any kind) and from each other, since a cat's last "seen" update need not
// be its last "fed" one.
type CatDetail struct {
	ID           string
	Name         string
	Lat          float64
	Lng          float64
	AreaLabel    *string
	PrimaryPhoto *string
	CreatedAt    time.Time
	LastUpdateAt *time.Time
	LastSeenAt   *time.Time
	LastFedAt    *time.Time
	LastWaterAt  *time.Time
	ActiveAlert  *ActiveAlert
	// MediaCount (issue #121's cover photo-counter parity gap) is the size
	// of the cat's cat_media archive — the design's cover pill and "medya"
	// tab count. Every cat created through POST /v1/cats has at least one
	// (its cover, inserted by CreateCatWithMedia); a pre-#70 seed cat with
	// only photo_url set has zero, matching that it has no media row to
	// archive.
	MediaCount int
	// IsOwner (issue #156) is true only when GetCatDetail was called with
	// the caller's own authenticated user id and it matches this cat's
	// created_by_user_id — always false for a guest read (no caller id at
	// all) or a pre-#70 seed cat (no owner at all). Server-derived so the
	// client never decides for itself whether to show the cover-change
	// affordance.
	IsOwner bool
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

	// AuthorDisplayName (issue #121's timeline-avatar parity gap) is the
	// author's users.display_name at read time — nil for a guest-authored
	// (pre-#65) row or an account that never set one; the handler falls
	// back to a generic avatar rather than inventing a name or initial.
	AuthorDisplayName *string

	// PhotoURL (issue #121's timeline-thumbnail parity gap) is the url of
	// the media this update carries, nil when it carries none — every row
	// reads nil today, since no write path sets updates.media_id yet (see
	// migration 00024's comment); the field exists so the client can render
	// the design's inline thumbnail the moment a future write path does.
	PhotoURL *string

	// NeedsHelp (issue #101) is the flag itself — the field 0.2 clients
	// read. The four fields below are populated exactly when it is true:
	// Category/CategoryLabel serve the stored legacy vocabulary value or
	// the fixed compat pair (0.1 clients require them non-null on a
	// help-carrying entry); ExpiresAt/Active are the server-decided
	// lifecycle, never left to a client clock.
	NeedsHelp              bool
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
	CorrectOwnUpdate(ctx context.Context, arg repository.CorrectOwnUpdateParams) (repository.CorrectOwnUpdateRow, error)
	DeleteOwnUpdate(ctx context.Context, arg repository.DeleteOwnUpdateParams) (repository.DeleteOwnUpdateRow, error)
	GetUpdateForCorrectionCheck(ctx context.Context, arg repository.GetUpdateForCorrectionCheckParams) (repository.GetUpdateForCorrectionCheckRow, error)
	GetUpdateByIdempotencyKey(ctx context.Context, arg repository.GetUpdateByIdempotencyKeyParams) (repository.GetUpdateByIdempotencyKeyRow, error)
	GetCatByIdempotencyKey(ctx context.Context, arg repository.GetCatByIdempotencyKeyParams) (repository.GetCatByIdempotencyKeyRow, error)
	ListNearbyCatsForDuplicateCheck(ctx context.Context, arg repository.ListNearbyCatsForDuplicateCheckParams) ([]repository.ListNearbyCatsForDuplicateCheckRow, error)
	CreateCatWithMedia(ctx context.Context, arg repository.CreateCatWithMediaParams) (repository.CreateCatWithMediaRow, error)
	ListCatsByDistance(ctx context.Context, arg repository.ListCatsByDistanceParams) ([]repository.ListCatsByDistanceRow, error)
	ListActiveNeedsHelpCatsByDistance(ctx context.Context, arg repository.ListActiveNeedsHelpCatsByDistanceParams) ([]repository.ListActiveNeedsHelpCatsByDistanceRow, error)
	CountCatMedia(ctx context.Context, catID pgtype.UUID) (int64, error)
	ListCatMedia(ctx context.Context, catID pgtype.UUID) ([]repository.ListCatMediaRow, error)
	GetUserByID(ctx context.Context, id pgtype.UUID) (repository.User, error)
	GetMediaByID(ctx context.Context, id pgtype.UUID) (repository.Medium, error)
	GetCatMediaByCatAndMedia(ctx context.Context, arg repository.GetCatMediaByCatAndMediaParams) (repository.CatMedium, error)
	SetCatCoverPhoto(ctx context.Context, arg repository.SetCatCoverPhotoParams) error
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
func deriveActiveAlert(clock func() time.Time, category, comment pgtype.Text, createdAt, expiresAt pgtype.Timestamptz) *ActiveAlert {
	// presence is decided by the expiry alone (issue #101): a post-#101
	// help mark carries no category, so category.Valid can no longer gate
	// whether an alert exists — only whether the compat fields serve a
	// stored legacy value or the fixed compat pair.
	if !expiresAt.Valid {
		return nil
	}
	if !expiresAt.Time.After(clock()) {
		return nil
	}
	alertCategory := needsHelpCompatCategory
	if category.Valid {
		alertCategory = category.String
	}
	return &ActiveAlert{
		Category:      alertCategory,
		CategoryLabel: needsHelpCategoryLabel(alertCategory),
		Comment:       textPtr(comment),
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
			ActiveAlert:  deriveActiveAlert(s.clock, r.NeedsHelpCategory, r.NeedsHelpComment, r.NeedsHelpCreatedAt, r.NeedsHelpExpiresAt),
			LastUpdateAt: timestamptzPtr(r.LastUpdateAt),
		})
	}
	return markers, nil
}

// ListDiscover answers GET /v1/cats/discover (issue #82): active cats
// nearest-first from (lat, lng), keyset-paginated. filter selects which of
// the two location-aware mvp discovery surfaces (docs/product/discovery.md)
// this call serves — discoverFilterNearby (every active cat) or
// discoverFilterNeedsHelp (only a cat whose latest needs-help update is
// still active against s.clock(), never the database's own now() or a
// client-supplied one). The third discovery surface, followed cats, isn't
// reachable through this method at all — it stays private, account-owned
// state served by GET /v1/me/follows (FollowsService), never this public,
// guest-readable read path. cursor is the opaque token from a previous
// page's NextCursor, or "" for the first page; limit == 0 falls back to
// defaultDiscoverLimit, matching ListCatUpdates' own convention.
func (s *CatsService) ListDiscover(ctx context.Context, filter string, lat, lng float64, cursor string, limit int) (DiscoverPage, error) {
	if filter != discoverFilterNearby && filter != discoverFilterNeedsHelp {
		return DiscoverPage{}, ErrInvalidDiscoverFilter
	}
	if !withinIstanbul(lat, lng) {
		return DiscoverPage{}, ErrInvalidArea
	}
	if limit == 0 {
		limit = defaultDiscoverLimit
	}
	if limit < 0 || limit > maxDiscoverLimit {
		return DiscoverPage{}, ErrInvalidLimit
	}
	decoded, err := decodeDiscoverCursor(cursor)
	if err != nil {
		return DiscoverPage{}, err
	}

	var afterDistance pgtype.Float8
	var afterID pgtype.UUID
	if decoded != nil {
		afterDistance = pgtype.Float8{Float64: decoded.distanceMeters, Valid: true}
		// decodeDiscoverCursor already validated decoded.id parses as a
		// uuid, so the error here can never actually trigger — checked
		// anyway rather than discarding it.
		parsedID, err := uuid.Parse(decoded.id)
		if err != nil {
			return DiscoverPage{}, ErrInvalidCursor
		}
		afterID = pgtype.UUID{Bytes: parsedID, Valid: true}
	}

	// fetch one extra row to detect a next page, exactly like ListCatUpdates.
	rowLimit := int32(limit + 1)

	// now is read once and reused for both the needs_help query's own
	// active-alert filter and this method's own ActiveAlert derivation
	// below (via the fixedClock closure) — two separate s.clock() calls a
	// few lines apart would risk the real time.Now() ticking forward
	// between them, which could make a cat the database just filtered in
	// as "still active" come back with ActiveAlert == nil (deriveActiveAlert
	// deciding, a moment later, that it had *just* expired). One instant,
	// used consistently, is what issue #82's "needs_help returns only cats
	// whose alert is active... ordered nearest first" requires.
	now := s.clock()
	fixedClock := func() time.Time { return now }

	var (
		items   []DiscoverCat
		lastRow *discoverRow
	)
	switch filter {
	case discoverFilterNearby:
		rows, err := s.db.ListCatsByDistance(ctx, repository.ListCatsByDistanceParams{
			Lng: lng, Lat: lat,
			AfterDistanceM: afterDistance,
			AfterID:        afterID,
			RowLimit:       rowLimit,
		})
		if err != nil {
			return DiscoverPage{}, err
		}
		hasMore := len(rows) > limit
		if hasMore {
			rows = rows[:limit]
		}
		for _, r := range rows {
			items = append(items, toDiscoverCat(fixedClock, r.ID, r.Name, r.PhotoUrl, r.AreaLabel, r.LastUpdateAt, r.NeedsHelpCategory, r.NeedsHelpComment, r.NeedsHelpCreatedAt, r.NeedsHelpExpiresAt, r.DistanceM))
		}
		if hasMore && len(rows) > 0 {
			last := rows[len(rows)-1]
			lastRow = &discoverRow{id: last.ID, distanceMeters: last.DistanceM}
		}
	case discoverFilterNeedsHelp:
		rows, err := s.db.ListActiveNeedsHelpCatsByDistance(ctx, repository.ListActiveNeedsHelpCatsByDistanceParams{
			Lng: lng, Lat: lat,
			Now:            pgtype.Timestamptz{Time: now, Valid: true},
			AfterDistanceM: afterDistance,
			AfterID:        afterID,
			RowLimit:       rowLimit,
		})
		if err != nil {
			return DiscoverPage{}, err
		}
		hasMore := len(rows) > limit
		if hasMore {
			rows = rows[:limit]
		}
		for _, r := range rows {
			items = append(items, toDiscoverCat(fixedClock, r.ID, r.Name, r.PhotoUrl, r.AreaLabel, r.LastUpdateAt, r.NeedsHelpCategory, r.NeedsHelpComment, r.NeedsHelpCreatedAt, r.NeedsHelpExpiresAt, r.DistanceM))
		}
		if hasMore && len(rows) > 0 {
			last := rows[len(rows)-1]
			lastRow = &discoverRow{id: last.ID, distanceMeters: last.DistanceM}
		}
	}

	page := DiscoverPage{Items: items}
	if lastRow != nil {
		page.NextCursor = encodeDiscoverCursor(discoverCursor{distanceMeters: lastRow.distanceMeters, id: uuid.UUID(lastRow.id.Bytes).String()})
	}
	return page, nil
}

// discoverRow is the minimal (id, distance) pair ListDiscover needs to
// build the next page's cursor, kept independent of which of the two
// per-filter row types (ListCatsByDistanceRow/
// ListActiveNeedsHelpCatsByDistanceRow) it came from.
type discoverRow struct {
	id             pgtype.UUID
	distanceMeters float64
}

// toDiscoverCat builds one DiscoverCat from either filter's row fields —
// both ListCatsByDistanceRow and ListActiveNeedsHelpCatsByDistanceRow share
// this exact field shape (see their query comments in db/queries/cats.sql),
// so one conversion serves both switch cases above instead of duplicating
// it per row type. clock is ListDiscover's fixedClock (a single s.clock()
// reading pinned for the whole call), not s.clock itself — see ListDiscover's
// own comment on why.
func toDiscoverCat(clock func() time.Time, id pgtype.UUID, name pgtype.Text, photoURL string, areaLabel pgtype.Text, lastUpdateAt pgtype.Timestamptz, needsHelpCategory, needsHelpComment pgtype.Text, needsHelpCreatedAt, needsHelpExpiresAt pgtype.Timestamptz, distanceMeters float64) DiscoverCat {
	return DiscoverCat{
		ID:             uuid.UUID(id.Bytes).String(),
		Name:           name.String,
		PrimaryPhoto:   photoURL,
		AreaLabel:      textPtr(areaLabel),
		DistanceMeters: distanceMeters,
		ActiveAlert:    deriveActiveAlert(clock, needsHelpCategory, needsHelpComment, needsHelpCreatedAt, needsHelpExpiresAt),
		LastUpdateAt:   timestamptzPtr(lastUpdateAt),
	}
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

// authorDisplayNameFor looks up authorUserID's current users.display_name,
// mirroring what ListCatUpdates' join already returns — needed on the
// create paths below because CreateOrdinaryUpdateParams' INSERT ... RETURNING
// never joins the users table (issue #139: the just-created update's
// response otherwise omits the author's name until the next full reload).
func (s *CatsService) authorDisplayNameFor(ctx context.Context, authorUserID uuid.UUID) (*string, error) {
	user, err := s.db.GetUserByID(ctx, pgtype.UUID{Bytes: authorUserID, Valid: true})
	if err != nil {
		return nil, err
	}
	return textPtr(user.DisplayName), nil
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
// if no cat exists with that id. callerUserID (issue #156) is the optional
// bearer caller's own account id — "" for a guest read or an absent/invalid
// bearer (GET /v1/cats/{cat_id} uses OptionalBearer, never RequireBearer, so
// this endpoint stays guest-readable) — used only to derive IsOwner, never
// to gate the read itself.
func (s *CatsService) GetCatDetail(ctx context.Context, id, callerUserID string) (CatDetail, error) {
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

	mediaCount, err := s.db.CountCatMedia(ctx, catID)
	if err != nil {
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
		LastSeenAt:   timestamptzPtr(row.LastSeenAt),
		LastFedAt:    timestamptzPtr(row.LastFedAt),
		LastWaterAt:  timestamptzPtr(row.LastWaterAt),
		ActiveAlert:  deriveActiveAlert(s.clock, row.NeedsHelpCategory, row.NeedsHelpComment, row.NeedsHelpCreatedAt, row.NeedsHelpExpiresAt),
		MediaCount:   int(mediaCount),
		IsOwner:      isCatOwner(row.CreatedByUserID, callerUserID),
	}, nil
}

// isCatOwner reports whether callerUserID (a possibly-empty, possibly
// malformed caller-supplied id) matches ownerID (the cat's own
// created_by_user_id, possibly sql-null for a pre-#70 seed cat). A
// malformed callerUserID (shouldn't happen — OptionalBearer/RequireBearer
// only ever place a well-formed uuid or nothing at all in context) simply
// never matches, mirroring ListCatUpdates' own AuthorIsMe derivation.
func isCatOwner(ownerID pgtype.UUID, callerUserID string) bool {
	if !ownerID.Valid || callerUserID == "" {
		return false
	}
	parsed, err := uuid.Parse(callerUserID)
	if err != nil {
		return false
	}
	return uuid.UUID(ownerID.Bytes) == parsed
}

// CatMediaItem is one entry of the cat-profile "medya" archive tab (issue
// #121's media-archive parity gap): a photo linked to the cat via
// cat_media, newest-first. IsCover mirrors cats.primary_photo_id, letting
// the client render the design's "ana" badge without a second lookup.
// UploaderDisplayName (issue #154's media-attribution parity gap) mirrors
// CatUpdate's own AuthorDisplayName: nil only when the uploader never set
// a display name, never when the uploader is unknown.
type CatMediaItem struct {
	ID                  string
	URL                 string
	IsCover             bool
	CreatedAt           time.Time
	UploaderDisplayName *string
}

// ListCatMedia returns id's photo archive, newest-first, or ErrCatNotFound
// if no cat exists with that id.
func (s *CatsService) ListCatMedia(ctx context.Context, id string) ([]CatMediaItem, error) {
	catID, err := parseCatID(id)
	if err != nil {
		return nil, err
	}

	exists, err := s.db.CatExists(ctx, catID)
	if err != nil {
		return nil, err
	}
	if !exists {
		return nil, ErrCatNotFound
	}

	rows, err := s.db.ListCatMedia(ctx, catID)
	if err != nil {
		return nil, err
	}

	items := make([]CatMediaItem, 0, len(rows))
	for _, r := range rows {
		items = append(items, CatMediaItem{
			ID:                  uuid.UUID(r.ID.Bytes).String(),
			URL:                 r.Url,
			IsCover:             r.IsCover,
			CreatedAt:           r.CreatedAt.Time,
			UploaderDisplayName: textPtr(r.UploaderDisplayName),
		})
	}
	return items, nil
}

// SetCoverPhoto changes cat id's cover to mediaID, the promoted entry's own
// id from GET /v1/cats/{cat_id}/media (issue #156). Only the cat's owning
// account (created_by_user_id) may do this — ErrNotCatOwner for anyone
// else, including another authenticated account, never a silent no-op —
// and mediaID must already be part of that cat's own cat_media archive
// (ErrMediaNotInGallery otherwise): the owner picks an existing gallery
// photo, never an arbitrary media row from elsewhere. Neither check leaks
// which failed to a non-owner caller versus a bad media id beyond their own
// distinct error codes — both are legitimate client-facing outcomes, not a
// security boundary to obscure. The update never touches the update or
// media row the photo came from — only cats.primary_photo_id moves; the
// original contribution stays exactly as its author left it. Returns the
// refreshed CatDetail, same shape GetCatDetail already gives the caller who
// just made this change.
func (s *CatsService) SetCoverPhoto(ctx context.Context, id, callerUserID, mediaID string) (CatDetail, error) {
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
	if !isCatOwner(row.CreatedByUserID, callerUserID) {
		return CatDetail{}, ErrNotCatOwner
	}

	parsedMediaID, err := uuid.Parse(mediaID)
	if err != nil {
		return CatDetail{}, ErrInvalidMediaID
	}
	mediaUUID := pgtype.UUID{Bytes: parsedMediaID, Valid: true}

	if _, err := s.db.GetCatMediaByCatAndMedia(ctx, repository.GetCatMediaByCatAndMediaParams{
		CatID:   catID,
		MediaID: mediaUUID,
	}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return CatDetail{}, ErrMediaNotInGallery
		}
		return CatDetail{}, err
	}

	if err := s.db.SetCatCoverPhoto(ctx, repository.SetCatCoverPhotoParams{
		ID:             catID,
		PrimaryPhotoID: mediaUUID,
	}); err != nil {
		return CatDetail{}, err
	}

	return s.GetCatDetail(ctx, id, callerUserID)
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
			ID: uuid.UUID(r.ID.Bytes).String(),
			// wire kind is derived from the flag (issue #101), not the
			// stored column: a 0.1 client renders any help-carrying entry
			// through its needs-help branch (help pill, no statuses, no
			// correction menu) — the safe degradation for a combined
			// update — while a 0.2 client reads NeedsHelp/Statuses
			// directly. The stored kind only still distinguishes a legacy
			// pre-#101 subtype row below.
			Kind:              wireUpdateKind(r.NeedsHelp),
			Statuses:          r.Statuses,
			Comment:           textPtr(r.Comment),
			CreatedAt:         r.CreatedAt.Time,
			NeedsHelp:         r.NeedsHelp,
			AuthorDisplayName: textPtr(r.AuthorDisplayName),
			PhotoURL:          textPtr(r.PhotoUrl),
		}
		if r.NeedsHelp {
			category := needsHelpCompatCategory
			if r.NeedsHelpCategory.Valid {
				category = r.NeedsHelpCategory.String
			}
			label := needsHelpCategoryLabel(category)
			expiresAt := r.NeedsHelpExpiresAt.Time
			active := expiresAt.After(s.clock())
			item.NeedsHelpCategory = &category
			item.NeedsHelpCategoryLabel = &label
			item.NeedsHelpExpiresAt = &expiresAt
			item.NeedsHelpActive = &active
		}
		if haveCaller && r.AuthorUserID.Valid && uuid.UUID(r.AuthorUserID.Bytes) == callerUUID {
			item.AuthorIsMe = true
			// correctability follows the stored kind, not the wire kind: a
			// legacy pre-#101 subtype row is still not a correctable
			// resource, while every post-#101 row (help-carrying or not)
			// is, inside its window (product decision on #101: the author
			// may remove their own help mark within 10 minutes).
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
// sufficient on its own. kind, needs-help fields, timestamps, sequence, and
// author identity are never accepted from the caller — kind is always
// "ordinary" here, created_at/author_user_id/author_device_id are
// server-derived, and the update row, its statuses, and the cat's
// last_update_at commit as one transaction (see
// repository.Store.CreateOrdinaryUpdate).
//
// idempotencyKey (issue #80, product-owner review), when non-nil, makes a
// retried call with the same key return the original update instead of
// creating a second one — checked first, before status validation or any
// write, mirroring CatsService.Create's own idempotency-key contract
// exactly. A genuine race between two concurrent identical retries (both
// miss the initial check) is resolved by falling back to the same lookup
// after a unique-constraint violation on the insert, rather than
// surfacing a raw database error to either caller.
// needsHelp (issue #101, contract issue #100) marks the update as a help
// call: the 72h expiry is server-computed, the notification fan-out is
// decided downstream by the worker (suppressed while the cat already had
// an active help state), and the optional comment doubles as the help note
// under the contract's 500-rune cap. statuses may then be empty — the
// create invariant is "at least one status or the help flag".
//
// mediaID (issue #153) is optional and, when non-nil, must name a media
// row the caller themselves uploaded via POST /v1/media beforehand — never
// raw media bytes; this endpoint only ever links an id, mirroring the
// standalone-upload-then-link shape media.go's own doc comment already
// described. A mediaID that doesn't exist or wasn't uploaded by userID
// fails closed with ErrMediaNotFound rather than silently dropping it or
// attaching someone else's photo.
func (s *CatsService) CreateOrdinaryUpdate(ctx context.Context, id, userID, deviceID string, idempotencyKey *string, statuses []string, needsHelp bool, comment *string, mediaID *string) (CatUpdate, error) {
	catID, err := parseCatID(id)
	if err != nil {
		return CatUpdate{}, err
	}

	// userID comes from the authenticated bearer context the
	// RequireBearer middleware places on the request — it is always a
	// well-formed uuid the middleware itself resolved, never
	// client-supplied input to re-validate against a sentinel error here.
	authorUserID, err := uuid.Parse(userID)
	if err != nil {
		return CatUpdate{}, err
	}

	idemKey := nullableText(idempotencyKey)
	if idemKey.Valid {
		existing, err := s.fetchIdempotentOrdinaryUpdate(ctx, authorUserID, idemKey)
		if err == nil {
			return existing, nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return CatUpdate{}, err
		}
	}

	if err := validateStatusSet(statuses, needsHelp); err != nil {
		return CatUpdate{}, err
	}
	if needsHelp {
		if err := validateNeedsHelpNote(comment); err != nil {
			return CatUpdate{}, err
		}
	}

	// deviceID (from the optional device-token context) may be "".
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

	media, err := s.resolveOwnMedia(ctx, mediaID, authorUserID)
	if err != nil {
		return CatUpdate{}, err
	}

	// always a non-nil slice: a help-only update has no statuses, but the
	// response field must marshal as [] (never null) — Flutter's
	// CatUpdateEntry.fromJson casts statuses as a non-nullable List.
	sorted := append([]string{}, statuses...)
	sort.Strings(sorted)

	createdAt := s.clock()
	params := repository.CreateOrdinaryUpdateParams{
		ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
		CatID:          catID,
		AuthorDeviceID: authorDeviceID,
		AuthorUserID:   pgtype.UUID{Bytes: authorUserID, Valid: true},
		Comment:        nullableText(comment),
		CreatedAt:      pgtype.Timestamptz{Time: createdAt, Valid: true},
		Statuses:       sorted,
		IdempotencyKey: idemKey,
	}
	if needsHelp {
		params.NeedsHelp = true
		params.NeedsHelpExpiresAt = pgtype.Timestamptz{Time: NeedsHelpExpiresAt(createdAt), Valid: true}
	}
	if media != nil {
		params.MediaID = media.ID
	}
	row, err := s.db.CreateOrdinaryUpdate(ctx, params)
	if err != nil {
		if idemKey.Valid && isUniqueViolation(err) {
			if existing, getErr := s.fetchIdempotentOrdinaryUpdate(ctx, authorUserID, idemKey); getErr == nil {
				return existing, nil
			}
		}
		return CatUpdate{}, err
	}

	authorDisplayName, err := s.authorDisplayNameFor(ctx, authorUserID)
	if err != nil {
		return CatUpdate{}, err
	}

	expiresAt := createdAt.Add(updateCorrectionWindow)
	result := CatUpdate{
		ID:        uuid.UUID(row.ID.Bytes).String(),
		Kind:      wireUpdateKind(needsHelp),
		Statuses:  sorted,
		Comment:   comment,
		CreatedAt: createdAt,
		NeedsHelp: needsHelp,
		// the caller always authored the update they just created, and it
		// is always freshly inside the correction window at creation time
		// (issue #80) — never left false/nil the way a zero-value CatUpdate
		// would, which would otherwise hide the correction affordance from
		// the client immediately after posting until the next full reload.
		AuthorIsMe:          true,
		CorrectionExpiresAt: &expiresAt,
		AuthorDisplayName:   authorDisplayName,
	}
	if media != nil {
		result.PhotoURL = &media.Url
	}
	if needsHelp {
		category := needsHelpCompatCategory
		label := needsHelpCompatCategoryLabel
		helpExpires := NeedsHelpExpiresAt(createdAt)
		active := true
		result.NeedsHelpCategory = &category
		result.NeedsHelpCategoryLabel = &label
		result.NeedsHelpExpiresAt = &helpExpires
		result.NeedsHelpActive = &active
	}
	return result, nil
}

// resolveOwnMedia looks up mediaID (when non-nil) and confirms
// authorUserID uploaded it, for the ordinary-update write path's optional
// photo attachment (issue #153). Returns (nil, nil) when mediaID is nil —
// the update simply carries no photo, same as today. A malformed id or a
// media row that doesn't exist or belongs to someone else both fail
// closed with ErrMediaNotFound; the caller never learns which.
func (s *CatsService) resolveOwnMedia(ctx context.Context, mediaID *string, authorUserID uuid.UUID) (*repository.Medium, error) {
	if mediaID == nil {
		return nil, nil
	}
	parsed, err := uuid.Parse(*mediaID)
	if err != nil {
		return nil, ErrMediaNotFound
	}
	media, err := s.db.GetMediaByID(ctx, pgtype.UUID{Bytes: parsed, Valid: true})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrMediaNotFound
		}
		return nil, err
	}
	if uuid.UUID(media.UploadedByUserID.Bytes) != authorUserID || !media.UploadedByUserID.Valid {
		return nil, ErrMediaNotFound
	}
	return &media, nil
}

// fetchIdempotentOrdinaryUpdate resolves a presented Idempotency-Key to the
// ordinary update it already created for authorUserID, if any — returns
// pgx.ErrNoRows unchanged when no such update exists yet, so callers can
// tell "no retry in progress" apart from a genuine lookup failure.
// CorrectionExpiresAt is always createdAt + the fixed window, matching
// ListCatUpdates' own convention of stating the fact and leaving "is it
// still open" to CatUpdateEntry.isCorrectionOpen() on the client.
func (s *CatsService) fetchIdempotentOrdinaryUpdate(ctx context.Context, authorUserID uuid.UUID, idemKey pgtype.Text) (CatUpdate, error) {
	row, err := s.db.GetUpdateByIdempotencyKey(ctx, repository.GetUpdateByIdempotencyKeyParams{
		AuthorUserID:   pgtype.UUID{Bytes: authorUserID, Valid: true},
		IdempotencyKey: idemKey,
	})
	if err != nil {
		return CatUpdate{}, err
	}
	authorDisplayName, err := s.authorDisplayNameFor(ctx, authorUserID)
	if err != nil {
		return CatUpdate{}, err
	}

	createdAt := row.CreatedAt.Time
	expiresAt := createdAt.Add(updateCorrectionWindow)
	result := CatUpdate{
		ID:                  uuid.UUID(row.ID.Bytes).String(),
		Kind:                wireUpdateKind(row.NeedsHelp),
		Statuses:            row.Statuses,
		Comment:             textPtr(row.Comment),
		CreatedAt:           createdAt,
		NeedsHelp:           row.NeedsHelp,
		AuthorIsMe:          true,
		CorrectionExpiresAt: &expiresAt,
		AuthorDisplayName:   authorDisplayName,
		PhotoURL:            textPtr(row.PhotoUrl),
	}
	if row.NeedsHelp {
		category := needsHelpCompatCategory
		label := needsHelpCompatCategoryLabel
		helpExpires := row.NeedsHelpExpiresAt.Time
		active := helpExpires.After(s.clock())
		result.NeedsHelpCategory = &category
		result.NeedsHelpCategoryLabel = &label
		result.NeedsHelpExpiresAt = &helpExpires
		result.NeedsHelpActive = &active
	}
	return result, nil
}

// CreateNeedsHelpUpdate answers the 0.1 compatibility endpoint
// POST /v1/cats/{cat_id}/needs-help (issue #78; kept through the mixed
// 0.1/0.2 window by issue #101 so live 0.1 clients keep working
// unchanged). category must still be one of needsHelpCategoryLabels' fixed
// 5 values — 0.1 clients only ever send those — and is recorded on the row
// as legacy metadata only (issue #100: never rendered by the 0.2 ui, never
// reproduced as a note). The write itself is the unified flag-model write:
// kind = 'ordinary', needs_help = true, no statuses — so the mark is
// clearable/deletable by its author exactly like one made through
// POST .../updates, and the worker's fan-out/suppression logic sees one
// shape. expires_at is always computed here as createdAt + NeedsHelpExpiry
// — never accepted from the caller. Retiring this endpoint entirely is
// deferred until 0.1 clients are retired.
func (s *CatsService) CreateNeedsHelpUpdate(ctx context.Context, id, userID, deviceID, category string, comment *string) (CatUpdate, error) {
	catID, err := parseCatID(id)
	if err != nil {
		return CatUpdate{}, err
	}

	if _, ok := needsHelpCategoryLabels[category]; !ok {
		return CatUpdate{}, ErrInvalidNeedsHelpCategory
	}
	if err := validateNeedsHelpNote(comment); err != nil {
		return CatUpdate{}, err
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
	row, err := s.db.CreateOrdinaryUpdate(ctx, repository.CreateOrdinaryUpdateParams{
		ID:                 pgtype.UUID{Bytes: uuid.New(), Valid: true},
		CatID:              catID,
		AuthorDeviceID:     authorDeviceID,
		AuthorUserID:       pgtype.UUID{Bytes: authorUserID, Valid: true},
		Comment:            nullableText(comment),
		CreatedAt:          pgtype.Timestamptz{Time: createdAt, Valid: true},
		NeedsHelp:          true,
		NeedsHelpCategory:  pgtype.Text{String: category, Valid: true},
		NeedsHelpExpiresAt: pgtype.Timestamptz{Time: expiresAt, Valid: true},
	})
	if err != nil {
		return CatUpdate{}, err
	}

	authorDisplayName, err := s.authorDisplayNameFor(ctx, authorUserID)
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
		NeedsHelp:              true,
		NeedsHelpCategory:      &category,
		NeedsHelpCategoryLabel: &label,
		NeedsHelpExpiresAt:     &expiresAt,
		NeedsHelpActive:        &active,
		AuthorDisplayName:      authorDisplayName,
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
func (s *CatsService) resolveCorrectionFailure(ctx context.Context, catID, updateID pgtype.UUID, authorUserID uuid.UUID, windowStart time.Time, correction bool) (alreadyDeleted bool, err error) {
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
	// every row-state condition the conditional update itself checks held
	// true here, yet it still affected zero rows. For a correction (issue
	// #101) the one remaining cause is the post-state invariant: the
	// request would have left the row with no statuses and no help flag —
	// invalid content, same 400 family as any other bad status set (the
	// author deletes the update instead of hollowing it out). For a delete
	// there is no such condition; only a genuine race (e.g. concurrently
	// deleted between the two statements) remains — surface as "not found"
	// rather than panicking on an assumption that can't hold.
	if correction {
		return false, ErrInvalidStatuses
	}
	return false, ErrUpdateNotFound
}

// UpdateCorrection carries a PATCH body's presence-aware fields into
// CorrectOwnUpdate (issue #105): a nil Statuses means "preserve the
// existing set" (an empty non-nil slice is an explicit clear, valid only
// while the help flag survives), and Comment is written only when
// SetComment is true (an explicit JSON null clears it; an omitted field
// preserves it). ClearNeedsHelp (issue #101) removes the row's help mark.
type UpdateCorrection struct {
	Statuses       *[]string
	ClearNeedsHelp bool
	SetComment     bool
	Comment        *string
}

// CorrectOwnUpdate applies an in-window correction to the caller's own
// ordinary update (issue #80): statuses and/or comment. kind, author
// identity, and created_at are never alterable through this path — only
// comment/statuses (and, issue #101, the help flag — removal only) change,
// and updated_at is server-derived exactly like CreateOrdinaryUpdate's
// created_at. windowStart is computed against s.clock, never the caller's
// own notion of time, matching every other time-relative decision in this
// service.
//
// The request is presence-aware (issue #105): a field the PATCH body
// omitted preserves the row's existing value — patching only
// {"needs_help": false} must not erase the update's statuses or comment.
// Validation therefore only runs against a status set the caller actually
// supplied; the post-state invariant (at least one status, or the flag
// survives) is enforced by the conditional statement against whichever
// set — replacement or preserved — the row ends up with.
//
// ClearNeedsHelp (issue #101, "işareti koyan kullanıcı 10 dakika içinde
// kaldırabilir") removes the row's help mark: flag, expiry, and any
// compat-recorded legacy category are nulled together so the check
// constraint holds. A correction can never ADD the flag — marking help
// happens only at creation, so there is never a retroactive notification
// to fan out. An obviously-hollow request — an explicit empty status set
// while clearing — is rejected here before touching the database.
func (s *CatsService) CorrectOwnUpdate(ctx context.Context, catID, updateID, userID string, correction UpdateCorrection) (CatUpdate, error) {
	catUUID, err := parseCatID(catID)
	if err != nil {
		return CatUpdate{}, err
	}
	updateUUID, err := parseUpdateID(updateID)
	if err != nil {
		return CatUpdate{}, err
	}
	if correction.Statuses != nil {
		if err := validateStatusSet(*correction.Statuses, !correction.ClearNeedsHelp); err != nil {
			return CatUpdate{}, err
		}
	}
	// userID is always a well-formed uuid from RequireBearer's context —
	// never client-supplied input to re-validate against a sentinel error.
	authorUserID, err := uuid.Parse(userID)
	if err != nil {
		return CatUpdate{}, err
	}

	now := s.clock()
	windowStart := now.Add(-updateCorrectionWindow)
	var sorted []string
	if correction.Statuses != nil {
		sorted = append([]string(nil), *correction.Statuses...)
		sort.Strings(sorted)
	}

	row, err := s.db.CorrectOwnUpdate(ctx, repository.CorrectOwnUpdateParams{
		ID:              updateUUID,
		CatID:           catUUID,
		AuthorUserID:    pgtype.UUID{Bytes: authorUserID, Valid: true},
		SetComment:      correction.SetComment,
		Comment:         nullableText(correction.Comment),
		UpdatedAt:       pgtype.Timestamptz{Time: now, Valid: true},
		WindowStart:     pgtype.Timestamptz{Time: windowStart, Valid: true},
		ReplaceStatuses: correction.Statuses != nil,
		Statuses:        sorted,
		ClearNeedsHelp:  correction.ClearNeedsHelp,
	})
	if err != nil {
		if !errors.Is(err, pgx.ErrNoRows) {
			return CatUpdate{}, err
		}
		if _, resolveErr := s.resolveCorrectionFailure(ctx, catUUID, updateUUID, authorUserID, windowStart, true); resolveErr != nil {
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
	// row.Statuses/row.Comment are the row's post-correction values whether
	// the request replaced them or preserved them (issue #105) — echoing
	// them, not the request fields, keeps the response truthful for a
	// partial patch. Statuses must marshal as [] (never null), matching
	// CreateOrdinaryUpdate's own guarantee.
	statuses := row.Statuses
	if statuses == nil {
		statuses = []string{}
	}
	result := CatUpdate{
		ID:                  uuid.UUID(row.ID.Bytes).String(),
		Kind:                wireUpdateKind(row.NeedsHelp),
		Statuses:            statuses,
		Comment:             textPtr(row.Comment),
		CreatedAt:           createdAt,
		UpdatedAt:           &updatedAt,
		NeedsHelp:           row.NeedsHelp,
		AuthorIsMe:          true,
		CorrectionExpiresAt: &expiresAt,
	}
	if row.NeedsHelp {
		category := needsHelpCompatCategory
		label := needsHelpCompatCategoryLabel
		helpExpires := row.NeedsHelpExpiresAt.Time
		active := helpExpires.After(now)
		result.NeedsHelpCategory = &category
		result.NeedsHelpCategoryLabel = &label
		result.NeedsHelpExpiresAt = &helpExpires
		result.NeedsHelpActive = &active
	}
	return result, nil
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
	alreadyDeleted, resolveErr := s.resolveCorrectionFailure(ctx, catUUID, updateUUID, authorUserID, windowStart, false)
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
			return s.GetCatDetail(ctx, uuid.UUID(existing.ID.Bytes).String(), userID)
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
			result, err = s.GetCatDetail(ctx, uuid.UUID(existing.ID.Bytes).String(), uuid.UUID(ownerUUID.Bytes).String())
		}
	} else {
		err = createErr
	}

	if delErr := s.pipeline.store.Delete(ctx, objectKey); delErr != nil {
		slog.Error("failed to clean up media object after cat create failure", "key", objectKey, "error", delErr)
	}
	return result, err
}

// validateStatusSet enforces issue #36's status-set rules — every value
// drawn from the closed mvp vocabulary, no duplicates — with the
// emptiness rule made explicit (issue #101): a help-carrying update may
// omit statuses entirely ("yardıma ihtiyacı var" alone is a valid update),
// so those write paths pass allowEmpty. Every violation collapses to the
// same 400 via ErrInvalidStatuses.
func validateStatusSet(statuses []string, allowEmpty bool) error {
	if len(statuses) == 0 {
		if allowEmpty {
			return nil
		}
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
