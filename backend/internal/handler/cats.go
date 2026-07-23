package handler

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

type CatsHandler struct {
	cats *service.CatsService
}

func NewCatsHandler(cats *service.CatsService) *CatsHandler {
	return &CatsHandler{cats: cats}
}

type catMarkerResponse struct {
	ID           string               `json:"id"`
	Name         string               `json:"name"`
	PrimaryPhoto string               `json:"primary_photo"`
	Area         areaLatLng           `json:"area"`
	AreaLabel    *string              `json:"area_label"`
	ActiveAlert  *activeAlertResponse `json:"active_alert"`
	LastUpdateAt *time.Time           `json:"last_update_at"`
}

type areaLatLng struct {
	Lat float64 `json:"lat"`
	Lng float64 `json:"lng"`
}

// activeAlertResponse is the map/cat-detail representation of an active
// needs-help alert (issue #4/#23) — null whenever there isn't one. Always
// the full category + lifecycle context, never a bare boolean, so a client
// never has to guess what "needs help" means.
type activeAlertResponse struct {
	Category      string    `json:"category"`
	CategoryLabel string    `json:"category_label"`
	CreatedAt     time.Time `json:"created_at"`
	ExpiresAt     time.Time `json:"expires_at"`
}

type catDetailResponse struct {
	ID           string               `json:"id"`
	Name         string               `json:"name"`
	Area         areaLatLng           `json:"area"`
	AreaLabel    *string              `json:"area_label"`
	PrimaryPhoto *string              `json:"primary_photo"`
	Traits       []traitResponse      `json:"traits"`
	CreatedAt    time.Time            `json:"created_at"`
	LastUpdateAt *time.Time           `json:"last_update_at"`
	ActiveAlert  *activeAlertResponse `json:"active_alert"`
}

type traitResponse struct {
	Key   string `json:"key"`
	Label string `json:"label"`
}

// updateResponse is one entry of a cat's newest-first history — either an
// ordinary status update (Statuses populated, NeedsHelp* all null) or a
// needs-help one (issue #4/#23: NeedsHelp* populated, Statuses empty).
// NeedsHelpActive is server-decided (never left for the client to derive
// from its own clock) and is only meaningful when Kind is "needs_help".
type updateResponse struct {
	ID                     string     `json:"id"`
	Kind                   string     `json:"kind"`
	Statuses               []string   `json:"statuses"`
	Comment                *string    `json:"comment"`
	CreatedAt              time.Time  `json:"created_at"`
	NeedsHelpCategory      *string    `json:"needs_help_category"`
	NeedsHelpCategoryLabel *string    `json:"needs_help_category_label"`
	NeedsHelpExpiresAt     *time.Time `json:"needs_help_expires_at"`
	NeedsHelpActive        *bool      `json:"needs_help_active"`
}

func toActiveAlertResponse(a *service.ActiveAlert) *activeAlertResponse {
	if a == nil {
		return nil
	}
	return &activeAlertResponse{
		Category:      a.Category,
		CategoryLabel: a.CategoryLabel,
		CreatedAt:     a.CreatedAt,
		ExpiresAt:     a.ExpiresAt,
	}
}

// updateHistoryResponse is GET /v1/cats/{cat_id}/updates' page envelope:
// NextCursor is null once the last page has been served, so clients never
// have to guess whether to request another page.
type updateHistoryResponse struct {
	Items      []updateResponse `json:"items"`
	NextCursor *string          `json:"next_cursor"`
}

