package handler

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

type CatsHandler struct {
	cats *service.CatsService
}

func NewCatsHandler(cats *service.CatsService) *CatsHandler {
	return &CatsHandler{cats: cats}
}

type catMarkerResponse struct {
	ID           string     `json:"id"`
	PrimaryPhoto string     `json:"primary_photo"`
	Area         areaLatLng `json:"area"`
	NeedsHelp    bool       `json:"needs_help"`
	LastUpdateAt *time.Time `json:"last_update_at"`
}

type areaLatLng struct {
	Lat float64 `json:"lat"`
	Lng float64 `json:"lng"`
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
			PrimaryPhoto: m.PrimaryPhoto,
			Area:         areaLatLng{Lat: m.Lat, Lng: m.Lng},
			NeedsHelp:    m.NeedsHelp,
			LastUpdateAt: m.LastUpdateAt,
		})
	}
	writeJSON(w, http.StatusOK, resp)
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
