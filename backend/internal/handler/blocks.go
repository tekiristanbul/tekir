package handler

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// Blocker is satisfied by service.BlocksService; kept as an interface so
// the handler is testable without a real database connection.
type Blocker interface {
	Block(ctx context.Context, blockerUserID, blockedUserID string) error
	Unblock(ctx context.Context, blockerUserID, blockedUserID string) error
	ListBlocked(ctx context.Context, blockerUserID string) ([]service.BlockedAccount, error)
}

// BlocksHandler exposes account-to-account blocking (issue #234) under
// /v1/me/blocks — the caller-owned namespace follows/notifications/profile
// already use. Every method requires RequireBearer: the blocker is always
// the authenticated caller, never a client-supplied account id, and a
// block list is only ever readable by the account that owns it.
type BlocksHandler struct {
	blocks Blocker
}

func NewBlocksHandler(blocks Blocker) *BlocksHandler {
	return &BlocksHandler{blocks: blocks}
}

// createBlockRequest is the body of POST /v1/me/blocks. DisallowUnknownFields
// rejects anything else — in particular there is no blocker field.
type createBlockRequest struct {
	BlockedUserID string `json:"blocked_user_id"`
}

type blockedAccountResponse struct {
	UserID      string    `json:"user_id"`
	DisplayName *string   `json:"display_name"`
	CreatedAt   time.Time `json:"created_at"`
}

// Create answers POST /v1/me/blocks: the caller blocks another account.
// Idempotent — blocking an already-blocked account answers 204 without
// creating anything. Blocking is visibility only: no content is deleted,
// and the blocked account is never told.
func (h *BlocksHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req createBlockRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	user := UserFromContext(r.Context())
	if err := h.blocks.Block(r.Context(), user.UserID, req.BlockedUserID); err != nil {
		writeBlocksServiceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// Delete answers DELETE /v1/me/blocks/{user_id}: the caller unblocks an
// account. Idempotent — unblocking an account that isn't blocked answers
// 204 too, since the end state the caller asked for is the state they get.
func (h *BlocksHandler) Delete(w http.ResponseWriter, r *http.Request) {
	user := UserFromContext(r.Context())
	if err := h.blocks.Unblock(r.Context(), user.UserID, chi.URLParam(r, "user_id")); err != nil {
		writeBlocksServiceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// List answers GET /v1/me/blocks with the caller's own blocks, newest
// first — the data behind the unblock screen.
func (h *BlocksHandler) List(w http.ResponseWriter, r *http.Request) {
	user := UserFromContext(r.Context())
	blocked, err := h.blocks.ListBlocked(r.Context(), user.UserID)
	if err != nil {
		writeBlocksServiceError(w, err)
		return
	}

	resp := make([]blockedAccountResponse, 0, len(blocked))
	for _, b := range blocked {
		resp = append(resp, blockedAccountResponse{UserID: b.UserID, DisplayName: b.DisplayName, CreatedAt: b.CreatedAt})
	}
	writeJSON(w, http.StatusOK, resp)
}

func writeBlocksServiceError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, service.ErrInvalidBlockedUserID):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid blocked user id"})
	case errors.Is(err, service.ErrCannotBlockSelf):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "cannot block yourself"})
	case errors.Is(err, service.ErrBlockedUserNotFound):
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "blocked user not found"})
	default:
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
}
