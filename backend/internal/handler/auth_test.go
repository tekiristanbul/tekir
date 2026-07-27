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

// unlinkCall records one UnlinkDevice invocation, for tests asserting
// Logout did (or deliberately didn't) attempt an unlink.
type unlinkCall struct{ deviceID, userID string }

// fakeDeviceUnlinker is an in-process stub for DeviceUnlinker. captured, if
// non-nil, records every call — a pointer field so the write is visible
// through the copy of fakeDeviceUnlinker the handler ends up holding,
// mirroring this repo's existing "captured" fake-store convention.
type fakeDeviceUnlinker struct {
	err      error
	captured *[]unlinkCall
}

func (f fakeDeviceUnlinker) UnlinkDevice(_ context.Context, deviceID, userID string) error {
	if f.captured != nil {
		*f.captured = append(*f.captured, unlinkCall{deviceID, userID})
	}
	return f.err
}

// ── POST /v1/auth/otp/request ──────────────────────────────────────────────────

func TestAuthHandler_RequestOTP_Success(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{})

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
	h := handler.NewAuthHandler(fakeOTPRequester{err: service.ErrInvalidPhone}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/otp/request", bytes.NewBufferString(`{"phone":"bad"}`))
	h.RequestOTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestAuthHandler_RequestOTP_ResendTooSoon(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{err: service.ErrOTPResendTooSoon}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/otp/request", bytes.NewBufferString(`{"phone":"5321112233"}`))
	h.RequestOTP(rec, req)

	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429, got %d", rec.Code)
	}
}

func TestAuthHandler_RequestOTP_MalformedJSON(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{})

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
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{session: session}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{})

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
			h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{err: c.err}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{})

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
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{session: session}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/refresh", bytes.NewBufferString(`{"refresh_token":"rt"}`))
	h.Refresh(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestAuthHandler_Refresh_MissingToken(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{})

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
		h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{err: e}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{})

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
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/logout", bytes.NewBufferString(`{"refresh_token":"rt"}`))
	h.Logout(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", rec.Code)
	}
}

func TestAuthHandler_Logout_MissingToken(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/logout", bytes.NewBufferString(`{}`))
	h.Logout(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

// constAccessValidator is a minimal AccessTokenValidator fake for driving
// Logout through RequireBearer exactly as router.go wires it, so
// UserFromContext is populated the same way production traffic would be.
type constAccessValidator struct {
	userID string
	err    error
}

func (c constAccessValidator) ValidateAccessToken(_ string) (string, error) {
	return c.userID, c.err
}

// logoutRequest exercises h.Logout behind RequireBearer + OptionalDeviceToken
// exactly as router.go wires it (issue #80's product-owner review: logout
// now optionally unlinks the presented device).
func logoutRequest(h *handler.AuthHandler, userID, deviceToken string, resolver handler.DeviceTokenResolver) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/logout", bytes.NewBufferString(`{"refresh_token":"rt"}`))
	if deviceToken != "" {
		req.Header.Set("X-Device-Token", deviceToken)
	}

	mw := func(next http.Handler) http.Handler {
		return handler.RequireBearer(constAccessValidator{userID: userID})(
			handler.OptionalDeviceToken(resolver)(next),
		)
	}
	req.Header.Set("Authorization", "Bearer irrelevant-for-this-fake")
	mw(http.HandlerFunc(h.Logout)).ServeHTTP(rec, req)
	return rec
}

func TestAuthHandler_Logout_WithDeviceToken_UnlinksThatDeviceForThisAccount(t *testing.T) {
	var captured []unlinkCall
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{captured: &captured})

	rec := logoutRequest(h, "user-1", "some-token", constDeviceResolver{service.DeviceIdentity{DeviceID: "device-1"}})

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", rec.Code, rec.Body.String())
	}
	if len(captured) != 1 || captured[0].deviceID != "device-1" || captured[0].userID != "user-1" {
		t.Fatalf("expected exactly one unlink call for (device-1, user-1), got %+v", captured)
	}
}

