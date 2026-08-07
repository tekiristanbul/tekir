package handler

import (
	"bytes"
	"context"
	"errors"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// fakeMediaUploader is an in-process stub for MediaUploader.
type fakeMediaUploader struct {
	media service.Media
	err   error

	capturedUserID         *string
	capturedDeviceID       *string
	capturedIdempotencyKey **string
}

func (f fakeMediaUploader) Upload(_ context.Context, userID, deviceID string, idempotencyKey *string, _ []byte) (service.Media, error) {
	if f.capturedUserID != nil {
		*f.capturedUserID = userID
	}
	if f.capturedDeviceID != nil {
		*f.capturedDeviceID = deviceID
	}
	if f.capturedIdempotencyKey != nil {
		*f.capturedIdempotencyKey = idempotencyKey
	}
	return f.media, f.err
}

// newMultipartFileRequest builds a POST request whose body is a multipart
// form with one file field (fieldName/filename/content) plus any extra
// plain string fields.
func newMultipartFileRequest(url, fieldName, filename string, content []byte, extraFields map[string]string) *http.Request {
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	for k, v := range extraFields {
		_ = w.WriteField(k, v)
	}
	part, _ := w.CreateFormFile(fieldName, filename)
	_, _ = part.Write(content)
	_ = w.Close()

	req := httptest.NewRequest(http.MethodPost, url, &buf)
	req.Header.Set("Content-Type", w.FormDataContentType())
	return req
}

func mediaRouterFor(h *MediaHandler) http.Handler {
	r := chi.NewRouter()
	r.With(
		RequireBearer(fakeAccessValidator{userID: defaultTestUserID}),
		OptionalDeviceToken(fakeDeviceResolver{identity: service.DeviceIdentity{DeviceID: uuid.NewString()}}),
	).Post("/v1/media", h.Upload)
	return r
}

func TestMediaHandler_Upload_Success(t *testing.T) {
	var capturedUserID string
	uploader := fakeMediaUploader{
		media:          service.Media{ID: "media-1", URL: "/v1/media/objects/x.jpg"},
		capturedUserID: &capturedUserID,
	}
	h := NewMediaHandler(uploader, 1<<20)

	req := withBearerToken(newMultipartFileRequest("/v1/media", "file", "photo.jpg", []byte("fake-bytes"), nil))
	rec := httptest.NewRecorder()
	mediaRouterFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	if capturedUserID != defaultTestUserID {
		t.Errorf("expected ownership resolved from bearer context (%s), got %q", defaultTestUserID, capturedUserID)
	}
}

func TestMediaHandler_Upload_RequiresBearer(t *testing.T) {
	h := NewMediaHandler(fakeMediaUploader{}, 1<<20)

	req := newMultipartFileRequest("/v1/media", "file", "photo.jpg", []byte("fake-bytes"), nil)
	rec := httptest.NewRecorder()
	mediaRouterFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 without a bearer token, got %d", rec.Code)
	}
}

func TestMediaHandler_Upload_MissingFile(t *testing.T) {
	h := NewMediaHandler(fakeMediaUploader{}, 1<<20)

	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	_ = w.Close()
	req := httptest.NewRequest(http.MethodPost, "/v1/media", &buf)
	req.Header.Set("Content-Type", w.FormDataContentType())
	req = withBearerToken(req)

	rec := httptest.NewRecorder()
	mediaRouterFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 without a file, got %d", rec.Code)
	}
}

func TestMediaHandler_Upload_PassesIdempotencyKeyHeader(t *testing.T) {
	var captured *string
	uploader := fakeMediaUploader{capturedIdempotencyKey: &captured}
	h := NewMediaHandler(uploader, 1<<20)

	req := withBearerToken(newMultipartFileRequest("/v1/media", "file", "photo.jpg", []byte("fake-bytes"), nil))
	req.Header.Set("Idempotency-Key", "my-key")
	rec := httptest.NewRecorder()
	mediaRouterFor(h).ServeHTTP(rec, req)

	if captured == nil || *captured != "my-key" {
		t.Errorf("expected idempotency key %q to reach the service, got %v", "my-key", captured)
	}
}

func TestMediaHandler_Upload_MapsServiceErrors(t *testing.T) {
	cases := []struct {
		name       string
		err        error
		wantStatus int
	}{
		{"too large", service.ErrMediaTooLarge, http.StatusRequestEntityTooLarge},
		{"unsupported type", service.ErrUnsupportedMediaType, http.StatusUnsupportedMediaType},
		{"video too long", service.ErrMediaDurationTooLong, http.StatusBadRequest},
		{"malformed", service.ErrMalformedMedia, http.StatusBadRequest},
		{"generic", errors.New("boom"), http.StatusInternalServerError},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := NewMediaHandler(fakeMediaUploader{err: tc.err}, 1<<20)
			req := withBearerToken(newMultipartFileRequest("/v1/media", "file", "photo.jpg", []byte("fake-bytes"), nil))
			rec := httptest.NewRecorder()
			mediaRouterFor(h).ServeHTTP(rec, req)
			if rec.Code != tc.wantStatus {
				t.Errorf("expected %d, got %d: %s", tc.wantStatus, rec.Code, rec.Body.String())
			}
		})
	}
}
