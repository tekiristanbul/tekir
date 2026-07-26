package handler

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

type CatsHandler struct {
	cats *service.CatsService
	// maxUploadBytes bounds POST /v1/cats' multipart request body via
	// http.MaxBytesReader — ParseMultipartForm's own maxMemory argument only
	// bounds what's kept in memory before spilling to disk, never the total
	// request size, so this is the actual defense against an oversized
	// request (issue #70). A margin above the photo's own byte-size limit
	// (see service.MediaService/CatsService's shared pipeline) covers the
	// surrounding multipart form fields/boundaries.
	maxUploadBytes int64
}

func NewCatsHandler(cats *service.CatsService, maxUploadBytes int) *CatsHandler {
	return &CatsHandler{cats: cats, maxUploadBytes: int64(maxUploadBytes) + multipartOverheadBytes}
}

// multipartOverheadBytes is generous headroom above the configured photo
// byte-size limit for the surrounding multipart form fields/boundaries —
// none of which are themselves large, but a fixed cap must allow for them.
const multipartOverheadBytes = 64 * 1024

// multipartMemoryThreshold is ParseMultipartForm's own maxMemory argument:
// how much of the (already size-capped, via http.MaxBytesReader above) body
// it keeps in memory before spilling the rest to a temp file. Distinct from
// maxUploadBytes, which bounds the request itself.
const multipartMemoryThreshold = 10 << 20

// writeMultipartParseError answers a ParseMultipartForm failure. An
// http.MaxBytesReader-triggered failure (the request body itself exceeded
// maxUploadBytes) is distinguishable from a genuinely malformed multipart
// body via *http.MaxBytesError — worth a distinct 413 so a client isn't
// left guessing whether its photo was too large or its request was simply
// broken.
func writeMultipartParseError(w http.ResponseWriter, err error) {
	var tooLarge *http.MaxBytesError
	if errors.As(err, &tooLarge) {
		writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "request too large"})
		return
	}
	writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid multipart form"})
}

// duplicateCandidateResponse is one entry of GET /v1/cats/nearby's array, and
// of POST /v1/cats' 409 candidates list — the same shape both places
// (docs/architecture/api.md).
type duplicateCandidateResponse struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	PrimaryPhoto string `json:"primary_photo"`
}

func toDuplicateCandidateResponses(candidates []service.DuplicateCandidate) []duplicateCandidateResponse {
	resp := make([]duplicateCandidateResponse, 0, len(candidates))
	for _, c := range candidates {
		resp = append(resp, duplicateCandidateResponse{ID: c.ID, Name: c.Name, PrimaryPhoto: c.PrimaryPhoto})
	}
	return resp
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
	CreatedAt    time.Time            `json:"created_at"`
	LastUpdateAt *time.Time           `json:"last_update_at"`
	ActiveAlert  *activeAlertResponse `json:"active_alert"`
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

// NearbyDuplicates answers GET /v1/cats/nearby?lat&lng&radius=50 — the
// add-cat flow's non-blocking duplicate-candidate check
// (docs/architecture/api.md). Public: a guest reaches this in the add-cat
// flow up to the moment the auth gate requires signing in (issue #70),
// same as any other public read.
func (h *CatsHandler) NearbyDuplicates(w http.ResponseWriter, r *http.Request) {
	lat, lng, err := parseLatLng(r.URL.Query().Get("lat"), r.URL.Query().Get("lng"))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	candidates, err := h.cats.ListNearbyDuplicates(r.Context(), lat, lng)
	if err != nil {
		writeCatsServiceError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toDuplicateCandidateResponses(candidates))
}

// createCatResponse wraps the created cat per docs/architecture/api.md's
// `201 { cat }` sketch.
type createCatResponse struct {
	Cat catDetailResponse `json:"cat"`
}

// duplicateCandidatesResponse wraps the 409 candidates list per
// docs/architecture/api.md's `409 { candidates:[...] }` sketch.
type duplicateCandidatesResponse struct {
	Candidates []duplicateCandidateResponse `json:"candidates"`
}

// Create answers POST /v1/cats: a multipart request with lat/lng form
// fields (area), a required photo file, an optional name, and an optional
// confirmed_new flag ("true" to proceed past a duplicate-candidate match —
// docs/architecture/api.md's confirmed_new). Ownership is always resolved
// from the authenticated bearer session (see RequireBearer) and the
// optional X-Device-Token (see OptionalDeviceToken) — never from the
// request body. An optional Idempotency-Key header makes a retried request
// return the original result instead of creating a second cat.
func (h *CatsHandler) Create(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, h.maxUploadBytes)
	if err := r.ParseMultipartForm(multipartMemoryThreshold); err != nil {
		writeMultipartParseError(w, err)
		return
	}

	lat, lng, err := parseLatLng(r.FormValue("lat"), r.FormValue("lng"))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	var name *string
	if v := strings.TrimSpace(r.FormValue("name")); v != "" {
		name = &v
	}
	confirmedNew := r.FormValue("confirmed_new") == "true"

	var idempotencyKey *string
	if v := strings.TrimSpace(r.Header.Get("Idempotency-Key")); v != "" {
		idempotencyKey = &v
	}

	file, _, ferr := r.FormFile("photo")
	if ferr != nil {
		writeCatsServiceError(w, service.ErrMissingPhoto)
		return
	}
	defer func() { _ = file.Close() }()
	photoBytes, err := io.ReadAll(file)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid photo"})
		return
	}

	user := UserFromContext(r.Context())
	device := DeviceFromContext(r.Context())
	cat, err := h.cats.Create(r.Context(), user.UserID, device.DeviceID, idempotencyKey, lat, lng, name, confirmedNew, photoBytes)
	if err != nil {
		var dupErr *service.DuplicateCandidatesError
		if errors.As(err, &dupErr) {
			writeJSON(w, http.StatusConflict, duplicateCandidatesResponse{Candidates: toDuplicateCandidateResponses(dupErr.Candidates)})
			return
		}
		writeCatsServiceError(w, err)
		return
	}

	writeJSON(w, http.StatusCreated, createCatResponse{Cat: catDetailResponse{
		ID:           cat.ID,
		Name:         cat.Name,
		Area:         areaLatLng{Lat: cat.Lat, Lng: cat.Lng},
		AreaLabel:    cat.AreaLabel,
		PrimaryPhoto: cat.PrimaryPhoto,
		CreatedAt:    cat.CreatedAt,
		LastUpdateAt: cat.LastUpdateAt,
		ActiveAlert:  toActiveAlertResponse(cat.ActiveAlert),
	}})
}

