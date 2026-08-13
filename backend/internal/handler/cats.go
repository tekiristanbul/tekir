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
// help state — null whenever there isn't one. Comment is the reporter's
// optional note (issue #101, contract issue #100), the field 0.2 clients
// read; Category/CategoryLabel are 0.1 compatibility fields (that client
// generation requires them non-null) — a legacy record serves its stored
// vocabulary value, a post-#101 mark the fixed "unspecified" pair.
type activeAlertResponse struct {
	Category      string    `json:"category"`
	CategoryLabel string    `json:"category_label"`
	Comment       *string   `json:"comment"`
	CreatedAt     time.Time `json:"created_at"`
	ExpiresAt     time.Time `json:"expires_at"`
}

type catDetailResponse struct {
	ID           string     `json:"id"`
	Name         string     `json:"name"`
	Area         areaLatLng `json:"area"`
	AreaLabel    *string    `json:"area_label"`
	PrimaryPhoto *string    `json:"primary_photo"`
	CreatedAt    time.Time  `json:"created_at"`
	LastUpdateAt *time.Time `json:"last_update_at"`
	// LastSeenAt/LastFedAt/LastWaterAt (issue #121) back the cat-profile
	// three-stat header — each null when the cat has never had an update
	// carrying that status.
	LastSeenAt  *time.Time           `json:"last_seen_at"`
	LastFedAt   *time.Time           `json:"last_fed_at"`
	LastWaterAt *time.Time           `json:"last_water_at"`
	ActiveAlert *activeAlertResponse `json:"active_alert"`
	// MediaCount (issue #121's cover photo-counter parity gap) is the size
	// of the cat's photo archive (GET /v1/cats/{cat_id}/media) — the
	// design's cover pill count and the "medya N" tab label.
	MediaCount int `json:"media_count"`
	// IsOwner (issue #156) is true only for the cat's own creator's
	// authenticated read — false for a guest read or any other account.
	// The client uses this, and only this, to decide whether to offer the
	// "change cover photo" affordance; PATCH /v1/cats/{cat_id}/cover
	// re-checks ownership server-side regardless.
	IsOwner bool `json:"is_owner"`
}

// updateResponse is one entry of a cat's newest-first history. NeedsHelp
// (issue #101, contract issue #100) is the combined-model flag 0.2 clients
// read — an update may carry statuses, the flag, or both. Kind is derived
// from the flag ("needs_help" whenever it is set) so a 0.1 client renders
// a help-carrying entry through its needs-help branch; NeedsHelpCategory/
// -Label are that generation's required compat fields (a legacy record's
// stored vocabulary value, or the fixed "unspecified" pair). NeedsHelp*
// lifecycle fields are populated exactly when the flag is set;
// NeedsHelpActive is server-decided, never left to a client clock.
type updateResponse struct {
	ID                     string     `json:"id"`
	Kind                   string     `json:"kind"`
	Statuses               []string   `json:"statuses"`
	Comment                *string    `json:"comment"`
	CreatedAt              time.Time  `json:"created_at"`
	UpdatedAt              *time.Time `json:"updated_at,omitempty"`
	NeedsHelp              bool       `json:"needs_help"`
	NeedsHelpCategory      *string    `json:"needs_help_category"`
	NeedsHelpCategoryLabel *string    `json:"needs_help_category_label"`
	NeedsHelpExpiresAt     *time.Time `json:"needs_help_expires_at"`
	NeedsHelpActive        *bool      `json:"needs_help_active"`
	// AuthorDisplayName (issue #121's timeline-avatar parity gap) is the
	// author's display name, null when the row has no author or the
	// author never set one — the client falls back to a generic avatar,
	// never inventing a name or initial.
	AuthorDisplayName *string `json:"author_display_name"`
	// PhotoURL (issue #121's timeline-thumbnail parity gap, wired up by
	// issue #153) is the url of the media this update carries, null when it
	// carries none — despite the name, this is set for both a photo and a
	// video attachment; MediaContentType is what tells them apart.
	PhotoURL *string `json:"photo_url"`
	// MediaContentType (issue #153's video support) is null under the same
	// conditions as PhotoURL; the client checks whether it starts with
	// "video/" to render a video player instead of an image widget.
	MediaContentType *string `json:"media_content_type"`
	// AuthorIsMe/CorrectionExpiresAt (issue #80): on GET
	// /v1/cats/{cat_id}/updates (OptionalBearer), both stay their zero
	// value (false/null) for a guest read. This same struct also backs
	// POST .../updates and PATCH .../updates/{id}'s own responses — both
	// always set AuthorIsMe true and a real CorrectionExpiresAt, since the
	// caller who just created or corrected an update is, by construction,
	// its author.
	AuthorIsMe          bool       `json:"author_is_me"`
	CorrectionExpiresAt *time.Time `json:"correction_expires_at"`
}

