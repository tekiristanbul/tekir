package handler

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// validTestJPEG returns real, decodable jpeg bytes — CatsService.Create's
// shared media pipeline (issue #70) genuinely decodes/re-encodes a photo
// before storing it, so a handler-level "success" test needs a real image,
// not an arbitrary byte string.
func validTestJPEG(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 4, 4))
	for y := 0; y < 4; y++ {
		for x := 0; x < 4; x++ {
			img.Set(x, y, color.RGBA{R: uint8(x * 10), G: uint8(y * 10), B: 100, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, nil); err != nil {
		t.Fatalf("encode test jpeg: %v", err)
	}
	return buf.Bytes()
}

// testMaxUploadBytes is a stand-in maxUploadBytes for tests that don't
// exercise Create's multipart size limit itself.
const testMaxUploadBytes = 8 * 1024 * 1024

type fakeCatsLister struct {
	rows []repository.ListCatsInBoundsRow

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
	// copy of fakeCatsLister that ends up inside the service.
	captured *repository.CreateOrdinaryUpdateParams

	createNeedsHelpRow repository.CreateUpdateRow
	createNeedsHelpErr error
	capturedNeedsHelp  *repository.CreateOrdinaryUpdateParams

	idempotencyRow repository.GetCatByIdempotencyKeyRow
	idempotencyErr error

	updateIdempotencyRow repository.GetUpdateByIdempotencyKeyRow
	updateIdempotencyErr error

	nearbyDuplicateRows []repository.ListNearbyCatsForDuplicateCheckRow
	nearbyDuplicateErr  error

	createCatWithMediaRow repository.CreateCatWithMediaRow
	createCatWithMediaErr error

	correctRow repository.CorrectOwnUpdateRow
	// capturedCorrect mirrors captured above, for CorrectOwnUpdate.
	capturedCorrect *repository.CorrectOwnUpdateParams
	correctErr      error

	deleteRow repository.DeleteOwnUpdateRow
	deleteErr error

	correctionCheckRow repository.GetUpdateForCorrectionCheckRow
	correctionCheckErr error

	distanceRows []repository.ListCatsByDistanceRow
	distanceErr  error

	needsHelpDistanceRows []repository.ListActiveNeedsHelpCatsByDistanceRow
	needsHelpDistanceErr  error

	mediaCount    int64
	mediaCountErr error

	mediaRows []repository.ListCatMediaRow
	mediaErr  error

	userRow repository.User
	userErr error

	getMediaRow repository.Medium
	getMediaErr error

	catMediaRow repository.CatMedium
	catMediaErr error

	setCoverErr error
}

func (f fakeCatsLister) GetUserByID(ctx context.Context, id pgtype.UUID) (repository.User, error) {
	return f.userRow, f.userErr
}

func (f fakeCatsLister) GetMediaByID(ctx context.Context, id pgtype.UUID) (repository.Medium, error) {
	return f.getMediaRow, f.getMediaErr
}

func (f fakeCatsLister) GetCatMediaByCatAndMedia(ctx context.Context, arg repository.GetCatMediaByCatAndMediaParams) (repository.CatMedium, error) {
	return f.catMediaRow, f.catMediaErr
}

func (f fakeCatsLister) SetCatCoverPhoto(ctx context.Context, arg repository.SetCatCoverPhotoParams) error {
	return f.setCoverErr
}

func (f fakeCatsLister) CountCatMedia(ctx context.Context, catID pgtype.UUID) (int64, error) {
	return f.mediaCount, f.mediaCountErr
}

func (f fakeCatsLister) ListCatMedia(ctx context.Context, catID pgtype.UUID) ([]repository.ListCatMediaRow, error) {
	return f.mediaRows, f.mediaErr
}

func (f fakeCatsLister) ListCatsInBounds(ctx context.Context, arg repository.ListCatsInBoundsParams) ([]repository.ListCatsInBoundsRow, error) {
	return f.rows, nil
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
	return f.distanceRows, f.distanceErr
}

func (f fakeCatsLister) ListActiveNeedsHelpCatsByDistance(ctx context.Context, arg repository.ListActiveNeedsHelpCatsByDistanceParams) ([]repository.ListActiveNeedsHelpCatsByDistanceRow, error) {
	return f.needsHelpDistanceRows, f.needsHelpDistanceErr
}

// fakeDeviceResolver stands in for service.DevicesService in tests that
// exercise CreateUpdate through the real OptionalDeviceToken middleware
// rather than by injecting a device identity directly into context.
type fakeDeviceResolver struct {
	identity service.DeviceIdentity
	err      error
}

func (f fakeDeviceResolver) ResolveToken(_ context.Context, _ string) (service.DeviceIdentity, error) {
	return f.identity, f.err
}

// fakeAccessValidator stands in for service.SessionService in tests that
// exercise CreateUpdate/Follow/Unfollow/ListFollows through the real
// RequireBearer middleware rather than by injecting a user identity
// directly into context (issue #65).
type fakeAccessValidator struct {
	userID string
	err    error
}

func (f fakeAccessValidator) ValidateAccessToken(_ string) (string, error) {
	return f.userID, f.err
}

// defaultTestUserID is the account id fakeAccessValidator resolves to by
// default in routerFor, so most CreateUpdate tests don't need to thread
// their own validator through just to satisfy RequireBearer.
var defaultTestUserID = uuid.NewString()

// routerFor wires h behind a real chi router so chi.URLParam (used by
// Detail/UpdateHistory/CreateUpdate) is populated the same way it is in
// production. The POST route runs behind RequireBearer + OptionalDeviceToken,
// exactly as server.NewRouter wires it (issue #65): a request without a
// valid Authorization: Bearer never reaches the handler, but a missing or
// invalid X-Device-Token never blocks it either.
func routerFor(h *CatsHandler) http.Handler {
	return routerForWithResolver(h,
		fakeDeviceResolver{identity: service.DeviceIdentity{DeviceID: uuid.NewString()}},
		fakeAccessValidator{userID: defaultTestUserID},
	)
}

func routerForWithResolver(h *CatsHandler, resolver DeviceTokenResolver, validator AccessTokenValidator) http.Handler {
	r := chi.NewRouter()
	r.With(OptionalBearer(validator)).Get("/v1/cats/{cat_id}", h.Detail)
	r.Get("/v1/cats/{cat_id}/media", h.Media)
	r.With(RequireBearer(validator)).Patch("/v1/cats/{cat_id}/cover", h.SetCover)
	r.With(OptionalBearer(validator)).Get("/v1/cats/{cat_id}/updates", h.UpdateHistory)
	r.With(RequireBearer(validator), OptionalDeviceToken(resolver)).Post("/v1/cats/{cat_id}/updates", h.CreateUpdate)
	r.With(RequireBearer(validator), OptionalDeviceToken(resolver)).Post("/v1/cats/{cat_id}/needs-help", h.CreateNeedsHelp)
	r.With(RequireBearer(validator)).Patch("/v1/cats/{cat_id}/updates/{update_id}", h.CorrectUpdate)
	r.With(RequireBearer(validator)).Delete("/v1/cats/{cat_id}/updates/{update_id}", h.DeleteUpdate)
	return r
}

// withDeviceToken sets the header OptionalDeviceToken reads, so requests
// through routerFor associate with the fake device it was built with.
func withDeviceToken(req *http.Request) *http.Request {
	req.Header.Set("X-Device-Token", "test-token")
	return req
}

// withBearerToken sets the header RequireBearer reads, so requests through
// routerFor authenticate as the fake account it was built with.
func withBearerToken(req *http.Request) *http.Request {
	req.Header.Set("Authorization", "Bearer test-bearer-token")
	return req
}

func TestCatsHandler_Nearby(t *testing.T) {
	id := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{rows: []repository.ListCatsInBoundsRow{
		{
			ID:        id,
			Name:      pgtype.Text{String: "tekir", Valid: true},
			PhotoUrl:  "https://placecats.com/millie/300/200",
			Lng:       28.9744,
			Lat:       41.0256,
			AreaLabel: pgtype.Text{String: "Galata Kulesi çevresi, Beyoğlu", Valid: true},
		},
	}}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats?bbox=28,41,29,42", nil)
	h.Nearby(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var body []catMarkerResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body) != 1 {
		t.Fatalf("expected 1 marker, got %d", len(body))
	}
	if body[0].PrimaryPhoto != "https://placecats.com/millie/300/200" {
		t.Errorf("unexpected primary_photo: %q", body[0].PrimaryPhoto)
	}
	if body[0].Name != "tekir" {
		t.Errorf("unexpected name: %q", body[0].Name)
	}
	if body[0].AreaLabel == nil || *body[0].AreaLabel != "Galata Kulesi çevresi, Beyoğlu" {
		t.Errorf("unexpected area_label: %v", body[0].AreaLabel)
	}
}

func TestCatsHandler_Nearby_MissingBbox(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats", nil)
	h.Nearby(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestCatsHandler_Nearby_MalformedBbox(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats?bbox=not,a,valid,bbox", nil)
	h.Nearby(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestCatsHandler_Nearby_InvalidBoundsOrder(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats?bbox=29,41,28,42", nil)
	h.Nearby(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestCatsHandler_Nearby_NanAndInfiniteBounds(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)

	cases := []string{"NaN,41,29,42", "28,41,29,Inf", "-Inf,41,29,42"}
	for _, bbox := range cases {
		t.Run(bbox, func(t *testing.T) {
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodGet, "/v1/cats?bbox="+bbox, nil)
			h.Nearby(rec, req)

			if rec.Code != http.StatusBadRequest {
				t.Fatalf("expected 400, got %d", rec.Code)
			}
		})
	}
}

func TestCatsHandler_Detail(t *testing.T) {
	id := uuid.New()
	created := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		catRow: repository.GetCatByIDRow{
			ID:        pgtype.UUID{Bytes: id, Valid: true},
			Name:      pgtype.Text{String: "tekir", Valid: true},
			Lng:       28.9744,
			Lat:       41.0256,
			AreaLabel: pgtype.Text{String: "Galata Kulesi çevresi, Beyoğlu", Valid: true},
			PhotoUrl:  "https://placecats.com/millie/300/200",
			CreatedAt: pgtype.Timestamptz{Time: created, Valid: true},
		},
	}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+id.String(), nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var body catDetailResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.Name != "tekir" {
		t.Errorf("unexpected name: %q", body.Name)
	}
	if body.PrimaryPhoto == nil || *body.PrimaryPhoto != "https://placecats.com/millie/300/200" {
		t.Errorf("unexpected primary_photo: %v", body.PrimaryPhoto)
	}
	if body.AreaLabel == nil || *body.AreaLabel != "Galata Kulesi çevresi, Beyoğlu" {
		t.Errorf("unexpected area_label: %v", body.AreaLabel)
	}
}

// TestCatsHandler_Detail_IsOwner proves GET /v1/cats/{cat_id} surfaces
// is_owner for the cat's own owner's authenticated read, and never for a
// guest read (issue #156) — OptionalBearer resolves the caller without
// requiring one.
func TestCatsHandler_Detail_IsOwner(t *testing.T) {
	id := uuid.New()
	ownerID := uuid.MustParse(defaultTestUserID)
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		catRow: repository.GetCatByIDRow{
			ID:              pgtype.UUID{Bytes: id, Valid: true},
			Name:            pgtype.Text{String: "tekir", Valid: true},
			CreatedByUserID: pgtype.UUID{Bytes: ownerID, Valid: true},
		},
	}), testMaxUploadBytes)

	t.Run("owner's own authenticated read", func(t *testing.T) {
		rec := httptest.NewRecorder()
		req := withBearerToken(httptest.NewRequest(http.MethodGet, "/v1/cats/"+id.String(), nil))
		routerFor(h).ServeHTTP(rec, req)

		var body catDetailResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatalf("decode response: %v", err)
		}
		if !body.IsOwner {
			t.Error("expected is_owner true for the cat's own owner")
		}
	})

	t.Run("guest read", func(t *testing.T) {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+id.String(), nil)
		routerFor(h).ServeHTTP(rec, req)

		var body catDetailResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatalf("decode response: %v", err)
		}
		if body.IsOwner {
			t.Error("expected is_owner false for a guest read")
		}
	})
}