// parseLatLng parses required lat/lng values shared by GET /v1/cats/nearby
// and POST /v1/cats' area field.
func parseLatLng(rawLat, rawLng string) (lat, lng float64, err error) {
	lat, err = strconv.ParseFloat(rawLat, 64)
	if err != nil {
		return 0, 0, errors.New("lat is required and must be a number")
	}
	lng, err = strconv.ParseFloat(rawLng, 64)
	if err != nil {
		return 0, 0, errors.New("lng is required and must be a number")
	}
	return lat, lng, nil
}

// Detail answers GET /v1/cats/{cat_id} with the cat-detail representation.
func (h *CatsHandler) Detail(w http.ResponseWriter, r *http.Request) {
	detail, err := h.cats.GetCatDetail(r.Context(), chi.URLParam(r, "cat_id"))
	if err != nil {
		writeCatsServiceError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, catDetailResponse{
		ID:           detail.ID,
		Name:         detail.Name,
		Area:         areaLatLng{Lat: detail.Lat, Lng: detail.Lng},
		AreaLabel:    detail.AreaLabel,
		PrimaryPhoto: detail.PrimaryPhoto,
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
		items = append(items, toUpdateResponse(u))
	}

	var nextCursor *string
	if page.NextCursor != "" {
		nextCursor = &page.NextCursor
	}
	writeJSON(w, http.StatusOK, updateHistoryResponse{Items: items, NextCursor: nextCursor})
}

func toUpdateResponse(u service.CatUpdate) updateResponse {
	return updateResponse{
		ID:                     u.ID,
		Kind:                   u.Kind,
		Statuses:               u.Statuses,
		Comment:                u.Comment,
		CreatedAt:              u.CreatedAt,
		NeedsHelpCategory:      u.NeedsHelpCategory,
		NeedsHelpCategoryLabel: u.NeedsHelpCategoryLabel,
		NeedsHelpExpiresAt:     u.NeedsHelpExpiresAt,
		NeedsHelpActive:        u.NeedsHelpActive,
	}
}

// createUpdateRequest is the body of POST /v1/cats/{cat_id}/updates
// (issue #36). DisallowUnknownFields rejects any client-supplied kind,
// media, needs-help, timestamp, sequence, or author field outright — those
// are always server-derived, never accepted from the caller.
type createUpdateRequest struct {
	Statuses []string `json:"statuses"`
	Comment  *string  `json:"comment"`
}

// CreateUpdate answers POST /v1/cats/{cat_id}/updates: records a new
// ordinary status update for the cat, attributed to the authenticated
// account resolved from the caller's Authorization: Bearer (see
// RequireBearer). An optional X-Device-Token (see OptionalDeviceToken) is
// recorded alongside it purely for installation/abuse-control association
// — it is never sufficient authorization on its own (issue #65).
func (h *CatsHandler) CreateUpdate(w http.ResponseWriter, r *http.Request) {
	var req createUpdateRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	user := UserFromContext(r.Context())
	device := DeviceFromContext(r.Context())
	update, err := h.cats.CreateOrdinaryUpdate(r.Context(), chi.URLParam(r, "cat_id"), user.UserID, device.DeviceID, req.Statuses, req.Comment)
	if err != nil {
		writeCatsServiceError(w, err)
		return
	}

	writeJSON(w, http.StatusCreated, toUpdateResponse(update))
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
	case errors.Is(err, service.ErrInvalidStatuses):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid statuses"})
	case errors.Is(err, service.ErrInvalidArea):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid area"})
	case errors.Is(err, service.ErrMissingPhoto):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "photo is required"})
	case errors.Is(err, service.ErrMediaTooLarge):
		writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "photo too large"})
	case errors.Is(err, service.ErrMediaDimensionsTooLarge):
		writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "photo dimensions too large"})
	case errors.Is(err, service.ErrUnsupportedMediaType):
		writeJSON(w, http.StatusUnsupportedMediaType, map[string]string{"error": "unsupported photo type"})
	case errors.Is(err, service.ErrMalformedMedia):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed photo"})
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
