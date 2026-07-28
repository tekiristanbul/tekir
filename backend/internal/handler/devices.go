package handler

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// DevicesRegistrar is satisfied by service.DevicesService; kept as an
// interface so the handler is testable without a real database connection.
type DevicesRegistrar interface {
	Register(ctx context.Context, platform string, pushToken *string) (service.DeviceRegistration, error)
	SetPushToken(ctx context.Context, deviceID, pushToken string) error
}

// DevicesHandler handles the device identity registration endpoint.
type DevicesHandler struct {
	devices DevicesRegistrar
}

func NewDevicesHandler(devices DevicesRegistrar) *DevicesHandler {
	return &DevicesHandler{devices: devices}
}

// registerRequest is the parsed body of POST /v1/devices.
// PushToken is optional; Platform is required.
type registerRequest struct {
	Platform  string  `json:"platform"`
	PushToken *string `json:"push_token"`
}

// registerResponse is the one-time response body of POST /v1/devices.
// DeviceToken is the raw secret — returned exactly once and not persisted
// server-side. Cache-Control: no-store is set on the response header.
type registerResponse struct {
	DeviceID    string `json:"device_id"`
	DeviceToken string `json:"device_token"`
}

// Register handles POST /v1/devices. It validates the request body,
// delegates to the service, and returns the new device credential exactly
// once with Cache-Control: no-store so intermediaries never cache it.
func (h *DevicesHandler) Register(w http.ResponseWriter, r *http.Request) {
	var req registerRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	if req.Platform == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "platform is required"})
		return
	}

	reg, err := h.devices.Register(r.Context(), req.Platform, req.PushToken)
	if err != nil {
		if errors.Is(err, service.ErrInvalidPlatform) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unsupported platform"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusCreated, registerResponse{
		DeviceID:    reg.DeviceID,
		DeviceToken: reg.DeviceToken,
	})
}

// updatePushTokenRequest is the parsed body of PUT /v1/devices/me.
type updatePushTokenRequest struct {
	PushToken string `json:"push_token"`
}

// UpdatePushToken handles PUT /v1/devices/me (issue #84): the
// device-authenticated caller registers or refreshes its own installation's
// fcm token. The device is always the one resolved from X-Device-Token —
// there is no device id in the path or body, so one installation can never
// write another's delivery address. Responds 204: the token is a write-only
// credential and is never echoed back.
func (h *DevicesHandler) UpdatePushToken(w http.ResponseWriter, r *http.Request) {
	var req updatePushTokenRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	identity := DeviceFromContext(r.Context())
	if err := h.devices.SetPushToken(r.Context(), identity.DeviceID, req.PushToken); err != nil {
		if errors.Is(err, service.ErrInvalidPushToken) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid push token"})
			return
		}
		if errors.Is(err, service.ErrDeviceNotFound) {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid device token"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}

	w.WriteHeader(http.StatusNoContent)
}