// Nearby answers GET /v1/cats?bbox=minLng,minLat,maxLng,maxLat with the
// active cats inside the requested map viewport.
func (h *CatsHandler) Nearby(w http.ResponseWriter, r *http.Request) {
	bounds, err := parseBounds(r.URL.Query().Get("bbox"))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	markers, err := h.cats.ListNearby(r.Context(), bounds)
	if err != nil {
		if errors.Is(err, service.ErrInvalidBounds) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid bounds"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}

	resp := make([]catMarkerResponse, 0, len(markers))
	for _, m := range markers {
		resp = append(resp, catMarkerResponse{
			ID:           m.ID,
			Name:         m.Name,
			PrimaryPhoto: m.PrimaryPhoto,
			Area:         areaLatLng{Lat: m.Lat, Lng: m.Lng},
			AreaLabel:    m.AreaLabel,
			ActiveAlert:  toActiveAlertResponse(m.ActiveAlert),
			LastUpdateAt: m.LastUpdateAt,
		})
	}
	writeJSON(w, http.StatusOK, resp)
}

// Detail answers GET /v1/cats/{cat_id} with the cat-detail representation.
func (h *CatsHandler) Detail(w http.ResponseWriter, r *http.Request) {
	detail, err := h.cats.GetCatDetail(r.Context(), chi.URLParam(r, "cat_id"))
	if err != nil {
		writeCatsServiceError(w, err)
		return
	}

	traits := make([]traitResponse, 0, len(detail.Traits))
	for _, t := range detail.Traits {
		traits = append(traits, traitResponse{Key: t.Key, Label: t.Label})
	}

	writeJSON(w, http.StatusOK, catDetailResponse{
		ID:           detail.ID,
		Name:         detail.Name,
		Area:         areaLatLng{Lat: detail.Lat, Lng: detail.Lng},
		AreaLabel:    detail.AreaLabel,
		PrimaryPhoto: detail.PrimaryPhoto,
		Traits:       traits,
		CreatedAt:    detail.CreatedAt,
		LastUpdateAt: detail.LastUpdateAt,
		ActiveAlert:  toActiveAlertResponse(detail.ActiveAlert),
	})
}

// UpdateHistory answers GET /v1/cats/{cat_id}/updates?cursor=&limit= with one
// newest-first page of the cat's status-update history. cursor is the opaque
// next_cursor from a previous page; limit defaults to 20 and caps at 50 so a
// client can never pull an unbounded page.
func (h *CatsHandler) UpdateHistory(w http.ResponseWriter, r *http.Request) {
	limit := 0
	if raw := r.URL.Query().Get("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "limit must be an integer"})
			return
		}
		limit = parsed
	}

	page, err := h.cats.ListCatUpdates(r.Context(), chi.URLParam(r, "cat_id"), r.URL.Query().Get("cursor"), limit)
	if err != nil {
		writeCatsServiceError(w, err)
		return
	}

	items := make([]updateResponse, 0, len(page.Items))
	for _, u := range page.Items {
		items = append(items, updateResponse{
			ID:                     u.ID,
			Kind:                   u.Kind,
			Statuses:               u.Statuses,
			Comment:                u.Comment,
			CreatedAt:              u.CreatedAt,
			NeedsHelpCategory:      u.NeedsHelpCategory,
			NeedsHelpCategoryLabel: u.NeedsHelpCategoryLabel,
			NeedsHelpExpiresAt:     u.NeedsHelpExpiresAt,
			NeedsHelpActive:        u.NeedsHelpActive,
		})
	}

	var nextCursor *string
	if page.NextCursor != "" {
		nextCursor = &page.NextCursor
	}
	writeJSON(w, http.StatusOK, updateHistoryResponse{Items: items, NextCursor: nextCursor})
}

func writeCatsServiceError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, service.ErrInvalidCatID):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid cat id"})
	case errors.Is(err, service.ErrCatNotFound):
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "cat not found"})
	case errors.Is(err, service.ErrInvalidCursor):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid cursor"})
	case errors.Is(err, service.ErrInvalidLimit):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid limit"})
	default:
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
}

// parseBounds validates the shape of the bbox query param; range/order
// validation against the coordinate system happens in the service layer.
func parseBounds(raw string) (service.Bounds, error) {
	if raw == "" {
		return service.Bounds{}, errors.New("bbox is required")
	}

	parts := strings.Split(raw, ",")
	if len(parts) != 4 {
		return service.Bounds{}, errors.New("bbox must have 4 comma-separated values: min_lng,min_lat,max_lng,max_lat")
	}

	values := make([]float64, 4)
	for i, p := range parts {
		v, err := strconv.ParseFloat(strings.TrimSpace(p), 64)
		if err != nil {
			return service.Bounds{}, errors.New("bbox values must be numbers")
		}
		values[i] = v
	}

	return service.Bounds{
		MinLng: values[0],
		MinLat: values[1],
		MaxLng: values[2],
		MaxLat: values[3],
	}, nil
}
