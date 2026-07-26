package handler_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/tekiristanbul/tekir/backend/internal/handler"
	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// ── fakes ─────────────────────────────────────────────────────────────────────

type fakeOTPRequester struct{ err error }

func (f fakeOTPRequester) RequestOTP(_ context.Context, _ string) error { return f.err }

type fakeOTPVerifier struct {
	session service.Session
	err     error
}

func (f fakeOTPVerifier) VerifyOTP(_ context.Context, _, _, _ string) (service.Session, error) {
	return f.session, f.err
}

type fakeRefresher struct {
	session service.Session
	err     error
}

func (f fakeRefresher) Refresh(_ context.Context, _ string) (service.Session, error) {
	return f.session, f.err
}

type fakeRevoker struct{ err error }

func (f fakeRevoker) Revoke(_ context.Context, _ string) error { return f.err }

type fakeDisplayNameSetter struct{ err error }

func (f fakeDisplayNameSetter) SetDisplayName(_ context.Context, _, _ string) error {
	return f.err
}

// ── POST /v1/auth/otp/request ──────────────────────────────────────────────────

func TestAuthHandler_RequestOTP_Success(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/otp/request", bytes.NewBufferString(`{"phone":"5321112233"}`))
	h.RequestOTP(rec, req)

	if rec.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d: %s", rec.Code, rec.Body.String())
	}
	if rec.Header().Get("Cache-Control") != "no-store" {
		t.Errorf("expected Cache-Control: no-store, got %q", rec.Header().Get("Cache-Control"))
	}
}

func TestAuthHandler_RequestOTP_InvalidPhone(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{err: service.ErrInvalidPhone}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/otp/request", bytes.NewBufferString(`{"phone":"bad"}`))
	h.RequestOTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestAuthHandler_RequestOTP_ResendTooSoon(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{err: service.ErrOTPResendTooSoon}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/otp/request", bytes.NewBufferString(`{"phone":"5321112233"}`))
	h.RequestOTP(rec, req)

	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429, got %d", rec.Code)
	}
}

