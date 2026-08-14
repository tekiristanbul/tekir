package handler

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// MediaUploader is satisfied by service.MediaService; kept as an interface
// so the handler is testable without a real database or object store.
type MediaUploader interface {
	Upload(ctx context.Context, userID, deviceID string, idempotencyKey *string, raw []byte, muted bool) (service.Media, error)
}

// MediaHandler handles standalone media uploads (POST /v1/media, issue
// #70; extended to accept video by issue #153). A cat's own initial photo
// is uploaded as part of POST /v1/cats instead (see CatsHandler.Create),
// image-only — this endpoint is for media independent of cat creation, an
// ordinary update's optional photo or video attachment (updates.media_id).
type MediaHandler struct {
	media          MediaUploader
	maxUploadBytes int64
}

func NewMediaHandler(media MediaUploader, maxUploadBytes int) *MediaHandler {
	return &MediaHandler{media: media, maxUploadBytes: int64(maxUploadBytes) + multipartOverheadBytes}
}

type mediaResponse struct {
	MediaID string `json:"media_id"`
	URL     string `json:"url"`
	Muted   bool   `json:"muted"`
}

// Upload answers POST /v1/media: a multipart request with a required file
// field. Ownership is always resolved from the authenticated bearer session
// (see RequireBearer) and the optional X-Device-Token (see
// OptionalDeviceToken) — never from the request body. An optional
// Idempotency-Key header makes a retried request return the original
// result instead of creating a second media row. An optional "muted" form
// field (issue #194) is the uploader's own audio choice for a video
// attachment, defaulting true (short-form videos default to muted) when
// absent or unparseable — meaningless for a photo but accepted the same
// way regardless.
func (h *MediaHandler) Upload(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, h.maxUploadBytes)
	if err := r.ParseMultipartForm(multipartMemoryThreshold); err != nil {
		writeMultipartParseError(w, err)
		return
	}

	var idempotencyKey *string
	if v := strings.TrimSpace(r.Header.Get("Idempotency-Key")); v != "" {
		idempotencyKey = &v
	}

	// muted (issue #194) defaults true — a short-form video defaults to
	// muted unless the composer's toggle explicitly sends "false" to opt
	// into audio. Any other or missing value stays the safe default rather
	// than rejecting the request over a malformed form field.
	muted := true
	if v := strings.TrimSpace(r.FormValue("muted")); v != "" {
		if parsed, err := strconv.ParseBool(v); err == nil {
			muted = parsed
		}
	}

	file, _, ferr := r.FormFile("file")
	if ferr != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "file is required"})
		return
	}
	defer func() { _ = file.Close() }()
	raw, err := io.ReadAll(file)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid file"})
		return
	}

	user := UserFromContext(r.Context())
	device := DeviceFromContext(r.Context())
	media, err := h.media.Upload(r.Context(), user.UserID, device.DeviceID, idempotencyKey, raw, muted)
	if err != nil {
		writeMediaServiceError(w, err)
		return
	}

	writeJSON(w, http.StatusCreated, mediaResponse{MediaID: media.ID, URL: media.URL, Muted: media.Muted})
}

func writeMediaServiceError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, service.ErrMediaTooLarge):
		writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "file too large"})
	case errors.Is(err, service.ErrMediaDimensionsTooLarge):
		writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "file dimensions too large"})
	case errors.Is(err, service.ErrUnsupportedMediaType):
		writeJSON(w, http.StatusUnsupportedMediaType, map[string]string{"error": "unsupported file type"})
	case errors.Is(err, service.ErrMediaDurationTooLong):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "video too long"})
	case errors.Is(err, service.ErrMalformedMedia):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed file"})
	case errors.Is(err, service.ErrContentRejected):
		// issue #241: a stable, recoverable moderation rejection — never
		// echoes categories, provider identity, or model output.
		writeJSON(w, http.StatusUnprocessableEntity, map[string]string{"error": "content rejected"})
	default:
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
}