// TestCatsHandler_Detail_NoTraitsField proves the cat-detail response never
// carries a "traits" key (issue #42: permanent cat traits are dormant
// legacy storage, no longer part of the mvp surface).
func TestCatsHandler_Detail_NoTraitsField(t *testing.T) {
	id := uuid.New()
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		catRow: repository.GetCatByIDRow{
			ID:   pgtype.UUID{Bytes: id, Valid: true},
			Name: pgtype.Text{String: "tekir", Valid: true},
		},
	}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+id.String(), nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var raw map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if _, ok := raw["traits"]; ok {
		t.Errorf("expected no traits key in response, got %s", rec.Body.String())
	}
}

// TestCatsHandler_Detail_ThreeStatTimestamps covers issue #121's three-stat
// header fields on the wire: last_seen_at/last_fed_at present independently,
// last_water_at absent (null) rather than falling back to another status.
func TestCatsHandler_Detail_ThreeStatTimestamps(t *testing.T) {
	id := uuid.New()
	seenAt := time.Date(2026, 1, 3, 8, 0, 0, 0, time.UTC)
	fedAt := time.Date(2026, 1, 2, 9, 0, 0, 0, time.UTC)
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		catRow: repository.GetCatByIDRow{
			ID:          pgtype.UUID{Bytes: id, Valid: true},
			Name:        pgtype.Text{String: "tekir", Valid: true},
			LastSeenAt:  pgtype.Timestamptz{Time: seenAt, Valid: true},
			LastFedAt:   pgtype.Timestamptz{Time: fedAt, Valid: true},
			LastWaterAt: pgtype.Timestamptz{},
		},
	}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+id.String(), nil)
	routerFor(h).ServeHTTP(rec, req)

	var body catDetailResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.LastSeenAt == nil || !body.LastSeenAt.Equal(seenAt) {
		t.Errorf("expected last_seen_at %v, got %v", seenAt, body.LastSeenAt)
	}
	if body.LastFedAt == nil || !body.LastFedAt.Equal(fedAt) {
		t.Errorf("expected last_fed_at %v, got %v", fedAt, body.LastFedAt)
	}
	if body.LastWaterAt != nil {
		t.Errorf("expected null last_water_at, got %v", body.LastWaterAt)
	}
}

// TestCatsHandler_Detail_MediaCount covers issue #121's cover
// photo-counter parity gap on the wire.
func TestCatsHandler_Detail_MediaCount(t *testing.T) {
	id := uuid.New()
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		catRow:     repository.GetCatByIDRow{ID: pgtype.UUID{Bytes: id, Valid: true}, Name: pgtype.Text{String: "tekir", Valid: true}},
		mediaCount: 2,
	}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+id.String(), nil)
	routerFor(h).ServeHTTP(rec, req)

	var body catDetailResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.MediaCount != 2 {
		t.Errorf("expected media_count 2, got %d", body.MediaCount)
	}
}

func TestCatsHandler_Media(t *testing.T) {
	id := uuid.New()
	coverID := uuid.New()
	created := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		exists: true,
		mediaRows: []repository.ListCatMediaRow{
			{ID: pgtype.UUID{Bytes: coverID, Valid: true}, Url: "https://placecats.com/millie/300/200", ContentType: "image/jpeg", CreatedAt: pgtype.Timestamptz{Time: created, Valid: true}, IsCover: true, UploaderDisplayName: pgtype.Text{String: "asli", Valid: true}},
		},
	}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+id.String()+"/media", nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var body []catMediaResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body) != 1 {
		t.Fatalf("expected 1 item, got %d", len(body))
	}
	if body[0].ID != coverID.String() {
		t.Errorf("unexpected id: %q", body[0].ID)
	}
	if body[0].URL != "https://placecats.com/millie/300/200" {
		t.Errorf("unexpected url: %q", body[0].URL)
	}
	if body[0].MediaContentType != "image/jpeg" {
		t.Errorf("unexpected media_content_type: %q", body[0].MediaContentType)
	}
	if !body[0].IsCover {
		t.Error("expected is_cover true")
	}
	if body[0].UploaderDisplayName == nil || *body[0].UploaderDisplayName != "asli" {
		t.Errorf("expected uploader_display_name %q, got %v", "asli", body[0].UploaderDisplayName)
	}
}

// TestCatsHandler_Media_UploaderDisplayName_Null covers issue #154's
// media-attribution parity gap on the wire: a media entry whose uploader
// never set a display name serializes it as null rather than an invented
// name.
func TestCatsHandler_Media_UploaderDisplayName_Null(t *testing.T) {
	id := uuid.New()
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		exists: true,
		mediaRows: []repository.ListCatMediaRow{
			{ID: pgtype.UUID{Bytes: id, Valid: true}, Url: "https://placecats.com/millie/300/200"},
		},
	}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+id.String()+"/media", nil)
	routerFor(h).ServeHTTP(rec, req)

	var body []catMediaResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body) != 1 {
		t.Fatalf("expected 1 item, got %d", len(body))
	}
	if body[0].UploaderDisplayName != nil {
		t.Errorf("expected null uploader_display_name, got %v", *body[0].UploaderDisplayName)
	}
}

