package handler

import (
	"bytes"
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

type fakeBlocker struct {
	err  error
	list []service.BlockedAccount

	capturedBlocker *string
	capturedBlocked *string
}

func (f fakeBlocker) Block(_ context.Context, blockerUserID, blockedUserID string) error {
	if f.capturedBlocker != nil {
		*f.capturedBlocker = blockerUserID
	}
	if f.capturedBlocked != nil {
		*f.capturedBlocked = blockedUserID
	}
	return f.err
}

func (f fakeBlocker) Unblock(_ context.Context, blockerUserID, blockedUserID string) error {
	if f.capturedBlocker != nil {
		*f.capturedBlocker = blockerUserID
	}
	if f.capturedBlocked != nil {
		*f.capturedBlocked = blockedUserID
	}
	return f.err
}

func (f fakeBlocker) ListBlocked(_ context.Context, blockerUserID string) ([]service.BlockedAccount, error) {
	if f.capturedBlocker != nil {
		*f.capturedBlocker = blockerUserID
	}
	return f.list, f.err
}

func routerForBlocks(h *BlocksHandler, validator AccessTokenValidator) http.Handler {
	r := chi.NewRouter()
	r.With(RequireBearer(validator)).Post("/v1/me/blocks", h.Create)
	r.With(RequireBearer(validator)).Get("/v1/me/blocks", h.List)
	r.With(RequireBearer(validator)).Delete("/v1/me/blocks/{user_id}", h.Delete)
	return r
}

// The blocker is the session, never the body — the request shape has no
// field for it, and an attempt to smuggle one in is rejected outright.
func TestBlocksHandler_Create_UsesSessionAsBlocker(t *testing.T) {
	userID := uuid.New().String()
	target := uuid.New().String()
	var capturedBlocker, capturedBlocked string

	h := NewBlocksHandler(fakeBlocker{capturedBlocker: &capturedBlocker, capturedBlocked: &capturedBlocked})
	rec := httptest.NewRecorder()
	req := withBearerToken(httptest.NewRequest(http.MethodPost, "/v1/me/blocks", bytes.NewBufferString(`{"blocked_user_id":"`+target+`"}`)))
	routerForBlocks(h, fakeAccessValidator{userID: userID}).ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", rec.Code, rec.Body.String())
	}
	if capturedBlocker != userID {
		t.Errorf("blocker: want %s, got %s", userID, capturedBlocker)
	}
	if capturedBlocked != target {
		t.Errorf("blocked: want %s, got %s", target, capturedBlocked)
	}
}

func TestBlocksHandler_Create_RejectsUnknownFields(t *testing.T) {
	h := NewBlocksHandler(fakeBlocker{})
	rec := httptest.NewRecorder()
	body := `{"blocked_user_id":"` + uuid.New().String() + `","blocker_user_id":"` + uuid.New().String() + `"}`
	req := withBearerToken(httptest.NewRequest(http.MethodPost, "/v1/me/blocks", bytes.NewBufferString(body)))
	routerForBlocks(h, fakeAccessValidator{userID: uuid.New().String()}).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestBlocksHandler_Create_RequiresBearer(t *testing.T) {
	h := NewBlocksHandler(fakeBlocker{})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/me/blocks", bytes.NewBufferString(`{"blocked_user_id":"`+uuid.New().String()+`"}`))
	routerForBlocks(h, fakeAccessValidator{userID: uuid.New().String()}).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestBlocksHandler_ServiceErrorMapping(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want int
	}{
		{"self block", service.ErrCannotBlockSelf, http.StatusBadRequest},
		{"malformed target", service.ErrInvalidBlockedUserID, http.StatusBadRequest},
		{"unknown target", service.ErrBlockedUserNotFound, http.StatusNotFound},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := NewBlocksHandler(fakeBlocker{err: c.err})
			rec := httptest.NewRecorder()
			req := withBearerToken(httptest.NewRequest(http.MethodPost, "/v1/me/blocks", bytes.NewBufferString(`{"blocked_user_id":"`+uuid.New().String()+`"}`)))
			routerForBlocks(h, fakeAccessValidator{userID: uuid.New().String()}).ServeHTTP(rec, req)

			if rec.Code != c.want {
				t.Fatalf("expected %d, got %d: %s", c.want, rec.Code, rec.Body.String())
			}
		})
	}
}

func TestBlocksHandler_Delete_UsesPathParam(t *testing.T) {
	userID := uuid.New().String()
	target := uuid.New().String()
	var capturedBlocker, capturedBlocked string

	h := NewBlocksHandler(fakeBlocker{capturedBlocker: &capturedBlocker, capturedBlocked: &capturedBlocked})
	rec := httptest.NewRecorder()
	req := withBearerToken(httptest.NewRequest(http.MethodDelete, "/v1/me/blocks/"+target, nil))
	routerForBlocks(h, fakeAccessValidator{userID: userID}).ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", rec.Code, rec.Body.String())
	}
	if capturedBlocker != userID || capturedBlocked != target {
		t.Fatalf("unexpected args: blocker=%s blocked=%s", capturedBlocker, capturedBlocked)
	}
}

func TestBlocksHandler_List_ReturnsOwnBlocksOnly(t *testing.T) {
	userID := uuid.New().String()
	blocked := uuid.New().String()
	name := "Komşu"
	var capturedBlocker string

	h := NewBlocksHandler(fakeBlocker{
		capturedBlocker: &capturedBlocker,
		list: []service.BlockedAccount{{
			UserID:      blocked,
			DisplayName: &name,
			CreatedAt:   time.Date(2026, 8, 14, 9, 0, 0, 0, time.UTC),
		}},
	})
	rec := httptest.NewRecorder()
	req := withBearerToken(httptest.NewRequest(http.MethodGet, "/v1/me/blocks", nil))
	routerForBlocks(h, fakeAccessValidator{userID: userID}).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if capturedBlocker != userID {
		t.Fatalf("list must be scoped to the caller: want %s, got %s", userID, capturedBlocker)
	}

	var body []blockedAccountResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body) != 1 || body[0].UserID != blocked || body[0].DisplayName == nil || *body[0].DisplayName != name {
		t.Fatalf("unexpected body: %+v", body)
	}
}
