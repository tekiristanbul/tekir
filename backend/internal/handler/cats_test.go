package handler

import (
	"context"
	"encoding/json"
	"errors"
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
	if f.captured != nil {
		*f.captured = arg
	}
	return f.createRow, f.createErr
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
	r.Get("/v1/cats/{cat_id}", h.Detail)
	r.Get("/v1/cats/{cat_id}/updates", h.UpdateHistory)
	r.With(RequireBearer(validator), OptionalDeviceToken(resolver)).Post("/v1/cats/{cat_id}/updates", h.CreateUpdate)
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
			PhotoUrl:  pgtype.Text{String: "https://placecats.com/millie/300/200", Valid: true},
			Lng:       28.9744,
			Lat:       41.0256,
			AreaLabel: pgtype.Text{String: "Galata Kulesi çevresi, Beyoğlu", Valid: true},
		},
	}}))

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
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats", nil)
	h.Nearby(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestCatsHandler_Nearby_MalformedBbox(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats?bbox=not,a,valid,bbox", nil)
	h.Nearby(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestCatsHandler_Nearby_InvalidBoundsOrder(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats?bbox=29,41,28,42", nil)
	h.Nearby(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestCatsHandler_Nearby_NanAndInfiniteBounds(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}))

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
			PhotoUrl:  pgtype.Text{String: "https://placecats.com/millie/300/200", Valid: true},
			CreatedAt: pgtype.Timestamptz{Time: created, Valid: true},
		},
	}))

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
	}))

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

func TestCatsHandler_Detail_NotFound(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{catErr: pgx.ErrNoRows}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String(), nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_Detail_InvalidID(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/not-a-uuid", nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestCatsHandler_Detail_RepositoryFailure(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{catErr: errors.New("connection refused")}))

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
	}))

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

func TestCatsHandler_UpdateHistory_NotFound(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: false}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String()+"/updates", nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_UpdateHistory_InvalidLimit(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String()+"/updates?limit=not-a-number", nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_UpdateHistory_LimitOutOfRange(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String()+"/updates?limit=1000", nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_UpdateHistory_RepositoryFailure(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true, updatesErr: errors.New("connection refused")}))

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
	}}, service.WithClock(func() time.Time { return fixedNow })))

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
	}}))

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
	}, service.WithClock(func() time.Time { return fixedNow })))

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
				CreatedAt:          pgtype.Timestamptz{Time: fixedNow.Add(-100 * time.Hour), Valid: true},
				Seq:                pgtype.Int8{Int64: 1, Valid: true},
				NeedsHelpCategory:  pgtype.Text{String: "water_needed", Valid: true},
				NeedsHelpExpiresAt: pgtype.Timestamptz{Time: fixedNow.Add(-28 * time.Hour), Valid: true},
				Statuses:           []string{},
			},
		},
	}, service.WithClock(func() time.Time { return fixedNow })))

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
	}))
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
	}, service.WithClock(func() time.Time { return created })))

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

func TestCatsHandler_CreateUpdate_WithCommentAndMultipleStatuses(t *testing.T) {
	returnedID := uuid.New()
	var captured repository.CreateOrdinaryUpdateParams
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		exists:    true,
		createRow: repository.CreateUpdateRow{ID: pgtype.UUID{Bytes: returnedID, Valid: true}},
		captured:  &captured,
	}))

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
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}))
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{"statuses":[]}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateUpdate_MissingStatuses(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}))
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateUpdate_CommentOnly(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}))
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{"comment":"mama verildi"}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateUpdate_UnknownStatusValue(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}))
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{"statuses":["flying"]}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateUpdate_DuplicateStatus(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}))
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{"statuses":["seen","seen"]}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateUpdate_MalformedJSON(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}))
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
			h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}))
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
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: false}))
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{"statuses":["seen"]}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateUpdate_InvalidCatID(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}))
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest("not-a-uuid", `{"statuses":["seen"]}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateUpdate_RepositoryFailure(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true, createErr: errors.New("connection refused")}))
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
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true}))
	r := routerFor(h)

	rec := httptest.NewRecorder()
	req := withDeviceToken(httptest.NewRequest(http.MethodPost, "/v1/cats/"+uuid.New().String()+"/updates", strings.NewReader(`{"statuses":["seen"]}`)))
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CreateUpdate_InvalidBearer(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true}))
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
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true, captured: &captured}))
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
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true}))
	r := routerForWithResolver(h, fakeDeviceResolver{err: service.ErrDeviceNotFound}, fakeAccessValidator{userID: defaultTestUserID})

	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{"statuses":["seen"]}`)
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
}
