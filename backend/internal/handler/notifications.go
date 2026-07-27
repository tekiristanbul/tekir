package handler

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// NotificationInboxManager is satisfied by service.NotificationInboxService;
// kept as an interface so the handler is testable without a real database
// connection.
type NotificationInboxManager interface {
	ListMyNotifications(ctx context.Context, userID, cursor string, limit int) (service.NotificationsPage, error)
	MarkRead(ctx context.Context, userID, id string) error
}

// notificationResponse is one entry of GET /v1/me/notifications — the
// in-app representation of a needs-help update on a followed cat (issue
// #78: this mvp slice has no real push transport, see
// service.NotificationSender's doc comment).
type notificationResponse struct {
	ID        string    `json:"id"`
	CatID     string    `json:"cat_id"`
	UpdateID  string    `json:"update_id"`
	Read      bool      `json:"read"`
	CreatedAt time.Time `json:"created_at"`
}

// notificationsPageResponse is GET /v1/me/notifications' page envelope,
// mirroring updateHistoryResponse's shape.
type notificationsPageResponse struct {
	Items      []notificationResponse `json:"items"`
	NextCursor *string                `json:"next_cursor"`
}

// NotificationsHandler exposes the authenticated account's own notification
// inbox — never another account's, since UserFromContext is the only
// source of ownership these handlers use.
type NotificationsHandler struct {
	inbox NotificationInboxManager
}

func NewNotificationsHandler(inbox NotificationInboxManager) *NotificationsHandler {
	return &NotificationsHandler{inbox: inbox}
}

// List answers GET /v1/me/notifications?cursor=&limit=: the caller's own
// notifications, newest first.
func (h *NotificationsHandler) List(w http.ResponseWriter, r *http.Request) {
	user := UserFromContext(r.Context())

	limit := 0
	if raw := r.URL.Query().Get("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid limit"})
			return
		}
		limit = parsed
	}

	page, err := h.inbox.ListMyNotifications(r.Context(), user.UserID, r.URL.Query().Get("cursor"), limit)
	if err != nil {
		writeNotificationsServiceError(w, err)
		return
	}

	items := make([]notificationResponse, 0, len(page.Items))
	for _, n := range page.Items {
		items = append(items, notificationResponse{
			ID:        n.ID,
			CatID:     n.CatID,
			UpdateID:  n.UpdateID,
			Read:      n.Read,
			CreatedAt: n.CreatedAt,
		})
	}

	resp := notificationsPageResponse{Items: items}
	if page.NextCursor != "" {
		resp.NextCursor = &page.NextCursor
	}
	writeJSON(w, http.StatusOK, resp)
}

// MarkRead answers POST /v1/me/notifications/{id}/read.
func (h *NotificationsHandler) MarkRead(w http.ResponseWriter, r *http.Request) {
	user := UserFromContext(r.Context())
	if err := h.inbox.MarkRead(r.Context(), user.UserID, chi.URLParam(r, "id")); err != nil {
		writeNotificationsServiceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func writeNotificationsServiceError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, service.ErrInvalidCursor):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid cursor"})
	case errors.Is(err, service.ErrInvalidLimit):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid limit"})
	case errors.Is(err, service.ErrInvalidNotificationID):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid notification id"})
	default:
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
}
