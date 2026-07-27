package handler

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// fakeNotificationInboxManager is an in-process stub for NotificationInboxManager.
type fakeNotificationInboxManager struct {
	page    service.NotificationsPage
	listErr error

	capturedUserID *string
	capturedCursor *string
	capturedLimit  *int

	markErr          error
	capturedMarkUser *string
	capturedMarkID   *string
}

func (f fakeNotificationInboxManager) ListMyNotifications(_ context.Context, userID, cursor string, limit int) (service.NotificationsPage, error) {
	if f.capturedUserID != nil {
		*f.capturedUserID = userID
	}
	if f.capturedCursor != nil {
		*f.capturedCursor = cursor
	}
	if f.capturedLimit != nil {
		*f.capturedLimit = limit
	}
	return f.page, f.listErr
}

func (f fakeNotificationInboxManager) MarkRead(_ context.Context, userID, id string) error {
	if f.capturedMarkUser != nil {
		*f.capturedMarkUser = userID
	}
	if f.capturedMarkID != nil {
		*f.capturedMarkID = id
	}
	return f.markErr
}

func routerForNotifications(h *NotificationsHandler, validator AccessTokenValidator) http.Handler {
	r := chi.NewRouter()
	r.With(RequireBearer(validator)).Get("/v1/me/notifications", h.List)
	r.With(RequireBearer(validator)).Post("/v1/me/notifications/{id}/read", h.MarkRead)
	return r
}

func TestNotificationsHandler_List_Success(t *testing.T) {
	userID := uuid.New().String()
	notifID := uuid.New().String()
	catID := uuid.New().String()
	updateID := uuid.New().String()
	createdAt := time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC)

	var capturedUser string
	h := NewNotificationsHandler(fakeNotificationInboxManager{
		capturedUserID: &capturedUser,
		page: service.NotificationsPage{
			Items: []service.Notification{
				{ID: notifID, CatID: catID, UpdateID: updateID, Read: false, CreatedAt: createdAt},
			},
		},
	})

	rec := httptest.NewRecorder()
	req := withBearerToken(httptest.NewRequest(http.MethodGet, "/v1/me/notifications", nil))
	routerForNotifications(h, fakeAccessValidator{userID: userID}).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if capturedUser != userID {
		t.Errorf("expected user id %s, got %s", userID, capturedUser)
	}

	var body notificationsPageResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body.Items) != 1 || body.Items[0].ID != notifID {
		t.Fatalf("unexpected items: %+v", body.Items)
	}
	if body.Items[0].Read {
		t.Errorf("expected read false")
	}
	if body.NextCursor != nil {
		t.Errorf("expected no next cursor, got %v", *body.NextCursor)
	}
}

func TestNotificationsHandler_List_PassesCursorAndLimit(t *testing.T) {
	var capturedCursor string
	var capturedLimit int
	h := NewNotificationsHandler(fakeNotificationInboxManager{capturedCursor: &capturedCursor, capturedLimit: &capturedLimit})

	rec := httptest.NewRecorder()
	req := withBearerToken(httptest.NewRequest(http.MethodGet, "/v1/me/notifications?cursor=abc&limit=5", nil))
	routerForNotifications(h, fakeAccessValidator{userID: uuid.New().String()}).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if capturedCursor != "abc" {
		t.Errorf("expected cursor abc, got %q", capturedCursor)
	}
	if capturedLimit != 5 {
		t.Errorf("expected limit 5, got %d", capturedLimit)
	}
}

func TestNotificationsHandler_List_InvalidLimit(t *testing.T) {
	h := NewNotificationsHandler(fakeNotificationInboxManager{})
	rec := httptest.NewRecorder()
	req := withBearerToken(httptest.NewRequest(http.MethodGet, "/v1/me/notifications?limit=not-a-number", nil))
	routerForNotifications(h, fakeAccessValidator{userID: uuid.New().String()}).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestNotificationsHandler_List_InvalidCursor(t *testing.T) {
	h := NewNotificationsHandler(fakeNotificationInboxManager{listErr: service.ErrInvalidCursor})
	rec := httptest.NewRecorder()
	req := withBearerToken(httptest.NewRequest(http.MethodGet, "/v1/me/notifications?cursor=garbage", nil))
	routerForNotifications(h, fakeAccessValidator{userID: uuid.New().String()}).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestNotificationsHandler_List_RequiresBearer(t *testing.T) {
	h := NewNotificationsHandler(fakeNotificationInboxManager{})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/me/notifications", nil)
	routerForNotifications(h, fakeAccessValidator{userID: uuid.New().String()}).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestNotificationsHandler_MarkRead_Success(t *testing.T) {
	userID := uuid.New().String()
	notifID := uuid.New().String()
	var capturedUser, capturedID string
	h := NewNotificationsHandler(fakeNotificationInboxManager{capturedMarkUser: &capturedUser, capturedMarkID: &capturedID})

	rec := httptest.NewRecorder()
	req := withBearerToken(httptest.NewRequest(http.MethodPost, "/v1/me/notifications/"+notifID+"/read", nil))
	routerForNotifications(h, fakeAccessValidator{userID: userID}).ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", rec.Code, rec.Body.String())
	}
	if capturedUser != userID {
		t.Errorf("expected user id %s, got %s", userID, capturedUser)
	}
	if capturedID != notifID {
		t.Errorf("expected notification id %s, got %s", notifID, capturedID)
	}
}

func TestNotificationsHandler_MarkRead_InvalidID(t *testing.T) {
	h := NewNotificationsHandler(fakeNotificationInboxManager{markErr: service.ErrInvalidNotificationID})
	rec := httptest.NewRecorder()
	req := withBearerToken(httptest.NewRequest(http.MethodPost, "/v1/me/notifications/not-a-uuid/read", nil))
	routerForNotifications(h, fakeAccessValidator{userID: uuid.New().String()}).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestNotificationsHandler_MarkRead_RequiresBearer(t *testing.T) {
	h := NewNotificationsHandler(fakeNotificationInboxManager{})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/me/notifications/"+uuid.New().String()+"/read", nil)
	routerForNotifications(h, fakeAccessValidator{userID: uuid.New().String()}).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", rec.Code, rec.Body.String())
	}
}