func toActiveAlertResponse(a *service.ActiveAlert) *activeAlertResponse {
	if a == nil {
		return nil
	}
	return &activeAlertResponse{
		Category:      a.Category,
		CategoryLabel: a.CategoryLabel,
		Comment:       a.Comment,
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

// discoverCatResponse is one entry of GET /v1/cats/discover's paginated
// result (issue #82) — the same map-marker-preview fields catMarkerResponse
// carries, minus area (this is a distance-ordered list, not a viewport —
// tapping an entry opens the existing cat-detail flow, which fetches its
// own coordinates), plus DistanceMeters, the field this endpoint adds.
type discoverCatResponse struct {
	ID             string               `json:"id"`
	Name           string               `json:"name"`
	PrimaryPhoto   string               `json:"primary_photo"`
	AreaLabel      *string              `json:"area_label"`
	DistanceMeters float64              `json:"distance_meters"`
	ActiveAlert    *activeAlertResponse `json:"active_alert"`
	LastUpdateAt   *time.Time           `json:"last_update_at"`
}

// discoverPageResponse is GET /v1/cats/discover's page envelope — the same
// shape as updateHistoryResponse: NextCursor is null once the last page has
// been served.
type discoverPageResponse struct {
	Items      []discoverCatResponse `json:"items"`
	NextCursor *string               `json:"next_cursor"`
}

// Discover answers GET /v1/cats/discover?lat=&lng=&filter=nearby|needs_help
// &cursor=&limit= (issue #82): the location-aware half of the mvp discover
// screen's three surfaces (docs/product/discovery.md) — every active cat,
// or only those with a currently active needs-help alert, nearest first
// from the caller's own (lat, lng). Public: like GET /v1/cats' bbox mode
// and GET /v1/cats/nearby, a guest reaches this with no bearer at all — the
// third discovery surface (followed cats) is the only one that requires an
// account, and it stays on GET /v1/me/follows, never this endpoint.
func (h *CatsHandler) Discover(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	lat, lng, err := parseLatLng(q.Get("lat"), q.Get("lng"))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	filter := q.Get("filter")

	limit := 0
	if raw := q.Get("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "limit must be an integer"})
			return
		}
		limit = parsed
	}

	page, err := h.cats.ListDiscover(r.Context(), filter, lat, lng, q.Get("cursor"), limit)
	if err != nil {
		writeCatsServiceError(w, err)
		return
	}

	items := make([]discoverCatResponse, 0, len(page.Items))
	for _, c := range page.Items {
		items = append(items, discoverCatResponse{
			ID:             c.ID,
			Name:           c.Name,
			PrimaryPhoto:   c.PrimaryPhoto,
			AreaLabel:      c.AreaLabel,
			DistanceMeters: c.DistanceMeters,
			ActiveAlert:    toActiveAlertResponse(c.ActiveAlert),
			LastUpdateAt:   c.LastUpdateAt,
		})
	}

	var nextCursor *string
	if page.NextCursor != "" {
		nextCursor = &page.NextCursor
	}
	writeJSON(w, http.StatusOK, discoverPageResponse{Items: items, NextCursor: nextCursor})
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
// OptionalBearer (issue #156) resolves the caller's own account when a
// valid bearer is presented, without requiring one — a guest read is
// unaffected; it's used only to derive is_owner.
func (h *CatsHandler) Detail(w http.ResponseWriter, r *http.Request) {
	caller := UserFromContext(r.Context())
	detail, err := h.cats.GetCatDetail(r.Context(), chi.URLParam(r, "cat_id"), caller.UserID)
	if err != nil {
		writeCatsServiceError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, toCatDetailResponse(detail))
}

func toCatDetailResponse(detail service.CatDetail) catDetailResponse {
	return catDetailResponse{
		ID:           detail.ID,
		Name:         detail.Name,
		Area:         areaLatLng{Lat: detail.Lat, Lng: detail.Lng},
		AreaLabel:    detail.AreaLabel,
		PrimaryPhoto: detail.PrimaryPhoto,
		CreatedAt:    detail.CreatedAt,
		LastUpdateAt: detail.LastUpdateAt,
		LastSeenAt:   detail.LastSeenAt,
		LastFedAt:    detail.LastFedAt,
		LastWaterAt:  detail.LastWaterAt,
		ActiveAlert:  toActiveAlertResponse(detail.ActiveAlert),
		MediaCount:   detail.MediaCount,
		IsOwner:      detail.IsOwner,
	}
}

// catMediaResponse is one entry of GET /v1/cats/{cat_id}/media's newest-first
// photo archive (issue #121's media-archive/media-tab parity gap). IsCover
// mirrors the cat's primary_photo — the client renders the design's "ana"
// badge on exactly that entry. UploaderDisplayName (issue #154's
// media-attribution parity gap) mirrors updateResponse's own
// author_display_name field. MediaContentType (issue #179) mirrors
// updateResponse's own media_content_type — the client uses its
// `video/`/`image/` prefix to pick the thumbnail/viewer and to hide the
// "make cover" action for a video entry, which can never become the cover.
type catMediaResponse struct {
	ID                  string    `json:"id"`
	URL                 string    `json:"url"`
	MediaContentType    string    `json:"media_content_type"`
	IsCover             bool      `json:"is_cover"`
	CreatedAt           time.Time `json:"created_at"`
	UploaderDisplayName *string   `json:"uploader_display_name"`
}

// Media answers GET /v1/cats/{cat_id}/media with the cat's photo archive,
// newest-first — the "medya" tab's data source.
func (h *CatsHandler) Media(w http.ResponseWriter, r *http.Request) {
	items, err := h.cats.ListCatMedia(r.Context(), chi.URLParam(r, "cat_id"))
	if err != nil {
		writeCatsServiceError(w, err)
		return
	}

	resp := make([]catMediaResponse, 0, len(items))
	for _, m := range items {
		resp = append(resp, catMediaResponse{ID: m.ID, URL: m.URL, MediaContentType: m.ContentType, IsCover: m.IsCover, CreatedAt: m.CreatedAt, UploaderDisplayName: m.UploaderDisplayName})
	}
	writeJSON(w, http.StatusOK, resp)
}

// setCoverRequest is the body of PATCH /v1/cats/{cat_id}/cover (issue
// #156). DisallowUnknownFields rejects any client-supplied field beyond
// media_id, mirroring createUpdateRequest's own guarantee.
type setCoverRequest struct {
	MediaID string `json:"media_id"`
}

// SetCover answers PATCH /v1/cats/{cat_id}/cover: the cat's own owning
// account promotes an existing entry from its media gallery (GET
// /v1/cats/{cat_id}/media) to be the cover photo. Only the cat's owner may
// do this (issue #156) — CatsService.SetCoverPhoto re-checks
// created_by_user_id against the authenticated caller server-side,
// regardless of what the client believes is_owner to be. media_id must
// already belong to this cat's own cat_media archive; the update or photo
// it originally came from is never modified — only cats.primary_photo_id
// moves.
func (h *CatsHandler) SetCover(w http.ResponseWriter, r *http.Request) {
	var req setCoverRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	user := UserFromContext(r.Context())
	detail, err := h.cats.SetCoverPhoto(r.Context(), chi.URLParam(r, "cat_id"), user.UserID, req.MediaID)
	if err != nil {
		writeCatsServiceError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, toCatDetailResponse(detail))
}

// renameCatRequest is the body of PATCH /v1/cats/{cat_id} (issue #199).
// DisallowUnknownFields rejects any client-supplied field beyond name,
// mirroring setCoverRequest's own guarantee — nothing else about the cat is
// ever alterable through this path.
type renameCatRequest struct {
	Name string `json:"name"`
}

// Rename answers PATCH /v1/cats/{cat_id}: the cat's own owning account
// corrects the cat's name (issue #199) — a recovery path for a naming
// mistake made at creation time. Only the cat's owner may do this;
// CatsService.RenameCat re-checks created_by_user_id against the
// authenticated caller server-side, regardless of what the client believes.
// Nothing else about the cat (media, updates, location, ownership, or
// unrelated timestamps) changes.
func (h *CatsHandler) Rename(w http.ResponseWriter, r *http.Request) {
	var req renameCatRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	user := UserFromContext(r.Context())
	detail, err := h.cats.RenameCat(r.Context(), chi.URLParam(r, "cat_id"), user.UserID, req.Name)
	if err != nil {
		writeCatsServiceError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, toCatDetailResponse(detail))
}

// Delete answers DELETE /v1/cats/{cat_id}: the cat's own owning account
// soft-deletes it (issue #200) — a terminal state with no restore/
// reactivate flow. CatsService.DeleteCat re-checks created_by_user_id
// against the authenticated caller server-side, regardless of what the
// client believes, and treats a retry against an already-deleted cat as a
// safe no-op rather than an error, so this handler always answers 204 on
// success, first call or repeated.
func (h *CatsHandler) Delete(w http.ResponseWriter, r *http.Request) {
	user := UserFromContext(r.Context())
	if err := h.cats.DeleteCat(r.Context(), chi.URLParam(r, "cat_id"), user.UserID); err != nil {
		writeCatsServiceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
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

	caller := UserFromContext(r.Context())
	page, err := h.cats.ListCatUpdates(r.Context(), chi.URLParam(r, "cat_id"), r.URL.Query().Get("cursor"), limit, caller.UserID)
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
		UpdatedAt:              u.UpdatedAt,
		NeedsHelp:              u.NeedsHelp,
		NeedsHelpCategory:      u.NeedsHelpCategory,
		NeedsHelpCategoryLabel: u.NeedsHelpCategoryLabel,
		NeedsHelpExpiresAt:     u.NeedsHelpExpiresAt,
		NeedsHelpActive:        u.NeedsHelpActive,
		AuthorDisplayName:      u.AuthorDisplayName,
		PhotoURL:               u.PhotoURL,
		MediaContentType:       u.MediaContentType,
		AuthorIsMe:             u.AuthorIsMe,
		CorrectionExpiresAt:    u.CorrectionExpiresAt,
	}
}

// createUpdateRequest is the body of POST /v1/cats/{cat_id}/updates
// (issue #36; needs_help added by issue #101's combined help model — a
// bare boolean, no category, per the issue #100 contract; media_id added
// by issue #153 — a caller optionally attaches a photo already uploaded
// via POST /v1/media, never raw media bytes here).
// DisallowUnknownFields rejects any client-supplied kind, category,
// expiry, timestamp, sequence, or author field outright — those are always
// server-derived, never accepted from the caller.
type createUpdateRequest struct {
	Statuses  []string `json:"statuses"`
	NeedsHelp bool     `json:"needs_help"`
	Comment   *string  `json:"comment"`
	MediaID   *string  `json:"media_id"`
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

	// issue #80 (product-owner review): an optional Idempotency-Key lets a
	// retried request (a duplicate network retry, or a fast double-tap of
	// the "Gördüm" shortcut before the first response returns) resolve to
	// the original update instead of creating a second one — mirrors
	// CatsHandler.Create's identical header handling.
	var idempotencyKey *string
	if v := strings.TrimSpace(r.Header.Get("Idempotency-Key")); v != "" {
		idempotencyKey = &v
	}

	user := UserFromContext(r.Context())
	device := DeviceFromContext(r.Context())
	update, err := h.cats.CreateOrdinaryUpdate(r.Context(), chi.URLParam(r, "cat_id"), user.UserID, device.DeviceID, idempotencyKey, req.Statuses, req.NeedsHelp, req.Comment, req.MediaID)
	if err != nil {
		writeCatsServiceError(w, err)
		return
	}

	writeJSON(w, http.StatusCreated, toUpdateResponse(update))
}

// createNeedsHelpRequest is the body of POST /v1/cats/{cat_id}/needs-help
// (issue #78). DisallowUnknownFields rejects any client-supplied kind,
// expires_at, or active — all server-derived, mirroring createUpdateRequest.
type createNeedsHelpRequest struct {
	Category string  `json:"category"`
	Comment  *string `json:"comment"`
}

// CreateNeedsHelp answers POST /v1/cats/{cat_id}/needs-help: records a new
// needs-help report for the cat, attributed to the authenticated account
// resolved from the caller's Authorization: Bearer, exactly like
// CreateUpdate — a needs-help report requires the same authenticated
// account, never guest/device-only, per issue #78's gate-at-intent
// requirement.
func (h *CatsHandler) CreateNeedsHelp(w http.ResponseWriter, r *http.Request) {
	var req createNeedsHelpRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	user := UserFromContext(r.Context())
	device := DeviceFromContext(r.Context())
	update, err := h.cats.CreateNeedsHelpUpdate(r.Context(), chi.URLParam(r, "cat_id"), user.UserID, device.DeviceID, req.Category, req.Comment)
	if err != nil {
		writeCatsServiceError(w, err)
		return
	}

	writeJSON(w, http.StatusCreated, toUpdateResponse(update))
}

// optionalString distinguishes a JSON field that was absent from one that
// was an explicit null (issue #105): PATCH preserves an omitted comment
// but clears an explicitly-null one — a plain *string can't tell those
// apart after decoding.
type optionalString struct {
	Set   bool
	Value *string
}

func (o *optionalString) UnmarshalJSON(data []byte) error {
	o.Set = true
	return json.Unmarshal(data, &o.Value)
}

// correctUpdateRequest is the body of PATCH /v1/cats/{cat_id}/updates/{update_id}
// (issue #80). DisallowUnknownFields rejects any client-supplied kind,
// author, created_at, or deleted_at — none of those are ever alterable
// through this path, mirroring createUpdateRequest's own guarantee.
// Every field is presence-aware (issue #105): an omitted field preserves
// the row's existing value, so a patch carrying only {"needs_help": false}
// removes the help mark without touching statuses or comment. Statuses
// nil (absent or JSON null) preserves the existing set; an explicit []
// clears it, valid only while the help flag survives. NeedsHelp (issue
// #101) is a three-state field: absent leaves the row's help mark
// untouched (a 0.1 client's PATCH never carries it), false removes the
// mark within the same 10-minute window, and true is rejected outright —
// help is only ever marked at creation, never added by an edit.
type correctUpdateRequest struct {
	Statuses  *[]string      `json:"statuses"`
	NeedsHelp *bool          `json:"needs_help"`
	Comment   optionalString `json:"comment"`
}

// CorrectUpdate answers PATCH /v1/cats/{cat_id}/updates/{update_id}: the
// caller corrects their own ordinary update within the fixed 10-minute
// window (docs/product/updates.md). Authorization (author match) and the
// window check both happen server-side, against the server's own clock —
// never trusted from the request.
func (h *CatsHandler) CorrectUpdate(w http.ResponseWriter, r *http.Request) {
	var req correctUpdateRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	if req.NeedsHelp != nil && *req.NeedsHelp {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "needs_help can only be cleared"})
		return
	}

	user := UserFromContext(r.Context())
	update, err := h.cats.CorrectOwnUpdate(r.Context(), chi.URLParam(r, "cat_id"), chi.URLParam(r, "update_id"), user.UserID, service.UpdateCorrection{
		Statuses:       req.Statuses,
		ClearNeedsHelp: req.NeedsHelp != nil && !*req.NeedsHelp,
		SetComment:     req.Comment.Set,
		Comment:        req.Comment.Value,
	})
	if err != nil {
		writeCatsServiceError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, toUpdateResponse(update))
}