// TestAuthHandler_Logout_NoDeviceToken_NeverAttemptsUnlink covers the
// existing, unaffected behavior: logout without any X-Device-Token still
// succeeds and never calls UnlinkDevice at all.
func TestAuthHandler_Logout_NoDeviceToken_NeverAttemptsUnlink(t *testing.T) {
	var captured []unlinkCall
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{captured: &captured})

	rec := logoutRequest(h, "user-1", "", constDeviceResolver{service.DeviceIdentity{DeviceID: "device-1"}})

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", rec.Code, rec.Body.String())
	}
	if len(captured) != 0 {
		t.Fatalf("expected no unlink attempt without a device token, got %+v", captured)
	}
}

// TestAuthHandler_Logout_InvalidDeviceToken_NeverAttemptsUnlink covers a
// device token that doesn't resolve to any device at all (OptionalDeviceToken
// simply proceeds with no DeviceIdentity in context) — must not unlink
// anything, and must not fail the logout response either.
func TestAuthHandler_Logout_InvalidDeviceToken_NeverAttemptsUnlink(t *testing.T) {
	var captured []unlinkCall
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{captured: &captured})

	failing := logoutRequest(h, "user-1", "unresolvable-token", failingDeviceResolver{})
	if failing.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", failing.Code, failing.Body.String())
	}
	if len(captured) != 0 {
		t.Fatalf("expected no unlink attempt for an unresolvable device token, got %+v", captured)
	}
}

type failingDeviceResolver struct{}

func (failingDeviceResolver) ResolveToken(_ context.Context, _ string) (service.DeviceIdentity, error) {
	return service.DeviceIdentity{}, errors.New("unknown device token")
}

// TestAuthHandler_Logout_UnlinkErrorStillSucceeds proves unlinking is
// best-effort: a failure from UnlinkDevice never fails the logout response
// itself (the refresh token is already revoked by that point).
func TestAuthHandler_Logout_UnlinkErrorStillSucceeds(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{err: errors.New("db down")})

	rec := logoutRequest(h, "user-1", "some-token", constDeviceResolver{service.DeviceIdentity{DeviceID: "device-1"}})

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204 even when unlink fails, got %d: %s", rec.Code, rec.Body.String())
	}
}

// TestAuthHandler_Logout_IsIdempotent proves calling Logout twice (mirroring
// a duplicate client retry) succeeds both times, even once the device is
// already unlinked from the first call.
func TestAuthHandler_Logout_IsIdempotent(t *testing.T) {
	var captured []unlinkCall
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{captured: &captured})

	resolver := constDeviceResolver{service.DeviceIdentity{DeviceID: "device-1"}}
	first := logoutRequest(h, "user-1", "some-token", resolver)
	second := logoutRequest(h, "user-1", "some-token", resolver)

	if first.Code != http.StatusNoContent || second.Code != http.StatusNoContent {
		t.Fatalf("expected 204 on both attempts, got %d and %d", first.Code, second.Code)
	}
	if len(captured) != 2 {
		t.Fatalf("expected an unlink attempt on both calls, got %+v", captured)
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
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{})

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
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{})
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
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPatch, "/v1/me", bytes.NewBufferString(`{"display_name":"Ayşe"}`))
	h.UpdateDisplayName(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestAuthHandler_UpdateDisplayName_Invalid(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{err: service.ErrInvalidDisplayName}, fakeDeviceUnlinker{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPatch, "/v1/me", bytes.NewBufferString(`{"display_name":""}`))
	h.UpdateDisplayName(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestAuthHandler_UpdateDisplayName_MalformedJSON(t *testing.T) {
	h := handler.NewAuthHandler(fakeOTPRequester{}, fakeOTPVerifier{}, fakeRefresher{}, fakeRevoker{}, fakeDisplayNameSetter{}, fakeDeviceUnlinker{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPatch, "/v1/me", bytes.NewBufferString(`not-json`))
	h.UpdateDisplayName(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}