func TestAuthHandler_RequestOTP_MalformedJSON(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/otp/request", bytes.NewBufferString(`not-json`))
	h.RequestOTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

// ── POST /v1/auth/otp/verify ────────────────────────────────────────────────────

func TestAuthHandler_VerifyOTP_Success(t *testing.T) {
	session := service.Session{AccessToken: "at", RefreshToken: "rt", UserID: "user-1"}
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{session: session}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/otp/verify", bytes.NewBufferString(`{"phone":"5321112233","code":"123456"}`))
	h.VerifyOTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var resp struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		UserID       string `json:"user_id"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.AccessToken != "at" || resp.RefreshToken != "rt" || resp.UserID != "user-1" {
		t.Errorf("unexpected response: %+v", resp)
	}
}

func TestAuthHandler_VerifyOTP_Errors(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want int
	}{
		{"invalid phone", service.ErrInvalidPhone, http.StatusBadRequest},
		{"not requested", service.ErrOTPNotRequested, http.StatusUnauthorized},
		{"code mismatch", service.ErrOTPCodeMismatch, http.StatusUnauthorized},
		{"expired", service.ErrOTPExpired, http.StatusGone},
		{"already consumed", service.ErrOTPAlreadyConsumed, http.StatusGone},
		{"too many attempts", service.ErrOTPTooManyAttempts, http.StatusTooManyRequests},
		{"device linked to other account", service.ErrDeviceLinkedToOtherAccount, http.StatusConflict},
		{"unexpected", errors.New("db down"), http.StatusInternalServerError},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{err: c.err}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{})

			rec := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPost, "/v1/auth/otp/verify", bytes.NewBufferString(`{"phone":"5321112233","code":"123456"}`))
			h.VerifyOTP(rec, req)

			if rec.Code != c.want {
				t.Errorf("expected %d, got %d", c.want, rec.Code)
			}
		})
	}
}

// ── POST /v1/auth/refresh ───────────────────────────────────────────────────────

func TestAuthHandler_Refresh_Success(t *testing.T) {
	session := service.Session{AccessToken: "at2", RefreshToken: "rt2"}
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{session: session}, fakeRevoker{}, fakeDisplayNameSetter{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/refresh", bytes.NewBufferString(`{"refresh_token":"rt"}`))
	h.Refresh(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestAuthHandler_Refresh_MissingToken(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/refresh", bytes.NewBufferString(`{}`))
	h.Refresh(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestAuthHandler_Refresh_InvalidSession(t *testing.T) {
	cases := []error{service.ErrSessionExpired, service.ErrSessionRevoked, service.ErrSessionInvalid}
	for _, e := range cases {
		h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{err: e}, fakeRevoker{}, fakeDisplayNameSetter{})

		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/v1/auth/refresh", bytes.NewBufferString(`{"refresh_token":"bad"}`))
		h.Refresh(rec, req)

		if rec.Code != http.StatusUnauthorized {
			t.Errorf("expected 401 for %v, got %d", e, rec.Code)
		}
	}
}

// ── POST /v1/auth/logout ────────────────────────────────────────────────────────

func TestAuthHandler_Logout_Success(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/logout", bytes.NewBufferString(`{"refresh_token":"rt"}`))
	h.Logout(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", rec.Code)
	}
}

func TestAuthHandler_Logout_MissingToken(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/logout", bytes.NewBufferString(`{}`))
	h.Logout(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

// ── GET /v1/me ──────────────────────────────────────────────────────────────────

// meRequest exercises h.Me behind RequireDeviceToken exactly as the router
// wires it, so the request context carries a real DeviceIdentity the same
// way production traffic would (Me itself never sets this up).
func meRequest(t *testing.T, h *handler.AuthHandler, identity service.DeviceIdentity) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/me", nil)
	req.Header.Set("X-Device-Token", "irrelevant-for-this-fake")

	mw := handler.RequireDeviceToken(constDeviceResolver{identity})
	mw(http.HandlerFunc(h.Me)).ServeHTTP(rec, req)
	return rec
}

type constDeviceResolver struct{ identity service.DeviceIdentity }

func (c constDeviceResolver) ResolveToken(_ context.Context, _ string) (service.DeviceIdentity, error) {
	return c.identity, nil
}

func TestAuthHandler_Me_GuestDevice(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{})

	rec := meRequest(t, h, service.DeviceIdentity{DeviceID: "device-1"})

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var resp struct {
		DeviceID      string  `json:"device_id"`
		UserID        *string `json:"user_id"`
		PhoneVerified bool    `json:"phone_verified"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.DeviceID != "device-1" {
		t.Errorf("expected device-1, got %q", resp.DeviceID)
	}
	if resp.UserID != nil {
		t.Error("expected nil user_id for an unlinked device")
	}
	if resp.PhoneVerified {
		t.Error("expected phone_verified false for a guest device")
	}
}

func TestAuthHandler_Me_LinkedDeviceNoBearer(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{})
	linkedUser := "user-abc"

	rec := meRequest(t, h, service.DeviceIdentity{DeviceID: "device-2", UserID: &linkedUser})

	var resp struct {
		UserID        *string `json:"user_id"`
		PhoneVerified bool    `json:"phone_verified"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.UserID == nil || *resp.UserID != linkedUser {
		t.Errorf("expected user_id %q, got %v", linkedUser, resp.UserID)
	}
	if !resp.PhoneVerified {
		t.Error("expected phone_verified true for a linked device")
	}
}

// ── PATCH /v1/me (display name) ─────────────────────────────────────────────────

func TestAuthHandler_UpdateDisplayName_Success(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPatch, "/v1/me", bytes.NewBufferString(`{"display_name":"Ayşe"}`))
	h.UpdateDisplayName(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestAuthHandler_UpdateDisplayName_Invalid(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{err: service.ErrInvalidDisplayName})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPatch, "/v1/me", bytes.NewBufferString(`{"display_name":""}`))
	h.UpdateDisplayName(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestAuthHandler_UpdateDisplayName_MalformedJSON(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPatch, "/v1/me", bytes.NewBufferString(`not-json`))
	h.UpdateDisplayName(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}