// DeleteUpdate answers DELETE /v1/cats/{cat_id}/updates/{update_id}: the
// caller soft-deletes their own ordinary update within the fixed 10-minute
// window. A retry against an already-deleted row also answers 204 — see
// service.CatsService.DeleteOwnUpdate's idempotent-retry note. 409 when the
// update's attached media is still the cat's current cover — the caller
// must change the cover first, then retry (service.ErrUpdateHoldsCover).
func (h *CatsHandler) DeleteUpdate(w http.ResponseWriter, r *http.Request) {
	user := UserFromContext(r.Context())
	if err := h.cats.DeleteOwnUpdate(r.Context(), chi.URLParam(r, "cat_id"), chi.URLParam(r, "update_id"), user.UserID); err != nil {
		writeCatsServiceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
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
	case errors.Is(err, service.ErrInvalidNeedsHelpCategory):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid needs-help category"})
	case errors.Is(err, service.ErrNoteTooLong):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "needs-help note too long"})
	case errors.Is(err, service.ErrInvalidArea):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid area"})
	case errors.Is(err, service.ErrInvalidDiscoverFilter):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid discover filter"})
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
	case errors.Is(err, service.ErrUpdateNotFound):
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "update not found"})
	case errors.Is(err, service.ErrNotUpdateAuthor):
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "not the update author"})
	case errors.Is(err, service.ErrCorrectionWindowExpired):
		writeJSON(w, http.StatusGone, map[string]string{"error": "correction window expired"})
	case errors.Is(err, service.ErrUpdateHoldsCover):
		writeJSON(w, http.StatusConflict, map[string]string{"error": "update holds cat's current cover"})
	case errors.Is(err, service.ErrMediaNotFound):
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "media not found"})
	case errors.Is(err, service.ErrNotCatOwner):
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "not the cat owner"})
	case errors.Is(err, service.ErrInvalidMediaID):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid media id"})
	case errors.Is(err, service.ErrMediaNotInGallery):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "media not in cat gallery"})
	case errors.Is(err, service.ErrInvalidCatName):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid cat name"})
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
