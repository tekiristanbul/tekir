package handler_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/tekiristanbul/tekir/backend/internal/handler"
	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// ── fake registrar ────────────────────────────────────────────────────────────

type fakeDevicesRegistrar struct {
	reg service.DeviceRegistration
	err error

	pushErr error
	// pointer so the value-typed fake can still record calls.
	pushCalls *[]pushTokenCall
}

type pushTokenCall struct {
	deviceID  string
	pushToken string
}

func (f fakeDevicesRegistrar) Register(_ context.Context, _ string, _ *string) (service.DeviceRegistration, error) {
	return f.reg, f.err
}

func (f fakeDevicesRegistrar) SetPushToken(_ context.Context, deviceID, pushToken string) error {
	if f.pushCalls != nil {
		*f.pushCalls = append(*f.pushCalls, pushTokenCall{deviceID: deviceID, pushToken: pushToken})
	}
	return f.pushErr
}

// ── POST /v1/devices tests ────────────────────────────────────────────────────

func TestDevicesHandler_Register_Success(t *testing.T) {
	fake := fakeDevicesRegistrar{
		reg: service.DeviceRegistration{DeviceID: "dev-123", DeviceToken: "tok-abc"},
	}
	h := handler.NewDevicesHandler(fake)

	body := `{"platform":"web"}`
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/devices", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	h.Register(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	if rec.Header().Get("Cache-Control") != "no-store" {
		t.Errorf("expected Cache-Control: no-store, got %q", rec.Header().Get("Cache-Control"))
	}

	var resp struct {
		DeviceID    string `json:"device_id"`
		DeviceToken string `json:"device_token"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.DeviceID != "dev-123" {
		t.Errorf("unexpected device_id: %q", resp.DeviceID)
	}
	if resp.DeviceToken != "tok-abc" {
		t.Errorf("unexpected device_token: %q", resp.DeviceToken)
	}
}

func TestDevicesHandler_Register_WithPushToken(t *testing.T) {
	fake := fakeDevicesRegistrar{
		reg: service.DeviceRegistration{DeviceID: "dev-456", DeviceToken: "tok-def"},
	}
	h := handler.NewDevicesHandler(fake)

	body := `{"platform":"ios","push_token":"fcm-token-xyz"}`
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/devices", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	h.Register(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestDevicesHandler_Register_MissingPlatform(t *testing.T) {
	h := handler.NewDevicesHandler(fakeDevicesRegistrar{})

	body := `{}`
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/devices", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	h.Register(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestDevicesHandler_Register_EmptyPlatform(t *testing.T) {
	h := handler.NewDevicesHandler(fakeDevicesRegistrar{})

	body := `{"platform":""}`
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/devices", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	h.Register(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestDevicesHandler_Register_UnsupportedPlatform(t *testing.T) {
	fake := fakeDevicesRegistrar{err: service.ErrInvalidPlatform}
	h := handler.NewDevicesHandler(fake)

	body := `{"platform":"windows"}`
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/devices", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	h.Register(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestDevicesHandler_Register_MalformedJSON(t *testing.T) {
	h := handler.NewDevicesHandler(fakeDevicesRegistrar{})

	body := `not-json`
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/devices", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	h.Register(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestDevicesHandler_Register_InvalidFieldType(t *testing.T) {
	// platform is a non-string value — json.Decoder returns an error.
	h := handler.NewDevicesHandler(fakeDevicesRegistrar{})

	body := `{"platform":123}`
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/devices", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	h.Register(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestDevicesHandler_Register_DBError(t *testing.T) {
	fake := fakeDevicesRegistrar{err: errors.New("db unavailable")}
	h := handler.NewDevicesHandler(fake)

	body := `{"platform":"web"}`
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/devices", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	h.Register(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestDevicesHandler_Register_CacheControlNoStore(t *testing.T) {
	// Cache-Control: no-store must be present even when no token is in the response.
	fake := fakeDevicesRegistrar{
		reg: service.DeviceRegistration{DeviceID: "d", DeviceToken: "t"},
	}
	h := handler.NewDevicesHandler(fake)

	body := `{"platform":"android"}`
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/devices", bytes.NewBufferString(body))
	h.Register(rec, req)

	cc := rec.Header().Get("Cache-Control")
	if cc != "no-store" {
		t.Errorf("Cache-Control must be no-store, got %q", cc)
	}
}

// ── device-auth middleware tests ──────────────────────────────────────────────

type fakeResolver struct {
	identity service.DeviceIdentity
	err      error
}

func (f fakeResolver) ResolveToken(_ context.Context, _ string) (service.DeviceIdentity, error) {
	return f.identity, f.err
}

func TestRequireDeviceToken_ValidToken(t *testing.T) {
	identity := service.DeviceIdentity{DeviceID: "device-abc"}
	mw := handler.RequireDeviceToken(fakeResolver{identity: identity})

	reached := false
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reached = true
		got := handler.DeviceFromContext(r.Context())
		if got.DeviceID != identity.DeviceID {
			t.Errorf("context device id: expected %q, got %q", identity.DeviceID, got.DeviceID)
		}
		w.WriteHeader(http.StatusOK)
	})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("X-Device-Token", "valid-token")
	mw(inner).ServeHTTP(rec, req)

	if !reached {
		t.Fatal("inner handler should have been called")
	}
	if rec.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", rec.Code)
	}
}

func TestRequireDeviceToken_MissingHeader(t *testing.T) {
	mw := handler.RequireDeviceToken(fakeResolver{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	mw(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("inner handler must not be reached")
	})).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rec.Code)
	}
}

func TestRequireDeviceToken_EmptyHeader(t *testing.T) {
	mw := handler.RequireDeviceToken(fakeResolver{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("X-Device-Token", "")
	mw(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("inner handler must not be reached")
	})).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rec.Code)
	}
}

func TestRequireDeviceToken_WhitespaceOnlyHeader(t *testing.T) {
	mw := handler.RequireDeviceToken(fakeResolver{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("X-Device-Token", "   ")
	mw(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("inner handler must not be reached")
	})).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rec.Code)
	}
}

func TestRequireDeviceToken_MultipleHeaderValues(t *testing.T) {
	mw := handler.RequireDeviceToken(fakeResolver{})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Add("X-Device-Token", "token-a")
	req.Header.Add("X-Device-Token", "token-b")
	mw(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("inner handler must not be reached")
	})).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rec.Code)
	}
}

func TestRequireDeviceToken_UnknownToken(t *testing.T) {
	mw := handler.RequireDeviceToken(fakeResolver{err: service.ErrDeviceNotFound})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("X-Device-Token", "unknown")
	mw(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("inner handler must not be reached")
	})).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rec.Code)
	}
}

func TestRequireDeviceToken_RevokedToken(t *testing.T) {
	mw := handler.RequireDeviceToken(fakeResolver{err: service.ErrDeviceRevoked})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("X-Device-Token", "revoked")
	mw(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("inner handler must not be reached")
	})).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rec.Code)
	}
}

func TestRequireDeviceToken_DBError(t *testing.T) {
	mw := handler.RequireDeviceToken(fakeResolver{err: errors.New("db down")})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("X-Device-Token", "some-token")
	mw(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("inner handler must not be reached")
	})).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rec.Code)
	}
}

// ── PUT /v1/devices/me tests ──────────────────────────────────────

// newPushTokenServer wires UpdatePushToken behind RequireDeviceToken with a
// resolver that answers the given identity, mirroring the real router's
// middleware wiring (issue #84).
func newPushTokenServer(reg fakeDevicesRegistrar, identity service.DeviceIdentity) http.Handler {
	h := handler.NewDevicesHandler(reg)
	return handler.RequireDeviceToken(fakeResolver{identity: identity})(http.HandlerFunc(h.UpdatePushToken))
}

func TestDevicesHandler_UpdatePushToken_Success(t *testing.T) {
	var calls []pushTokenCall
	srv := newPushTokenServer(fakeDevicesRegistrar{pushCalls: &calls}, service.DeviceIdentity{DeviceID: "device-abc"})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPut, "/v1/devices/me", bytes.NewBufferString(`{"push_token":"fcm-token-1"}`))
	req.Header.Set("X-Device-Token", "raw-device-token")
	srv.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", rec.Code, rec.Body.String())
	}
	if rec.Body.Len() != 0 {
		t.Errorf("expected empty body — the push token must never be echoed, got %s", rec.Body.String())
	}
	if len(calls) != 1 || calls[0].deviceID != "device-abc" || calls[0].pushToken != "fcm-token-1" {
		t.Errorf("unexpected service call: %+v", calls)
	}
}

func TestDevicesHandler_UpdatePushToken_InvalidBody(t *testing.T) {
	var calls []pushTokenCall
	srv := newPushTokenServer(fakeDevicesRegistrar{pushCalls: &calls}, service.DeviceIdentity{DeviceID: "device-abc"})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPut, "/v1/devices/me", bytes.NewBufferString(`not json`))
	req.Header.Set("X-Device-Token", "raw-device-token")
	srv.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
	if len(calls) != 0 {
		t.Errorf("service must not be called on a malformed body: %+v", calls)
	}
}

func TestDevicesHandler_UpdatePushToken_InvalidToken(t *testing.T) {
	srv := newPushTokenServer(fakeDevicesRegistrar{pushErr: service.ErrInvalidPushToken}, service.DeviceIdentity{DeviceID: "device-abc"})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPut, "/v1/devices/me", bytes.NewBufferString(`{"push_token":""}`))
	req.Header.Set("X-Device-Token", "raw-device-token")
	srv.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestDevicesHandler_UpdatePushToken_MissingDeviceToken(t *testing.T) {
	var calls []pushTokenCall
	srv := newPushTokenServer(fakeDevicesRegistrar{pushCalls: &calls}, service.DeviceIdentity{DeviceID: "device-abc"})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPut, "/v1/devices/me", bytes.NewBufferString(`{"push_token":"fcm-token-1"}`))
	srv.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 without a device credential, got %d", rec.Code)
	}
	if len(calls) != 0 {
		t.Errorf("service must not be called without a device credential: %+v", calls)
	}
}

func TestDevicesHandler_UpdatePushToken_InternalError(t *testing.T) {
	srv := newPushTokenServer(fakeDevicesRegistrar{pushErr: errors.New("db down")}, service.DeviceIdentity{DeviceID: "device-abc"})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPut, "/v1/devices/me", bytes.NewBufferString(`{"push_token":"fcm-token-1"}`))
	req.Header.Set("X-Device-Token", "raw-device-token")
	srv.ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d", rec.Code)
	}
	if strings.Contains(rec.Body.String(), "db down") {
		t.Errorf("internal error detail leaked to the client: %s", rec.Body.String())
	}
}
