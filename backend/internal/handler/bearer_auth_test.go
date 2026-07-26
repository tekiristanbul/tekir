package handler_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/tekiristanbul/tekir/backend/internal/handler"
)

type fakeAccessValidator struct {
	userID string
	err    error
}

func (f fakeAccessValidator) ValidateAccessToken(_ string) (string, error) { return f.userID, f.err }

func TestRequireBearer_ValidToken(t *testing.T) {
	mw := handler.RequireBearer(fakeAccessValidator{userID: "user-abc"})

	reached := false
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reached = true
		got := handler.UserFromContext(r.Context())
		if got.UserID != "user-abc" {
			t.Errorf("expected user-abc, got %q", got.UserID)
		}
		w.WriteHeader(http.StatusOK)
	})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/logout", nil)
	req.Header.Set("Authorization", "Bearer valid-token")
	mw(inner).ServeHTTP(rec, req)

	if !reached {
		t.Fatal("inner handler should have been called")
	}
	if rec.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", rec.Code)
	}
}

func TestRequireBearer_MissingHeader(t *testing.T) {
	mw := handler.RequireBearer(fakeAccessValidator{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/", nil)
	mw(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("inner handler must not be reached")
	})).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rec.Code)
	}
}

func TestRequireBearer_MissingBearerPrefix(t *testing.T) {
	mw := handler.RequireBearer(fakeAccessValidator{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/", nil)
	req.Header.Set("Authorization", "Basic dXNlcjpwYXNz")
	mw(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("inner handler must not be reached")
	})).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rec.Code)
	}
}

func TestRequireBearer_EmptyToken(t *testing.T) {
	mw := handler.RequireBearer(fakeAccessValidator{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/", nil)
	req.Header.Set("Authorization", "Bearer ")
	mw(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("inner handler must not be reached")
	})).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rec.Code)
	}
}

func TestRequireBearer_MultipleHeaderValues(t *testing.T) {
	mw := handler.RequireBearer(fakeAccessValidator{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/", nil)
	req.Header.Add("Authorization", "Bearer a")
	req.Header.Add("Authorization", "Bearer b")
	mw(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("inner handler must not be reached")
	})).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rec.Code)
	}
}

func TestRequireBearer_InvalidToken(t *testing.T) {
	mw := handler.RequireBearer(fakeAccessValidator{err: context.DeadlineExceeded})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/", nil)
	req.Header.Set("Authorization", "Bearer expired-or-bad")
	mw(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("inner handler must not be reached")
	})).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rec.Code)
	}
}

func TestOptionalBearer_ValidToken_SetsIdentity(t *testing.T) {
	mw := handler.OptionalBearer(fakeAccessValidator{userID: "user-xyz"})

	var got string
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = handler.UserFromContext(r.Context()).UserID
		w.WriteHeader(http.StatusOK)
	})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/me", nil)
	req.Header.Set("Authorization", "Bearer valid")
	mw(inner).ServeHTTP(rec, req)

	if got != "user-xyz" {
		t.Errorf("expected user-xyz, got %q", got)
	}
}

func TestOptionalBearer_MissingHeader_StillProceeds(t *testing.T) {
	mw := handler.OptionalBearer(fakeAccessValidator{})

	reached := false
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reached = true
		if got := handler.UserFromContext(r.Context()); got.UserID != "" {
			t.Errorf("expected no user identity, got %q", got.UserID)
		}
		w.WriteHeader(http.StatusOK)
	})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/me", nil)
	mw(inner).ServeHTTP(rec, req)

	if !reached {
		t.Fatal("inner handler should have been called even without a bearer token")
	}
	if rec.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", rec.Code)
	}
}

func TestOptionalBearer_InvalidToken_StillProceedsWithoutIdentity(t *testing.T) {
	mw := handler.OptionalBearer(fakeAccessValidator{err: context.DeadlineExceeded})

	reached := false
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reached = true
		if got := handler.UserFromContext(r.Context()); got.UserID != "" {
			t.Errorf("expected no user identity for an invalid token, got %q", got.UserID)
		}
		w.WriteHeader(http.StatusOK)
	})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/me", nil)
	req.Header.Set("Authorization", "Bearer bad-token")
	mw(inner).ServeHTTP(rec, req)

	if !reached {
		t.Fatal("inner handler should still be reached")
	}
}