func TestCatsHandler_Media_NotFound(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: false}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String()+"/media", nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_Detail_NotFound(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{catErr: pgx.ErrNoRows}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String(), nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_Detail_InvalidID(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/not-a-uuid", nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestCatsHandler_Detail_RepositoryFailure(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{catErr: errors.New("connection refused")}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String(), nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_UpdateHistory(t *testing.T) {
	id := uuid.New()
	created := time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC)
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		exists: true,
		updateRows: []repository.ListCatUpdatesRow{
			{
				ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
				CreatedAt: pgtype.Timestamptz{Time: created, Valid: true},
				Seq:       pgtype.Int8{Int64: 1, Valid: true},
				Statuses:  []string{"seen", "fed"},
			},
		},
	}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+id.String()+"/updates", nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var body updateHistoryResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body.Items) != 1 {
		t.Fatalf("expected 1 item, got %d", len(body.Items))
	}
	if body.NextCursor != nil {
		t.Errorf("expected nil next_cursor, got %v", *body.NextCursor)
	}
	if len(body.Items[0].Statuses) != 2 {
		t.Errorf("unexpected statuses: %v", body.Items[0].Statuses)
	}
	if body.Items[0].Comment != nil {
		t.Errorf("expected nil comment, got %v", *body.Items[0].Comment)
	}
}

// TestCatsHandler_UpdateHistory_AuthorDisplayName covers issue #121's
// timeline-avatar parity gap on the wire: an entry with an author display
// name surfaces it verbatim, an authorless entry serializes it as null
// rather than an invented name.
func TestCatsHandler_UpdateHistory_AuthorDisplayName(t *testing.T) {
	created := time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC)
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		exists: true,
		updateRows: []repository.ListCatUpdatesRow{
			{
				ID:                pgtype.UUID{Bytes: uuid.New(), Valid: true},
				CreatedAt:         pgtype.Timestamptz{Time: created, Valid: true},
				Seq:               pgtype.Int8{Int64: 2, Valid: true},
				Statuses:          []string{"seen"},
				AuthorUserID:      pgtype.UUID{Bytes: uuid.New(), Valid: true},
				AuthorDisplayName: pgtype.Text{String: "asli", Valid: true},
			},
			{
				ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
				CreatedAt: pgtype.Timestamptz{Time: created.Add(-time.Hour), Valid: true},
				Seq:       pgtype.Int8{Int64: 1, Valid: true},
				Statuses:  []string{"fed"},
			},
		},
	}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String()+"/updates", nil)
	routerFor(h).ServeHTTP(rec, req)

	var body updateHistoryResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body.Items) != 2 {
		t.Fatalf("expected 2 items, got %d", len(body.Items))
	}
	if body.Items[0].AuthorDisplayName == nil || *body.Items[0].AuthorDisplayName != "asli" {
		t.Errorf("expected author_display_name %q, got %v", "asli", body.Items[0].AuthorDisplayName)
	}
	if body.Items[1].AuthorDisplayName != nil {
		t.Errorf("expected null author_display_name for authorless entry, got %v", *body.Items[1].AuthorDisplayName)
	}
}

// TestCatsHandler_UpdateHistory_PhotoURL covers issue #121's
// timeline-thumbnail parity gap on the wire.
func TestCatsHandler_UpdateHistory_PhotoURL(t *testing.T) {
	created := time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC)
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		exists: true,
		updateRows: []repository.ListCatUpdatesRow{
			{
				ID:               pgtype.UUID{Bytes: uuid.New(), Valid: true},
				CreatedAt:        pgtype.Timestamptz{Time: created, Valid: true},
				Seq:              pgtype.Int8{Int64: 1, Valid: true},
				Statuses:         []string{"seen"},
				PhotoUrl:         pgtype.Text{String: "https://placecats.com/millie/300/200", Valid: true},
				MediaContentType: pgtype.Text{String: "image/jpeg", Valid: true},
			},
		},
	}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String()+"/updates", nil)
	routerFor(h).ServeHTTP(rec, req)

	var body updateHistoryResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body.Items) != 1 {
		t.Fatalf("expected 1 item, got %d", len(body.Items))
	}
	if body.Items[0].PhotoURL == nil || *body.Items[0].PhotoURL != "https://placecats.com/millie/300/200" {
		t.Errorf("expected photo_url set, got %v", body.Items[0].PhotoURL)
	}
	if body.Items[0].MediaContentType == nil || *body.Items[0].MediaContentType != "image/jpeg" {
		t.Errorf("expected media_content_type set, got %v", body.Items[0].MediaContentType)
	}
}

func TestCatsHandler_UpdateHistory_NotFound(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: false}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String()+"/updates", nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_UpdateHistory_InvalidLimit(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String()+"/updates?limit=not-a-number", nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_UpdateHistory_LimitOutOfRange(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String()+"/updates?limit=1000", nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_UpdateHistory_RepositoryFailure(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true, updatesErr: errors.New("connection refused")}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String()+"/updates", nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_Nearby_ActiveAlertMetadata(t *testing.T) {
	fixedNow := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	id := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{rows: []repository.ListCatsInBoundsRow{
		{
			ID:                 id,
			Name:               pgtype.Text{String: "duman", Valid: true},
			NeedsHelpCategory:  pgtype.Text{String: "injured_or_sick", Valid: true},
			NeedsHelpCreatedAt: pgtype.Timestamptz{Time: fixedNow.Add(-time.Hour), Valid: true},
			NeedsHelpExpiresAt: pgtype.Timestamptz{Time: fixedNow.Add(71 * time.Hour), Valid: true},
		},
	}}, service.WithClock(func() time.Time { return fixedNow })), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats?bbox=28,41,29,42", nil)
	h.Nearby(rec, req)

	var body []catMarkerResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body[0].ActiveAlert == nil {
		t.Fatal("expected active_alert to be present")
	}
	if body[0].ActiveAlert.Category != "injured_or_sick" {
		t.Errorf("unexpected category: %q", body[0].ActiveAlert.Category)
	}
	if body[0].ActiveAlert.CategoryLabel != "yaralı / hasta" {
		t.Errorf("unexpected category_label: %q", body[0].ActiveAlert.CategoryLabel)
	}
}

func TestCatsHandler_Nearby_NoActiveAlertIsNull(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{rows: []repository.ListCatsInBoundsRow{
		{ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}, Name: pgtype.Text{String: "tekir", Valid: true}},
	}}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats?bbox=28,41,29,42", nil)
	h.Nearby(rec, req)

	var body []catMarkerResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body[0].ActiveAlert != nil {
		t.Errorf("expected null active_alert, got %+v", body[0].ActiveAlert)
	}
}

func TestCatsHandler_Detail_ActiveAlertMetadata(t *testing.T) {
	fixedNow := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	id := uuid.New()
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		catRow: repository.GetCatByIDRow{
			ID:                 pgtype.UUID{Bytes: id, Valid: true},
			Name:               pgtype.Text{String: "kadıköy kedisi", Valid: true},
			NeedsHelpCategory:  pgtype.Text{String: "trapped", Valid: true},
			NeedsHelpCreatedAt: pgtype.Timestamptz{Time: fixedNow.Add(-71 * time.Hour), Valid: true},
			NeedsHelpExpiresAt: pgtype.Timestamptz{Time: fixedNow.Add(time.Hour), Valid: true},
		},
	}, service.WithClock(func() time.Time { return fixedNow })), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+id.String(), nil)
	routerFor(h).ServeHTTP(rec, req)

	var body catDetailResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.ActiveAlert == nil {
		t.Fatal("expected active_alert to be present")
	}
	if body.ActiveAlert.Category != "trapped" {
		t.Errorf("unexpected category: %q", body.ActiveAlert.Category)
	}
	if body.ActiveAlert.CategoryLabel != "mahsur kalmış" {
		t.Errorf("unexpected category_label: %q", body.ActiveAlert.CategoryLabel)
	}
}

