package handler

import (
	"context"
	"errors"
	"mime"
	"net/http"
	"path/filepath"

	"github.com/go-chi/chi/v5"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// LocalObjectReader is satisfied by *service.FakeObjectStore. Only the
// fake/local object-storage provider ever needs GET /v1/media/objects/{key}
// — a real s3-compatible provider serves reads from its own public/signed
// urls directly, never proxied back through this api (see
// docs/architecture/backend.md's OBJECT_STORAGE_PROVIDER).
type LocalObjectReader interface {
	Get(ctx context.Context, key string) ([]byte, error)
}

// MediaServeHandler answers GET /v1/media/objects/{key}: the local/dev
// "controlled read delivery" path for media stored by FakeObjectStore
// (issue #70 — media is public per docs/product/privacy.md, so this route
// needs no auth; it exists purely so a local manual walkthrough or test can
// actually view an uploaded photo without a real object-storage account).
type MediaServeHandler struct {
	objects LocalObjectReader
}

func NewMediaServeHandler(objects LocalObjectReader) *MediaServeHandler {
	return &MediaServeHandler{objects: objects}
}

func (h *MediaServeHandler) ServeObject(w http.ResponseWriter, r *http.Request) {
	key := chi.URLParam(r, "key")
	data, err := h.objects.Get(r.Context(), key)
	if err != nil {
		if errors.Is(err, service.ErrObjectNotFound) || errors.Is(err, service.ErrInvalidObjectKey) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "object not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}

	contentType := mime.TypeByExtension(filepath.Ext(key))
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	w.Header().Set("Content-Type", contentType)
	// This is a public route serving whatever object_key the client itself
	// chose an extension for at upload time (see mediaPipeline.process) —
	// nosniff stops a browser from ever second-guessing that declared type
	// into something executable, on the off chance a non-image ever ends
	// up in the store.
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}
