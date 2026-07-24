package handler

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// fakeFollowsManager is an in-process stub for FollowsManager.
type fakeFollowsManager struct {
	err error

	// capturedDeviceID/capturedCatID record the args the last Follow or
	// Unfollow call received, so a test can assert device isolation without
	// a real database.
	capturedDeviceID *string
	capturedCatID    *string

	cats    []service.CatMarker
	listErr error
}

func (f fakeFollowsManager) Follow(_ context.Context, catID, deviceID string) error {
	if f.capturedCatID != nil {
		*f.capturedCatID = catID
	}
	if f.capturedDeviceID != nil {
		*f.capturedDeviceID = deviceID
	}
	return f.err
}

func (f fakeFollowsManager) Unfollow(_ context.Context, catID, deviceID string) error {
	if f.capturedCatID != nil {
		*f.capturedCatID = catID
	}
	if f.capturedDeviceID != nil {
		*f.capturedDeviceID = deviceID
	}
	return f.err
}

func (f fakeFollowsManager) ListFollows(_ context.Context, deviceID string) ([]service.CatMarker, error) {
	if f.capturedDeviceID != nil {
		*f.capturedDeviceID = deviceID
	}
	return f.cats, f.listErr
}

// routerForFollows wires h behind a real chi router with RequireDeviceToken,
// exactly as server.NewRouter wires it, so requests without a valid
// X-Device-Token never reach the handler.
func routerForFollows(h *FollowsHandler, resolver DeviceTokenResolver) http.Handler {
	r := chi.NewRouter()
	r.With(RequireDeviceToken(resolver)).Post("/v1/cats/{cat_id}/follow", h.Follow)
	r.With(RequireDeviceToken(resolver)).Delete("/v1/cats/{cat_id}/follow", h.Unfollow)
	r.With(RequireDeviceToken(resolver)).Get("/v1/me/follows", h.ListFollows)
	return r
}

func followsResolverFor(deviceID string) DeviceTokenResolver {
	return fakeDeviceResolver{identity: service.DeviceIdentity{DeviceID: deviceID}}
}

// ── Follow ────────────────────────────────────────────────────────────────

func TestFollowsHandler_Follow_Success(t *testing.T) {
	var capturedCat, capturedDevice string
	h := NewFollowsHandler(fakeFollowsManager{capturedCatID: &capturedCat, capturedDeviceID: &capturedDevice})
	deviceID := uuid.New().String()
	r := routerForFollows(h, followsResolverFor(deviceID))

	catID := uuid.New().String()
	req := withDeviceToken(httptest.NewRequest(http.MethodPost, "/v1/cats/"+catID+"/follow", nil))
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", rec.Code, rec.Body.String())
	}
	if capturedCat != catID {
		t.Errorf("expected cat id %s, got %s", catID, capturedCat)
	}
	if capturedDevice != deviceID {
		t.Errorf("expected device id %s, got %s", deviceID, capturedDevice)
	}
}

func TestFollowsHandler_Follow_Idempotent(t *testing.T) {
	h := NewFollowsHandler(fakeFollowsManager{})
	r := routerForFollows(h, followsResolverFor(uuid.New().String()))
	catID := uuid.New().String()

	for i := 0; i < 2; i++ {
		req := withDeviceToken(httptest.NewRequest(http.MethodPost, "/v1/cats/"+catID+"/follow", nil))
		rec := httptest.NewRecorder()
		r.ServeHTTP(rec, req)
		if rec.Code != http.StatusNoContent {
			t.Fatalf("call %d: expected 204, got %d: %s", i, rec.Code, rec.Body.String())
		}
	}
}