func TestCatsHandler_UpdateHistory_NeedsHelpEntry(t *testing.T) {
	fixedNow := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		exists: true,
		updateRows: []repository.ListCatUpdatesRow{
			{
				ID:                 pgtype.UUID{Bytes: uuid.New(), Valid: true},
				Kind:               "needs_help",
				NeedsHelp:          true,
				CreatedAt:          pgtype.Timestamptz{Time: fixedNow.Add(-100 * time.Hour), Valid: true},
				Seq:                pgtype.Int8{Int64: 1, Valid: true},
				NeedsHelpCategory:  pgtype.Text{String: "water_needed", Valid: true},
				NeedsHelpExpiresAt: pgtype.Timestamptz{Time: fixedNow.Add(-28 * time.Hour), Valid: true},
				Statuses:           []string{},
			},
		},
	}, service.WithClock(func() time.Time { return fixedNow })), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String()+"/updates", nil)
	routerFor(h).ServeHTTP(rec, req)

	var body updateHistoryResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	item := body.Items[0]
	if item.Kind != "needs_help" {
		t.Errorf("expected kind needs_help, got %q", item.Kind)
	}
	if item.NeedsHelpCategory == nil || *item.NeedsHelpCategory != "water_needed" {
		t.Errorf("unexpected needs_help_category: %v", item.NeedsHelpCategory)
	}
	// this fixture's expiry is well in the past — expired entries must
	// remain in history, but never with active emphasis.
	if item.NeedsHelpActive == nil || *item.NeedsHelpActive {
		t.Errorf("expected an expired (inactive) needs-help entry, got %v", item.NeedsHelpActive)
	}
}

// TestCatsHandler_GuestReads_NoAuthHeadersRequired is an explicit regression
// for issue #65's "guest browse and update-history reads remain unchanged"
// requirement: Detail and UpdateHistory must stay reachable with zero
// headers at all — no X-Device-Token, no Authorization — exactly as before
// this slice moved follow/CreateUpdate onto bearer auth.
func TestCatsHandler_GuestReads_NoAuthHeadersRequired(t *testing.T) {
	catID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		catRow: repository.GetCatByIDRow{ID: catID, Name: pgtype.Text{String: "tekir", Valid: true}},
		exists: true,
	}), testMaxUploadBytes)
	r := routerFor(h)

	detailRec := httptest.NewRecorder()
	detailReq := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.UUID(catID.Bytes).String(), nil)
	r.ServeHTTP(detailRec, detailReq)
	if detailRec.Code != http.StatusOK {
		t.Fatalf("expected guest Detail to succeed with no auth headers, got %d: %s", detailRec.Code, detailRec.Body.String())
	}

	historyRec := httptest.NewRecorder()
	historyReq := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.UUID(catID.Bytes).String()+"/updates", nil)
	r.ServeHTTP(historyRec, historyReq)
	if historyRec.Code != http.StatusOK {
		t.Fatalf("expected guest UpdateHistory to succeed with no auth headers, got %d: %s", historyRec.Code, historyRec.Body.String())
	}
}

// ── CreateUpdate (POST /v1/cats/{cat_id}/updates, issue #36) ─────────────────

func newCreateUpdateRequest(catID, body string) *http.Request {
	req := httptest.NewRequest(http.MethodPost, "/v1/cats/"+catID+"/updates", strings.NewReader(body))
	return withBearerToken(withDeviceToken(req))
}

func newCreateNeedsHelpRequest(catID, body string) *http.Request {
	req := httptest.NewRequest(http.MethodPost, "/v1/cats/"+catID+"/needs-help", strings.NewReader(body))
	return withBearerToken(withDeviceToken(req))
}

func TestCatsHandler_CreateUpdate_Success(t *testing.T) {
	catID := uuid.New()
	deviceID := uuid.New()
	userID := uuid.New()
	created := time.Date(2026, 1, 3, 10, 0, 0, 0, time.UTC)
	returnedID := uuid.New()
	var captured repository.CreateOrdinaryUpdateParams
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		exists:    true,
		createRow: repository.CreateUpdateRow{ID: pgtype.UUID{Bytes: returnedID, Valid: true}},
		captured:  &captured,
		userRow:   repository.User{DisplayName: pgtype.Text{String: "asli", Valid: true}},
	}, service.WithClock(func() time.Time { return created })), testMaxUploadBytes)

	r := routerForWithResolver(h,
		fakeDeviceResolver{identity: service.DeviceIdentity{DeviceID: deviceID.String()}},
		fakeAccessValidator{userID: userID.String()},
	)
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(catID.String(), `{"statuses":["seen"]}`)
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}

	var body updateResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.ID != returnedID.String() {
		t.Errorf("unexpected id: %q", body.ID)
	}
	if body.Kind != "ordinary" {
		t.Errorf("expected kind ordinary, got %q", body.Kind)
	}
	if len(body.Statuses) != 1 || body.Statuses[0] != "seen" {
		t.Errorf("unexpected statuses: %v", body.Statuses)
	}
	if body.Comment != nil {
		t.Errorf("expected nil comment, got %v", *body.Comment)
	}
	if !body.CreatedAt.Equal(created) {
		t.Errorf("unexpected created_at: %v", body.CreatedAt)
	}
	if body.AuthorDisplayName == nil || *body.AuthorDisplayName != "asli" {
		t.Errorf("expected author_display_name %q, got %v", "asli", body.AuthorDisplayName)
	}

	if uuid.UUID(captured.CatID.Bytes).String() != catID.String() {
		t.Errorf("unexpected captured cat id: %v", captured.CatID)
	}
	if uuid.UUID(captured.AuthorDeviceID.Bytes).String() != deviceID.String() {
		t.Errorf("unexpected captured author device id: %v", captured.AuthorDeviceID)
	}
	if uuid.UUID(captured.AuthorUserID.Bytes).String() != userID.String() {
		t.Errorf("unexpected captured author user id: %v", captured.AuthorUserID)
	}
	if captured.Comment.Valid {
		t.Errorf("expected no comment captured, got %v", captured.Comment)
	}
	if len(captured.Statuses) != 1 || captured.Statuses[0] != "seen" {
		t.Errorf("unexpected captured statuses: %v", captured.Statuses)
	}
}

func TestCatsHandler_CreateUpdate_WithMediaID(t *testing.T) {
	catID := uuid.New()
	userID := uuid.New()
	mediaID := uuid.New()
	returnedID := uuid.New()
	var captured repository.CreateOrdinaryUpdateParams
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		exists:    true,
		createRow: repository.CreateUpdateRow{ID: pgtype.UUID{Bytes: returnedID, Valid: true}},
		captured:  &captured,
		getMediaRow: repository.Medium{
			ID:               pgtype.UUID{Bytes: mediaID, Valid: true},
			Url:              "https://media.example/cat.jpg",
			UploadedByUserID: pgtype.UUID{Bytes: userID, Valid: true},
		},
	}), testMaxUploadBytes)

	r := routerForWithResolver(h,
		fakeDeviceResolver{identity: service.DeviceIdentity{DeviceID: uuid.New().String()}},
		fakeAccessValidator{userID: userID.String()},
	)
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(catID.String(), `{"statuses":["seen"],"media_id":"`+mediaID.String()+`"}`)
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}

	var body updateResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.PhotoURL == nil || *body.PhotoURL != "https://media.example/cat.jpg" {
		t.Errorf("expected the response to carry the attached photo's url, got %v", body.PhotoURL)
	}
	if uuid.UUID(captured.MediaID.Bytes).String() != mediaID.String() || !captured.MediaID.Valid {
		t.Errorf("expected the repository write to carry the media id, got %v", captured.MediaID)
	}
}

func TestCatsHandler_CreateUpdate_UnknownMediaIDRejected(t *testing.T) {
	catID := uuid.New()
	userID := uuid.New()
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		exists:      true,
		getMediaErr: pgx.ErrNoRows,
	}), testMaxUploadBytes)

	r := routerForWithResolver(h,
		fakeDeviceResolver{identity: service.DeviceIdentity{DeviceID: uuid.New().String()}},
		fakeAccessValidator{userID: userID.String()},
	)
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(catID.String(), `{"statuses":["seen"],"media_id":"`+uuid.New().String()+`"}`)
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateUpdate_IdempotencyKeyHeaderPassedThrough(t *testing.T) {
	catID := uuid.New()
	returnedID := uuid.New()
	var captured repository.CreateOrdinaryUpdateParams
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		exists:               true,
		createRow:            repository.CreateUpdateRow{ID: pgtype.UUID{Bytes: returnedID, Valid: true}},
		captured:             &captured,
		updateIdempotencyErr: pgx.ErrNoRows,
	}), testMaxUploadBytes)

	r := routerForWithResolver(h,
		fakeDeviceResolver{identity: service.DeviceIdentity{DeviceID: uuid.New().String()}},
		fakeAccessValidator{userID: uuid.New().String()},
	)
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(catID.String(), `{"statuses":["seen"]}`)
	req.Header.Set("Idempotency-Key", "seen-tap-key")
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	if !captured.IdempotencyKey.Valid || captured.IdempotencyKey.String != "seen-tap-key" {
		t.Errorf("expected the Idempotency-Key header to be passed through, got %v", captured.IdempotencyKey)
	}
}

