package handler

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

type fakeLocalObjectReader struct {
	data []byte
	err  error
}

func (f fakeLocalObjectReader) Get(_ context.Context, _ string) ([]byte, error) {
	return f.data, f.err
}

func mediaServeRouterFor(h *MediaServeHandler) http.Handler {
	r := chi.NewRouter()
	r.Get("/v1/media/objects/{key}", h.ServeObject)
	return r
}

func TestMediaServeHandler_ServeObject_Success(t *testing.T) {
	h := NewMediaServeHandler(fakeLocalObjectReader{data: []byte("fake-jpeg-bytes")})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/media/objects/abc.jpg", nil)
	mediaServeRouterFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if rec.Body.String() != "fake-jpeg-bytes" {
		t.Errorf("unexpected body: %q", rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "image/jpeg" {
		t.Errorf("expected image/jpeg content-type, got %q", ct)
	}
}

func TestMediaServeHandler_ServeObject_NotFound(t *testing.T) {
	h := NewMediaServeHandler(fakeLocalObjectReader{err: service.ErrObjectNotFound})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/media/objects/missing.jpg", nil)
	mediaServeRouterFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", rec.Code)
	}
}

func TestMediaServeHandler_ServeObject_InvalidKeyIsNotFound(t *testing.T) {
	h := NewMediaServeHandler(fakeLocalObjectReader{err: service.ErrInvalidObjectKey})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/media/objects/whatever", nil)
	mediaServeRouterFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404 for an invalid key (never a 500), got %d", rec.Code)
	}
}

func TestMediaServeHandler_ServeObject_GenericErrorIs500(t *testing.T) {
	h := NewMediaServeHandler(fakeLocalObjectReader{err: errors.New("disk on fire")})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/media/objects/abc.jpg", nil)
	mediaServeRouterFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d", rec.Code)
	}
}