func TestFollowsHandler_Follow_InvalidCatID(t *testing.T) {
	h := NewFollowsHandler(fakeFollowsManager{err: service.ErrInvalidCatID})
	r := routerForFollows(h, followsResolverFor(uuid.New().String()))

	req := withDeviceToken(httptest.NewRequest(http.MethodPost, "/v1/cats/not-a-uuid/follow", nil))
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestFollowsHandler_Follow_UnknownCat(t *testing.T) {
	h := NewFollowsHandler(fakeFollowsManager{err: service.ErrCatNotFound})
	r := routerForFollows(h, followsResolverFor(uuid.New().String()))

	req := withDeviceToken(httptest.NewRequest(http.MethodPost, "/v1/cats/"+uuid.New().String()+"/follow", nil))
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestFollowsHandler_Follow_RepositoryFailure(t *testing.T) {
	h := NewFollowsHandler(fakeFollowsManager{err: errors.New("connection refused")})
	r := routerForFollows(h, followsResolverFor(uuid.New().String()))

	req := withDeviceToken(httptest.NewRequest(http.MethodPost, "/v1/cats/"+uuid.New().String()+"/follow", nil))
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestFollowsHandler_Follow_RequiresDeviceToken(t *testing.T) {
	h := NewFollowsHandler(fakeFollowsManager{})
	r := routerForFollows(h, followsResolverFor(uuid.New().String()))

	req := httptest.NewRequest(http.MethodPost, "/v1/cats/"+uuid.New().String()+"/follow", nil)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestFollowsHandler_Follow_UnknownDeviceToken(t *testing.T) {
	h := NewFollowsHandler(fakeFollowsManager{})
	r := routerForFollows(h, fakeDeviceResolver{err: service.ErrDeviceNotFound})

	req := withDeviceToken(httptest.NewRequest(http.MethodPost, "/v1/cats/"+uuid.New().String()+"/follow", nil))
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", rec.Code, rec.Body.String())
	}
}

// ── Unfollow ──────────────────────────────────────────────────────────────

func TestFollowsHandler_Unfollow_Success(t *testing.T) {
	var capturedCat, capturedDevice string
	h := NewFollowsHandler(fakeFollowsManager{capturedCatID: &capturedCat, capturedDeviceID: &capturedDevice})
	deviceID := uuid.New().String()
	r := routerForFollows(h, followsResolverFor(deviceID))

	catID := uuid.New().String()
	req := withDeviceToken(httptest.NewRequest(http.MethodDelete, "/v1/cats/"+catID+"/follow", nil))
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", rec.Code, rec.Body.String())
	}
	if capturedCat != catID {
		t.Errorf("expected cat id %s, got %s", catID, capturedCat)
	}
	if capturedDevice != deviceID {
		t.Errorf("expected device id %s, got %s", deviceID, capturedDevice)
	}
}

func TestFollowsHandler_Unfollow_NotFollowingIsIdempotent(t *testing.T) {
	h := NewFollowsHandler(fakeFollowsManager{})
	r := routerForFollows(h, followsResolverFor(uuid.New().String()))

	req := withDeviceToken(httptest.NewRequest(http.MethodDelete, "/v1/cats/"+uuid.New().String()+"/follow", nil))
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestFollowsHandler_Unfollow_InvalidCatID(t *testing.T) {
	h := NewFollowsHandler(fakeFollowsManager{err: service.ErrInvalidCatID})
	r := routerForFollows(h, followsResolverFor(uuid.New().String()))

	req := withDeviceToken(httptest.NewRequest(http.MethodDelete, "/v1/cats/not-a-uuid/follow", nil))
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestFollowsHandler_Unfollow_UnknownCat(t *testing.T) {
	h := NewFollowsHandler(fakeFollowsManager{err: service.ErrCatNotFound})
	r := routerForFollows(h, followsResolverFor(uuid.New().String()))

	req := withDeviceToken(httptest.NewRequest(http.MethodDelete, "/v1/cats/"+uuid.New().String()+"/follow", nil))
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestFollowsHandler_Unfollow_RequiresDeviceToken(t *testing.T) {
	h := NewFollowsHandler(fakeFollowsManager{})
	r := routerForFollows(h, followsResolverFor(uuid.New().String()))

	req := httptest.NewRequest(http.MethodDelete, "/v1/cats/"+uuid.New().String()+"/follow", nil)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", rec.Code, rec.Body.String())
	}
}

// ── ListFollows ───────────────────────────────────────────────────────────

func TestFollowsHandler_ListFollows_Success(t *testing.T) {
	id := uuid.New()
	lastUpdate := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	h := NewFollowsHandler(fakeFollowsManager{cats: []service.CatMarker{
		{
			ID:           id.String(),
			Name:         "tekir",
			PrimaryPhoto: "https://placecats.com/millie/300/200",
			Lat:          41.0256,
			Lng:          28.9744,
			LastUpdateAt: &lastUpdate,
		},
	}})
	r := routerForFollows(h, followsResolverFor(uuid.New().String()))

	req := withDeviceToken(httptest.NewRequest(http.MethodGet, "/v1/me/follows", nil))
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var body []catMarkerResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body) != 1 {
		t.Fatalf("expected 1 cat, got %d", len(body))
	}
	if body[0].ID != id.String() {
		t.Errorf("expected id %s, got %s", id.String(), body[0].ID)
	}
	if body[0].Name != "tekir" {
		t.Errorf("unexpected name: %q", body[0].Name)
	}
}

func TestFollowsHandler_ListFollows_ScopedToResolvedDevice(t *testing.T) {
	var capturedDevice string
	h := NewFollowsHandler(fakeFollowsManager{capturedDeviceID: &capturedDevice})
	deviceID := uuid.New().String()
	r := routerForFollows(h, followsResolverFor(deviceID))

	req := withDeviceToken(httptest.NewRequest(http.MethodGet, "/v1/me/follows", nil))
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if capturedDevice != deviceID {
		t.Errorf("expected list scoped to resolved device %s, got %s", deviceID, capturedDevice)
	}
}

func TestFollowsHandler_ListFollows_Empty(t *testing.T) {
	h := NewFollowsHandler(fakeFollowsManager{cats: nil})
	r := routerForFollows(h, followsResolverFor(uuid.New().String()))

	req := withDeviceToken(httptest.NewRequest(http.MethodGet, "/v1/me/follows", nil))
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var body []catMarkerResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body) != 0 {
		t.Fatalf("expected 0 cats, got %d", len(body))
	}
}

func TestFollowsHandler_ListFollows_RepositoryFailure(t *testing.T) {
	h := NewFollowsHandler(fakeFollowsManager{listErr: errors.New("connection refused")})
	r := routerForFollows(h, followsResolverFor(uuid.New().String()))

	req := withDeviceToken(httptest.NewRequest(http.MethodGet, "/v1/me/follows", nil))
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestFollowsHandler_ListFollows_RequiresDeviceToken(t *testing.T) {
	h := NewFollowsHandler(fakeFollowsManager{})
	r := routerForFollows(h, followsResolverFor(uuid.New().String()))

	req := httptest.NewRequest(http.MethodGet, "/v1/me/follows", nil)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", rec.Code, rec.Body.String())
	}
}