func TestCatsHandler_CreateUpdate_BlankIdempotencyKeyHeaderIgnored(t *testing.T) {
	catID := uuid.New()
	returnedID := uuid.New()
	var captured repository.CreateOrdinaryUpdateParams
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		exists:    true,
		createRow: repository.CreateUpdateRow{ID: pgtype.UUID{Bytes: returnedID, Valid: true}},
		captured:  &captured,
	}), testMaxUploadBytes)

	r := routerForWithResolver(h,
		fakeDeviceResolver{identity: service.DeviceIdentity{DeviceID: uuid.New().String()}},
		fakeAccessValidator{userID: uuid.New().String()},
	)
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(catID.String(), `{"statuses":["seen"]}`)
	req.Header.Set("Idempotency-Key", "   ")
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	if captured.IdempotencyKey.Valid {
		t.Errorf("expected a blank Idempotency-Key header to be ignored, got %v", captured.IdempotencyKey)
	}
}

func TestCatsHandler_CreateUpdate_WithCommentAndMultipleStatuses(t *testing.T) {
	returnedID := uuid.New()
	var captured repository.CreateOrdinaryUpdateParams
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		exists:    true,
		createRow: repository.CreateUpdateRow{ID: pgtype.UUID{Bytes: returnedID, Valid: true}},
		captured:  &captured,
	}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{"statuses":["fed","seen"],"comment":"mama verildi"}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}

	var body updateResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body.Statuses) != 2 {
		t.Errorf("unexpected statuses: %v", body.Statuses)
	}
	if body.Comment == nil || *body.Comment != "mama verildi" {
		t.Errorf("unexpected comment: %v", body.Comment)
	}
	if !captured.Comment.Valid || captured.Comment.String != "mama verildi" {
		t.Errorf("unexpected captured comment: %v", captured.Comment)
	}
}

func TestCatsHandler_CreateUpdate_EmptyStatuses(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{"statuses":[]}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateUpdate_MissingStatuses(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateUpdate_CommentOnly(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{"comment":"mama verildi"}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateUpdate_UnknownStatusValue(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{"statuses":["flying"]}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateUpdate_DuplicateStatus(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{"statuses":["seen","seen"]}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateUpdate_MalformedJSON(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{"statuses":`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

// TestCatsHandler_CreateUpdate_RejectsUnknownFields covers issue #36's
// requirement that kind, media, needs-help, timestamp, sequence, and author
// fields are never accepted from the caller — DisallowUnknownFields rejects
// the whole request the moment any field outside {statuses, comment} shows
// up, rather than silently ignoring it.
func TestCatsHandler_CreateUpdate_RejectsUnknownFields(t *testing.T) {
	bodies := map[string]string{
		"kind":                  `{"statuses":["seen"],"kind":"needs_help"}`,
		"media":                 `{"statuses":["seen"],"media":["https://example.com/a.jpg"]}`,
		"needs_help_category":   `{"statuses":["seen"],"needs_help_category":"injured_or_sick"}`,
		"needs_help_expires_at": `{"statuses":["seen"],"needs_help_expires_at":"2026-01-01T00:00:00Z"}`,
		"timestamp":             `{"statuses":["seen"],"timestamp":"2026-01-01T00:00:00Z"}`,
		"created_at":            `{"statuses":["seen"],"created_at":"2026-01-01T00:00:00Z"}`,
		"sequence":              `{"statuses":["seen"],"sequence":5}`,
		"seq":                   `{"statuses":["seen"],"seq":5}`,
		"author":                `{"statuses":["seen"],"author":"someone"}`,
		"author_device_id":      `{"statuses":["seen"],"author_device_id":"` + uuid.New().String() + `"}`,
	}

	for name, body := range bodies {
		t.Run(name, func(t *testing.T) {
			h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)
			rec := httptest.NewRecorder()
			req := newCreateUpdateRequest(uuid.New().String(), body)
			routerFor(h).ServeHTTP(rec, req)

			if rec.Code != http.StatusBadRequest {
				t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
			}
		})
	}
}

func TestCatsHandler_CreateUpdate_CatNotFound(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: false}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{"statuses":["seen"]}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateUpdate_InvalidCatID(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest("not-a-uuid", `{"statuses":["seen"]}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateUpdate_RepositoryFailure(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true, createErr: errors.New("connection refused")}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{"statuses":["seen"]}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d: %s", rec.Code, rec.Body.String())
	}
}

// TestCatsHandler_CreateUpdate_RequiresBearer proves the route is actually
// gated by RequireBearer in the same way server.NewRouter wires it (issue
// #65); the exhaustive missing/unknown/expired-token matrix lives in
// bearer_auth_test.go against the middleware directly.
func TestCatsHandler_CreateUpdate_RequiresBearer(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true}), testMaxUploadBytes)
	r := routerFor(h)

	rec := httptest.NewRecorder()
	req := withDeviceToken(httptest.NewRequest(http.MethodPost, "/v1/cats/"+uuid.New().String()+"/updates", strings.NewReader(`{"statuses":["seen"]}`)))
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateUpdate_InvalidBearer(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true}), testMaxUploadBytes)
	r := routerForWithResolver(h,
		fakeDeviceResolver{identity: service.DeviceIdentity{DeviceID: uuid.NewString()}},
		fakeAccessValidator{err: service.ErrSessionInvalid},
	)

	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{"statuses":["seen"]}`)
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", rec.Code, rec.Body.String())
	}
}

// TestCatsHandler_CreateUpdate_DeviceTokenOptional proves a request with a
// valid bearer token but no X-Device-Token at all still succeeds (issue
// #65: device association is optional, never required for authorization).
func TestCatsHandler_CreateUpdate_DeviceTokenOptional(t *testing.T) {
	var captured repository.CreateOrdinaryUpdateParams
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true, captured: &captured}), testMaxUploadBytes)
	r := routerFor(h)

	rec := httptest.NewRecorder()
	req := withBearerToken(httptest.NewRequest(http.MethodPost, "/v1/cats/"+uuid.New().String()+"/updates", strings.NewReader(`{"statuses":["seen"]}`)))
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	if captured.AuthorDeviceID.Valid {
		t.Errorf("expected no device id captured, got %v", captured.AuthorDeviceID)
	}
	if !captured.AuthorUserID.Valid {
		t.Error("expected author user id to still be captured")
	}
}

// TestCatsHandler_CreateUpdate_UnknownDeviceToken_StillSucceeds proves an
// unresolvable X-Device-Token never blocks the request (issue #65:
// OptionalDeviceToken never rejects) — only the bearer session determines
// authorization.
func TestCatsHandler_CreateUpdate_UnknownDeviceToken_StillSucceeds(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true}), testMaxUploadBytes)
	r := routerForWithResolver(h, fakeDeviceResolver{err: service.ErrDeviceNotFound}, fakeAccessValidator{userID: defaultTestUserID})

	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{"statuses":["seen"]}`)
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateNeedsHelp_Success(t *testing.T) {
	catID := uuid.New()
	deviceID := uuid.New()
	userID := uuid.New()
	created := time.Date(2026, 3, 1, 10, 0, 0, 0, time.UTC)
	returnedID := uuid.New()
	var captured repository.CreateOrdinaryUpdateParams
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		exists:             true,
		createNeedsHelpRow: repository.CreateUpdateRow{ID: pgtype.UUID{Bytes: returnedID, Valid: true}},
		capturedNeedsHelp:  &captured,
		userRow:            repository.User{DisplayName: pgtype.Text{String: "asli", Valid: true}},
	}, service.WithClock(func() time.Time { return created })), testMaxUploadBytes)

	r := routerForWithResolver(h,
		fakeDeviceResolver{identity: service.DeviceIdentity{DeviceID: deviceID.String()}},
		fakeAccessValidator{userID: userID.String()},
	)
	rec := httptest.NewRecorder()
	req := newCreateNeedsHelpRequest(catID.String(), `{"category":"injured_or_sick","comment":"sağ arka ayağını basamıyor"}`)
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}

	var body updateResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.ID != returnedID.String() {
		t.Errorf("unexpected id: %q", body.ID)
	}
	if body.Kind != "needs_help" {
		t.Errorf("expected kind needs_help, got %q", body.Kind)
	}
	if body.NeedsHelpCategory == nil || *body.NeedsHelpCategory != "injured_or_sick" {
		t.Errorf("unexpected needs_help_category: %v", body.NeedsHelpCategory)
	}
	if body.NeedsHelpActive == nil || !*body.NeedsHelpActive {
		t.Errorf("expected needs_help_active true, got %v", body.NeedsHelpActive)
	}
	if body.Comment == nil || *body.Comment != "sağ arka ayağını basamıyor" {
		t.Errorf("unexpected comment: %v", body.Comment)
	}
	if body.AuthorDisplayName == nil || *body.AuthorDisplayName != "asli" {
		t.Errorf("expected author_display_name %q, got %v", "asli", body.AuthorDisplayName)
	}

	if uuid.UUID(captured.CatID.Bytes).String() != catID.String() {
		t.Errorf("unexpected captured cat id: %v", captured.CatID)
	}
	if uuid.UUID(captured.AuthorDeviceID.Bytes).String() != deviceID.String() {
		t.Errorf("unexpected captured author device id: %v", captured.AuthorDeviceID)
	}
	if uuid.UUID(captured.AuthorUserID.Bytes).String() != userID.String() {
		t.Errorf("unexpected captured author user id: %v", captured.AuthorUserID)
	}
	if captured.NeedsHelpCategory.String != "injured_or_sick" {
		t.Errorf("unexpected captured category: %q", captured.NeedsHelpCategory.String)
	}
}

