package handler

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
)

type fakeAccountDeleter struct {
	err            error
	capturedUserID *string
}

func (f fakeAccountDeleter) Delete(_ context.Context, userID string) error {
	if f.capturedUserID != nil {
		*f.capturedUserID = userID
	}
	return f.err
}

func routerForAccounts(h *AccountsHandler, validator AccessTokenValidator) http.Handler {
	r := chi.NewRouter()
	r.With(RequireBearer(validator)).Delete("/v1/me", h.Delete)
	return r
}

// The account being deleted is always the session's own — the request
// carries no account id at all, so there is no shape in which one account
// could ask to delete another.
func TestAccountsHandler_Delete_DeletesTheCallersOwnAccount(t *testing.T) {
	userID := uuid.New().String()
	var captured string

	h := NewAccountsHandler(fakeAccountDeleter{capturedUserID: &captured})
	rec := httptest.NewRecorder()
	req := withBearerToken(httptest.NewRequest(http.MethodDelete, "/v1/me", nil))
	routerForAccounts(h, fakeAccessValidator{userID: userID}).ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", rec.Code, rec.Body.String())
	}
	if captured != userID {
		t.Fatalf("expected the session's account %s, got %s", userID, captured)
	}
}

func TestAccountsHandler_Delete_RequiresBearer(t *testing.T) {
	h := NewAccountsHandler(fakeAccountDeleter{})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodDelete, "/v1/me", nil)
	routerForAccounts(h, fakeAccessValidator{userID: uuid.New().String()}).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", rec.Code, rec.Body.String())
	}
}

// A failure must not read as success: the client keeps its session and the
// user is not signed out of an account that still exists.
func TestAccountsHandler_Delete_FailureIsNotReportedAsSuccess(t *testing.T) {
	h := NewAccountsHandler(fakeAccountDeleter{err: errors.New("boom")})
	rec := httptest.NewRecorder()
	req := withBearerToken(httptest.NewRequest(http.MethodDelete, "/v1/me", nil))
	routerForAccounts(h, fakeAccessValidator{userID: uuid.New().String()}).ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d: %s", rec.Code, rec.Body.String())
	}
}
