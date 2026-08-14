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
	capturedMuted          *bool
}

func (f fakeMediaUploader) Upload(_ context.Context, userID, deviceID string, idempotencyKey *string, _ []byte, muted bool) (service.Media, error) {
	if f.capturedUserID != nil {
		*f.capturedUserID = userID
	}
	if f.capturedDeviceID != nil {
		*f.capturedDeviceID = deviceID
	}
	if f.capturedIdempotencyKey != nil {
		*f.capturedIdempotencyKey = idempotencyKey
	}
	if f.capturedMuted != nil {
		*f.capturedMuted = muted
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

// TestMediaHandler_Upload_MutedDefaultsTrue proves a video (or any) upload
// that sends no "muted" form field is treated as muted (issue #194's
// product decision: short-form videos default to muted).
func TestMediaHandler_Upload_MutedDefaultsTrue(t *testing.T) {
	var captured bool
	uploader := fakeMediaUploader{capturedMuted: &captured}
	h := NewMediaHandler(uploader, 1<<20)

	req := withBearerToken(newMultipartFileRequest("/v1/media", "file", "video.mp4", []byte("fake-bytes"), nil))
	rec := httptest.NewRecorder()
	mediaRouterFor(h).ServeHTTP(rec, req)

	if !captured {
		t.Errorf("expected muted to default true when the form field is absent, got %v", captured)
	}
}

// TestMediaHandler_Upload_MutedRespectsExplicitField proves the composer's
// toggle can opt a video into audio by sending "muted=false", and can
// re-affirm the default explicitly with "muted=true".
func TestMediaHandler_Upload_MutedRespectsExplicitField(t *testing.T) {
	cases := []struct {
		field string
		want  bool
	}{
		{"false", false},
		{"true", true},
	}
	for _, tc := range cases {
		t.Run(tc.field, func(t *testing.T) {
			var captured bool
			uploader := fakeMediaUploader{capturedMuted: &captured}
			h := NewMediaHandler(uploader, 1<<20)

			req := withBearerToken(newMultipartFileRequest("/v1/media", "file", "video.mp4", []byte("fake-bytes"), map[string]string{"muted": tc.field}))
			rec := httptest.NewRecorder()
			mediaRouterFor(h).ServeHTTP(rec, req)

			if captured != tc.want {
				t.Errorf("expected muted=%v for form field %q, got %v", tc.want, tc.field, captured)
			}
		})
	}
}

// TestMediaHandler_Upload_ResponseIncludesMuted proves the created media's
// stored muted flag (as MediaUploader.Upload returns it, not the request's
// own field) is what the response actually echoes back.
func TestMediaHandler_Upload_ResponseIncludesMuted(t *testing.T) {
	uploader := fakeMediaUploader{media: service.Media{ID: "media-1", URL: "/v1/media/objects/x.mp4", Muted: false}}
	h := NewMediaHandler(uploader, 1<<20)

	req := withBearerToken(newMultipartFileRequest("/v1/media", "file", "video.mp4", []byte("fake-bytes"), map[string]string{"muted": "false"}))
	rec := httptest.NewRecorder()
	mediaRouterFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte(`"muted":false`)) {
		t.Errorf("expected response body to echo muted:false, got %s", rec.Body.String())
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
		{"content rejected", service.ErrContentRejected, http.StatusUnprocessableEntity},
		{"moderation unavailable", service.ErrModerationUnavailable, http.StatusInternalServerError},
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