func TestCatsHandler_CreateNeedsHelp_InvalidCategory(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := newCreateNeedsHelpRequest(uuid.New().String(), `{"category":"flying"}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateNeedsHelp_MissingCategory(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := newCreateNeedsHelpRequest(uuid.New().String(), `{}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateNeedsHelp_MalformedJSON(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := newCreateNeedsHelpRequest(uuid.New().String(), `{`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateNeedsHelp_RejectsUnknownFields(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := newCreateNeedsHelpRequest(uuid.New().String(), `{"category":"trapped","expires_at":"2026-01-01T00:00:00Z"}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateNeedsHelp_CatNotFound(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: false}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := newCreateNeedsHelpRequest(uuid.New().String(), `{"category":"trapped"}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateNeedsHelp_InvalidCatID(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := newCreateNeedsHelpRequest("not-a-uuid", `{"category":"trapped"}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateNeedsHelp_RequiresBearer(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/cats/"+uuid.New().String()+"/needs-help", strings.NewReader(`{"category":"trapped"}`))
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", rec.Code, rec.Body.String())
	}
}

// ── CorrectUpdate/DeleteUpdate (PATCH/DELETE /v1/cats/{cat_id}/updates/{update_id}, issue #80) ─────

func newCorrectUpdateRequest(catID, updateID, body string) *http.Request {
	req := httptest.NewRequest(http.MethodPatch, "/v1/cats/"+catID+"/updates/"+updateID, strings.NewReader(body))
	return withBearerToken(req)
}

func newDeleteUpdateRequest(catID, updateID string) *http.Request {
	req := httptest.NewRequest(http.MethodDelete, "/v1/cats/"+catID+"/updates/"+updateID, nil)
	return withBearerToken(req)
}

func TestCatsHandler_CorrectUpdate_Success(t *testing.T) {
	catID := uuid.New()
	updateID := uuid.New()
	createdAt := time.Date(2026, 1, 5, 8, 0, 0, 0, time.UTC)
	fixedNow := createdAt.Add(2 * time.Minute)
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		correctRow: repository.CorrectOwnUpdateRow{
			CorrectOrdinaryUpdateRow: repository.CorrectOrdinaryUpdateRow{
				ID:        pgtype.UUID{Bytes: updateID, Valid: true},
				CreatedAt: pgtype.Timestamptz{Time: createdAt, Valid: true},
				UpdatedAt: pgtype.Timestamptz{Time: fixedNow, Valid: true},
			},
			Statuses: []string{"seen"},
		},
	}, service.WithClock(func() time.Time { return fixedNow })), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := newCorrectUpdateRequest(catID.String(), updateID.String(), `{"statuses":["seen"],"comment":"düzeltildi"}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var body updateResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.ID != updateID.String() {
		t.Errorf("unexpected id: %q", body.ID)
	}
	if !body.AuthorIsMe {
		t.Error("expected author_is_me true on a successful own-correction response")
	}
}

func TestCatsHandler_CorrectUpdate_WrongAuthor_Returns403(t *testing.T) {
	catID := uuid.New()
	updateID := uuid.New()
	realAuthor := uuid.New()
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		correctErr: pgx.ErrNoRows,
		correctionCheckRow: repository.GetUpdateForCorrectionCheckRow{
			AuthorUserID: pgtype.UUID{Bytes: realAuthor, Valid: true},
			Kind:         "ordinary",
			CreatedAt:    pgtype.Timestamptz{Time: time.Now(), Valid: true},
		},
	}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := newCorrectUpdateRequest(catID.String(), updateID.String(), `{"statuses":["seen"]}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CorrectUpdate_WindowExpired_Returns410(t *testing.T) {
	catID := uuid.New()
	updateID := uuid.New()
	createdAt := time.Date(2026, 1, 5, 8, 0, 0, 0, time.UTC)
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		correctErr: pgx.ErrNoRows,
		correctionCheckRow: repository.GetUpdateForCorrectionCheckRow{
			AuthorUserID: pgtype.UUID{Bytes: uuid.MustParse(defaultTestUserID), Valid: true},
			Kind:         "ordinary",
			CreatedAt:    pgtype.Timestamptz{Time: createdAt, Valid: true},
		},
	}, service.WithClock(func() time.Time { return createdAt.Add(11 * time.Minute) })), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := newCorrectUpdateRequest(catID.String(), updateID.String(), `{"statuses":["seen"]}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusGone {
		t.Fatalf("expected 410, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CorrectUpdate_NeedsHelpKind_Returns404(t *testing.T) {
	catID := uuid.New()
	updateID := uuid.New()
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		correctErr: pgx.ErrNoRows,
		correctionCheckRow: repository.GetUpdateForCorrectionCheckRow{
			AuthorUserID: pgtype.UUID{Bytes: uuid.MustParse(defaultTestUserID), Valid: true},
			Kind:         "needs_help",
			CreatedAt:    pgtype.Timestamptz{Time: time.Now(), Valid: true},
		},
	}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := newCorrectUpdateRequest(catID.String(), updateID.String(), `{"statuses":["seen"]}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CorrectUpdate_RequiresBearer(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPatch, "/v1/cats/"+uuid.New().String()+"/updates/"+uuid.New().String(), strings.NewReader(`{"statuses":["seen"]}`))
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CorrectUpdate_MalformedJSON(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := newCorrectUpdateRequest(uuid.New().String(), uuid.New().String(), `{`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_DeleteUpdate_Success_Returns204(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		deleteRow: repository.DeleteOwnUpdateRow{ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}},
	}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := newDeleteUpdateRequest(uuid.New().String(), uuid.New().String())
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", rec.Code, rec.Body.String())
	}
}

// TestCatsHandler_DeleteUpdate_RetryAfterDelete_StillReturns204 proves a
// retried delete against an already-deleted update answers 204, not an
// error — the idempotent-retry convention this repo already uses for
// POST /v1/auth/logout and POST /v1/me/notifications/{id}/read.
func TestCatsHandler_DeleteUpdate_RetryAfterDelete_StillReturns204(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		deleteErr: pgx.ErrNoRows,
		correctionCheckRow: repository.GetUpdateForCorrectionCheckRow{
			AuthorUserID: pgtype.UUID{Bytes: uuid.MustParse(defaultTestUserID), Valid: true},
			Kind:         "ordinary",
			CreatedAt:    pgtype.Timestamptz{Time: time.Now(), Valid: true},
			DeletedAt:    pgtype.Timestamptz{Time: time.Now(), Valid: true},
		},
	}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := newDeleteUpdateRequest(uuid.New().String(), uuid.New().String())
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204 on a retried delete, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_DeleteUpdate_WrongAuthor_Returns403(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		deleteErr: pgx.ErrNoRows,
		correctionCheckRow: repository.GetUpdateForCorrectionCheckRow{
			AuthorUserID: pgtype.UUID{Bytes: uuid.New(), Valid: true},
			Kind:         "ordinary",
			CreatedAt:    pgtype.Timestamptz{Time: time.Now(), Valid: true},
		},
	}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := newDeleteUpdateRequest(uuid.New().String(), uuid.New().String())
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_DeleteUpdate_RequiresBearer(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodDelete, "/v1/cats/"+uuid.New().String()+"/updates/"+uuid.New().String(), nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", rec.Code, rec.Body.String())
	}
}

// ── SetCover (PATCH /v1/cats/{cat_id}/cover, issue #156) ─────

func newSetCoverRequest(catID, body string) *http.Request {
	req := httptest.NewRequest(http.MethodPatch, "/v1/cats/"+catID+"/cover", strings.NewReader(body))
	return withBearerToken(req)
}

func TestCatsHandler_SetCover_Success(t *testing.T) {
	catID := uuid.New()
	ownerID := uuid.MustParse(defaultTestUserID)
	mediaID := uuid.New()
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		catRow: repository.GetCatByIDRow{
			ID:              pgtype.UUID{Bytes: catID, Valid: true},
			Name:            pgtype.Text{String: "tekir", Valid: true},
			CreatedByUserID: pgtype.UUID{Bytes: ownerID, Valid: true},
		},
		catMediaRow: repository.CatMedium{ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}},
	}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := newSetCoverRequest(catID.String(), `{"media_id":"`+mediaID.String()+`"}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var body catDetailResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if !body.IsOwner {
		t.Error("expected is_owner true for the cat's own owner")
	}
}

func TestCatsHandler_SetCover_NotOwner_Returns403(t *testing.T) {
	catID := uuid.New()
	realOwner := uuid.New()
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		catRow: repository.GetCatByIDRow{
			ID:              pgtype.UUID{Bytes: catID, Valid: true},
			CreatedByUserID: pgtype.UUID{Bytes: realOwner, Valid: true},
		},
	}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := newSetCoverRequest(catID.String(), `{"media_id":"`+uuid.New().String()+`"}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_SetCover_MediaNotInGallery_Returns400(t *testing.T) {
	catID := uuid.New()
	ownerID := uuid.MustParse(defaultTestUserID)
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		catRow: repository.GetCatByIDRow{
			ID:              pgtype.UUID{Bytes: catID, Valid: true},
			CreatedByUserID: pgtype.UUID{Bytes: ownerID, Valid: true},
		},
		catMediaErr: pgx.ErrNoRows,
	}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := newSetCoverRequest(catID.String(), `{"media_id":"`+uuid.New().String()+`"}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_SetCover_RequiresBearer(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPatch, "/v1/cats/"+uuid.New().String()+"/cover", strings.NewReader(`{"media_id":"`+uuid.New().String()+`"}`))
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_SetCover_MalformedJSON(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := newSetCoverRequest(uuid.New().String(), `{"media_id":`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_SetCover_UnknownFields_Returns400(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)
	rec := httptest.NewRecorder()
	req := newSetCoverRequest(uuid.New().String(), `{"media_id":"`+uuid.New().String()+`","kind":"cover"}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

// TestCatsHandler_UpdateHistory_AuthorIsMe proves GET .../updates surfaces
// author_is_me/correction_expires_at for the caller's own recent ordinary
// update, computed server-side by comparing author_user_id against the
// optional bearer caller — never left to the client to guess.
func TestCatsHandler_UpdateHistory_AuthorIsMe(t *testing.T) {
	catID := uuid.New()
	myUserID := uuid.MustParse(defaultTestUserID)
	updateID := uuid.New()
	createdAt := time.Date(2026, 1, 5, 8, 0, 0, 0, time.UTC)
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		exists: true,
		updateRows: []repository.ListCatUpdatesRow{
			{
				ID:           pgtype.UUID{Bytes: updateID, Valid: true},
				Kind:         "ordinary",
				CreatedAt:    pgtype.Timestamptz{Time: createdAt, Valid: true},
				AuthorUserID: pgtype.UUID{Bytes: myUserID, Valid: true},
				Statuses:     []string{"seen"},
			},
		},
	}, service.WithClock(func() time.Time { return createdAt.Add(time.Minute) })), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := withBearerToken(httptest.NewRequest(http.MethodGet, "/v1/cats/"+catID.String()+"/updates", nil))
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var body updateHistoryResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body.Items) != 1 || !body.Items[0].AuthorIsMe {
		t.Fatalf("expected author_is_me true, got %+v", body.Items)
	}
	want := createdAt.Add(10 * time.Minute)
	if body.Items[0].CorrectionExpiresAt == nil || !body.Items[0].CorrectionExpiresAt.Equal(want) {
		t.Errorf("expected correction_expires_at %v, got %v", want, body.Items[0].CorrectionExpiresAt)
	}
}

// TestCatsHandler_UpdateHistory_GuestNeverSeesAuthorIsMe proves a guest
// read (no Authorization header at all) never surfaces author_is_me true
// for anyone, regardless of who authored the update.
func TestCatsHandler_UpdateHistory_GuestNeverSeesAuthorIsMe(t *testing.T) {
	catID := uuid.New()
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		exists: true,
		updateRows: []repository.ListCatUpdatesRow{
			{
				ID:           pgtype.UUID{Bytes: uuid.New(), Valid: true},
				Kind:         "ordinary",
				CreatedAt:    pgtype.Timestamptz{Time: time.Now(), Valid: true},
				AuthorUserID: pgtype.UUID{Bytes: uuid.New(), Valid: true},
				Statuses:     []string{"seen"},
			},
		},
	}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+catID.String()+"/updates", nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 (guest-readable), got %d: %s", rec.Code, rec.Body.String())
	}
	var body updateHistoryResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body.Items) != 1 || body.Items[0].AuthorIsMe || body.Items[0].CorrectionExpiresAt != nil {
		t.Fatalf("expected author_is_me false and no correction_expires_at for a guest read, got %+v", body.Items)
	}
}

// createCatRouterFor wires POST /v1/cats and GET /v1/cats/nearby behind the
// same middleware chain server.NewRouter uses in production.
func createCatRouterFor(h *CatsHandler) http.Handler {
	r := chi.NewRouter()
	r.Get("/v1/cats/nearby", h.NearbyDuplicates)
	r.With(
		RequireBearer(fakeAccessValidator{userID: defaultTestUserID}),
		OptionalDeviceToken(fakeDeviceResolver{identity: service.DeviceIdentity{DeviceID: uuid.NewString()}}),
	).Post("/v1/cats", h.Create)
	return r
}

// newCreateCatRequest builds a POST /v1/cats multipart request with the
// given lat/lng/name/confirmedNew fields and, when photo is non-nil, a
// "photo" file field carrying it. Tests whose expected outcome is decided
// before CatsService.Create ever validates the photo's content (missing
// photo, invalid area, duplicate candidates) can pass arbitrary bytes;
// TestCatsHandler_Create_Success is the only case that needs validTestJPEG.
func newCreateCatRequest(fields map[string]string, photo []byte) *http.Request {
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	for k, v := range fields {
		_ = w.WriteField(k, v)
	}
	if photo != nil {
		part, _ := w.CreateFormFile("photo", "cat.jpg")
		_, _ = part.Write(photo)
	}
	_ = w.Close()

	req := httptest.NewRequest(http.MethodPost, "/v1/cats", &buf)
	req.Header.Set("Content-Type", w.FormDataContentType())
	return req
}

func TestCatsHandler_Create_Success(t *testing.T) {
	catID := uuid.New()
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		createCatWithMediaRow: repository.CreateCatWithMediaRow{
			Cat:   repository.CreateCatRow{ID: pgtype.UUID{Bytes: catID, Valid: true}, Lat: 41.03, Lng: 28.98},
			Media: repository.Medium{ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}, Url: "/v1/media/objects/x.jpg"},
		},
	}, service.WithCatsMediaPipeline(&fakeHandlerObjectStore{}, 1<<20)), testMaxUploadBytes)

	req := withBearerToken(newCreateCatRequest(map[string]string{"lat": "41.03", "lng": "28.98", "confirmed_new": "true"}, validTestJPEG(t)))
	rec := httptest.NewRecorder()
	createCatRouterFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	var body createCatResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.Cat.ID != catID.String() {
		t.Errorf("expected cat id %s, got %s", catID.String(), body.Cat.ID)
	}
}

func TestCatsHandler_Create_RequiresBearer(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}, service.WithCatsMediaPipeline(&fakeHandlerObjectStore{}, 1<<20)), testMaxUploadBytes)

	req := newCreateCatRequest(map[string]string{"lat": "41.03", "lng": "28.98", "confirmed_new": "true"}, []byte("fake-photo-bytes"))
	rec := httptest.NewRecorder()
	createCatRouterFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestCatsHandler_Create_MissingPhoto(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}, service.WithCatsMediaPipeline(&fakeHandlerObjectStore{}, 1<<20)), testMaxUploadBytes)

	req := withBearerToken(newCreateCatRequest(map[string]string{"lat": "41.03", "lng": "28.98", "confirmed_new": "true"}, nil))
	rec := httptest.NewRecorder()
	createCatRouterFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 without a photo, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_Create_MissingLatLng(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}, service.WithCatsMediaPipeline(&fakeHandlerObjectStore{}, 1<<20)), testMaxUploadBytes)

	req := withBearerToken(newCreateCatRequest(map[string]string{"confirmed_new": "true"}, []byte("fake-photo-bytes")))
	rec := httptest.NewRecorder()
	createCatRouterFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 without lat/lng, got %d", rec.Code)
	}
}

// TestCatsHandler_Create_OversizedBodyReturns413 proves an
// http.MaxBytesReader rejection (the request itself exceeds
// maxUploadBytes) answers 413, distinguishable from a genuinely malformed
// multipart body (400) — a client needs to tell "your photo was too big"
// apart from "your request was broken".
func TestCatsHandler_Create_OversizedBodyReturns413(t *testing.T) {
	// maxUploadBytes always gets multipartOverheadBytes (64KB) added on top
	// (see NewCatsHandler) for the surrounding form fields/boundaries, so
	// the payload here must clear that plus the configured 10-byte limit.
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}, service.WithCatsMediaPipeline(&fakeHandlerObjectStore{}, 1<<20)), 10)

	oversizedPhoto := bytes.Repeat([]byte("x"), 200_000)
	req := withBearerToken(newCreateCatRequest(map[string]string{"lat": "41.03", "lng": "28.98", "confirmed_new": "true"}, oversizedPhoto))
	rec := httptest.NewRecorder()
	createCatRouterFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_Create_DuplicateCandidatesReturns409(t *testing.T) {
	nearbyID := uuid.New()
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		nearbyDuplicateRows: []repository.ListNearbyCatsForDuplicateCheckRow{
			{ID: pgtype.UUID{Bytes: nearbyID, Valid: true}, Name: pgtype.Text{String: "existing", Valid: true}, PhotoUrl: "https://example.com/x.jpg"},
		},
	}, service.WithCatsMediaPipeline(&fakeHandlerObjectStore{}, 1<<20)), testMaxUploadBytes)

	req := withBearerToken(newCreateCatRequest(map[string]string{"lat": "41.03", "lng": "28.98"}, []byte("fake-photo-bytes")))
	rec := httptest.NewRecorder()
	createCatRouterFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d: %s", rec.Code, rec.Body.String())
	}
	var body duplicateCandidatesResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body.Candidates) != 1 || body.Candidates[0].ID != nearbyID.String() {
		t.Errorf("unexpected candidates: %+v", body.Candidates)
	}
}

func TestCatsHandler_Create_InvalidAreaOutsideIstanbul(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}, service.WithCatsMediaPipeline(&fakeHandlerObjectStore{}, 1<<20)), testMaxUploadBytes)

	req := withBearerToken(newCreateCatRequest(map[string]string{"lat": "48.85", "lng": "2.35", "confirmed_new": "true"}, []byte("fake-photo-bytes")))
	rec := httptest.NewRecorder()
	createCatRouterFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for an out-of-bounds area, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_NearbyDuplicates_Success(t *testing.T) {
	nearbyID := uuid.New()
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		nearbyDuplicateRows: []repository.ListNearbyCatsForDuplicateCheckRow{
			{ID: pgtype.UUID{Bytes: nearbyID, Valid: true}, Name: pgtype.Text{String: "tekir", Valid: true}, PhotoUrl: "https://example.com/x.jpg"},
		},
	}), testMaxUploadBytes)

	req := httptest.NewRequest(http.MethodGet, "/v1/cats/nearby?lat=41.03&lng=28.98", nil)
	rec := httptest.NewRecorder()
	createCatRouterFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var body []duplicateCandidateResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body) != 1 || body[0].ID != nearbyID.String() {
		t.Errorf("unexpected body: %+v", body)
	}
}

func TestCatsHandler_NearbyDuplicates_MissingLatLng(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)

	req := httptest.NewRequest(http.MethodGet, "/v1/cats/nearby", nil)
	rec := httptest.NewRecorder()
	createCatRouterFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestCatsHandler_Discover_NearbySuccess(t *testing.T) {
	id := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		distanceRows: []repository.ListCatsByDistanceRow{
			{
				ID:        id,
				Name:      pgtype.Text{String: "tekir", Valid: true},
				PhotoUrl:  "https://placecats.com/millie/300/200",
				AreaLabel: pgtype.Text{String: "Galata Kulesi çevresi, Beyoğlu", Valid: true},
				DistanceM: 123.4,
			},
		},
	}), testMaxUploadBytes)

	// no Authorization header at all — issue #82 requires nearby/needs_help
	// to be public, guest-readable exactly like GET /v1/cats' bbox mode.
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/discover?lat=41.0256&lng=28.9744&filter=nearby", nil)
	rec := httptest.NewRecorder()
	h.Discover(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var body discoverPageResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body.Items) != 1 {
		t.Fatalf("expected 1 item, got %d", len(body.Items))
	}
	item := body.Items[0]
	if item.ID != uuid.UUID(id.Bytes).String() {
		t.Errorf("unexpected id: %q", item.ID)
	}
	if item.DistanceMeters != 123.4 {
		t.Errorf("unexpected distance_meters: %v", item.DistanceMeters)
	}
	if item.AreaLabel == nil || *item.AreaLabel != "Galata Kulesi çevresi, Beyoğlu" {
		t.Errorf("unexpected area_label: %v", item.AreaLabel)
	}
	if item.ActiveAlert != nil {
		t.Errorf("expected no active alert, got %+v", item.ActiveAlert)
	}
	if body.NextCursor != nil {
		t.Errorf("expected no next_cursor for a single-row result, got %v", body.NextCursor)
	}
}

func TestCatsHandler_Discover_NeedsHelpSuccess(t *testing.T) {
	fixedNow := time.Date(2026, 2, 1, 10, 0, 0, 0, time.UTC)
	id := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		needsHelpDistanceRows: []repository.ListActiveNeedsHelpCatsByDistanceRow{
			{
				ID:                 id,
				Name:               pgtype.Text{String: "boncuk", Valid: true},
				PhotoUrl:           "https://placecats.com/boncuk/300/200",
				NeedsHelpCategory:  pgtype.Text{String: "food_needed", Valid: true},
				NeedsHelpCreatedAt: pgtype.Timestamptz{Time: fixedNow.Add(-time.Hour), Valid: true},
				NeedsHelpExpiresAt: pgtype.Timestamptz{Time: fixedNow.Add(time.Hour), Valid: true},
				DistanceM:          50,
			},
		},
	}, service.WithClock(func() time.Time { return fixedNow })), testMaxUploadBytes)

	req := httptest.NewRequest(http.MethodGet, "/v1/cats/discover?lat=41.0256&lng=28.9744&filter=needs_help", nil)
	rec := httptest.NewRecorder()
	h.Discover(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var body discoverPageResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body.Items) != 1 {
		t.Fatalf("expected 1 item, got %d", len(body.Items))
	}
	alert := body.Items[0].ActiveAlert
	if alert == nil {
		t.Fatal("expected an active alert")
	}
	if alert.Category != "food_needed" {
		t.Errorf("unexpected category: %q", alert.Category)
	}
}

func TestCatsHandler_Discover_MissingLatLng(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)

	req := httptest.NewRequest(http.MethodGet, "/v1/cats/discover?filter=nearby", nil)
	rec := httptest.NewRecorder()
	h.Discover(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestCatsHandler_Discover_InvalidFilter(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)

	req := httptest.NewRequest(http.MethodGet, "/v1/cats/discover?lat=41.0256&lng=28.9744&filter=popular", nil)
	rec := httptest.NewRecorder()
	h.Discover(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_Discover_InvalidArea(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)

	// well outside istanbulBounds (e.g. ankara).
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/discover?lat=39.93&lng=32.85&filter=nearby", nil)
	rec := httptest.NewRecorder()
	h.Discover(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_Discover_InvalidCursor(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)

	req := httptest.NewRequest(http.MethodGet, "/v1/cats/discover?lat=41.0256&lng=28.9744&filter=nearby&cursor=not-valid!!", nil)
	rec := httptest.NewRecorder()
	h.Discover(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_Discover_InvalidLimit(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)

	req := httptest.NewRequest(http.MethodGet, "/v1/cats/discover?lat=41.0256&lng=28.9744&filter=nearby&limit=not-a-number", nil)
	rec := httptest.NewRecorder()
	h.Discover(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

// fakeHandlerObjectStore is a minimal ObjectStore for handler-level tests
// that only need CatsService.Create's pipeline to run without touching
// disk — the handler tests stub the repository layer, so the actual
// stored bytes/content-type never matter here.
type fakeHandlerObjectStore struct{}

func (fakeHandlerObjectStore) Put(_ context.Context, key, _ string, _ []byte) (string, error) {
	return "/v1/media/objects/" + key, nil
}

func (fakeHandlerObjectStore) Delete(_ context.Context, _ string) error { return nil }
