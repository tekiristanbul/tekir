package handler

import (
	"context"
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// FollowsManager is satisfied by service.FollowsService; kept as an
// interface so the handler is testable without a real database connection.
type FollowsManager interface {
	Follow(ctx context.Context, catID, deviceID string) error
	Unfollow(ctx context.Context, catID, deviceID string) error
	ListFollows(ctx context.Context, deviceID string) ([]service.CatMarker, error)
}

// FollowsHandler handles device-owned cat follow/unfollow/list (issue #44).
// Every route it serves must run behind RequireDeviceToken — DeviceFromContext
// is the only source of ownership these handlers ever use.
type FollowsHandler struct {
	follows FollowsManager
}

func NewFollowsHandler(follows FollowsManager) *FollowsHandler {
	return &FollowsHandler{follows: follows}
}

// Follow answers POST /v1/cats/{cat_id}/follow: the device identified by
// X-Device-Token follows the cat. Idempotent — a repeat follow still
// answers 204. Unknown cat_id → 404; malformed cat_id → 400.
func (h *FollowsHandler) Follow(w http.ResponseWriter, r *http.Request) {
	device := DeviceFromContext(r.Context())
	if err := h.follows.Follow(r.Context(), chi.URLParam(r, "cat_id"), device.DeviceID); err != nil {
		writeFollowsServiceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// Unfollow answers DELETE /v1/cats/{cat_id}/follow: removes the resolved
// device's follow of the cat, if any. Idempotent — unfollowing a cat this
// device doesn't follow still answers 204. Unknown cat_id → 404; malformed
// cat_id → 400.
func (h *FollowsHandler) Unfollow(w http.ResponseWriter, r *http.Request) {
	device := DeviceFromContext(r.Context())
	if err := h.follows.Unfollow(r.Context(), chi.URLParam(r, "cat_id"), device.DeviceID); err != nil {
		writeFollowsServiceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ListFollows answers GET /v1/me/follows: the resolved device's own
// followed cats, ordered by most recent cat activity, in the same
// map/detail cat-summary shape as GET /v1/cats — never another device's
// follows.
func (h *FollowsHandler) ListFollows(w http.ResponseWriter, r *http.Request) {
	device := DeviceFromContext(r.Context())
	cats, err := h.follows.ListFollows(r.Context(), device.DeviceID)
	if err != nil {
		writeFollowsServiceError(w, err)
		return
	}

	resp := make([]catMarkerResponse, 0, len(cats))
	for _, c := range cats {
		resp = append(resp, catMarkerResponse{
			ID:           c.ID,
			Name:         c.Name,
			PrimaryPhoto: c.PrimaryPhoto,
			Area:         areaLatLng{Lat: c.Lat, Lng: c.Lng},
			AreaLabel:    c.AreaLabel,
			ActiveAlert:  toActiveAlertResponse(c.ActiveAlert),
			LastUpdateAt: c.LastUpdateAt,
		})
	}
	writeJSON(w, http.StatusOK, resp)
}

func writeFollowsServiceError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, service.ErrInvalidCatID):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid cat id"})
	case errors.Is(err, service.ErrCatNotFound):
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "cat not found"})
	default:
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
}
