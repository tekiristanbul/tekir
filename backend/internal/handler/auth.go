package handler

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// OTPRequester is satisfied by service.AuthService.
type OTPRequester interface {
	RequestOTP(ctx context.Context, phone string) error
}

// OTPVerifier is satisfied by service.AuthService.
type OTPVerifier interface {
	VerifyOTP(ctx context.Context, phone, code, deviceID string) (service.Session, error)
}

// SessionRefresher is satisfied by service.SessionService.
type SessionRefresher interface {
	Refresh(ctx context.Context, rawRefreshToken string) (service.Session, error)
}

// SessionRevoker is satisfied by service.SessionService.
type SessionRevoker interface {
	Revoke(ctx context.Context, rawRefreshToken string) error
}

// DisplayNameSetter is satisfied by service.AuthService.
type DisplayNameSetter interface {
	SetDisplayName(ctx context.Context, userID, displayName string) error
}

// AuthHandler answers otp request/verify, refresh, logout, and the
// new-account display-name step (issue #58).
type AuthHandler struct {
	otpRequester      OTPRequester
	otpVerifier       OTPVerifier
	refresher         SessionRefresher
	revoker           SessionRevoker
	displayNameSetter DisplayNameSetter
}

func NewAuthHandler(otpRequester OTPRequester, otpVerifier OTPVerifier, refresher SessionRefresher, revoker SessionRevoker, displayNameSetter DisplayNameSetter) *AuthHandler {
	return &AuthHandler{
		otpRequester:      otpRequester,
		otpVerifier:       otpVerifier,
		refresher:         refresher,
		revoker:           revoker,
		displayNameSetter: displayNameSetter,
	}
}

type otpRequestBody struct {
	Phone string `json:"phone"`
}

// RequestOTP answers POST /v1/auth/otp/request. It always responds 202
// regardless of the outcome visible to a caller, except for a malformed
// phone number or a resend requested before the cooldown elapses — never
// leaking whether a given phone number has an account.
func (h *AuthHandler) RequestOTP(w http.ResponseWriter, r *http.Request) {
	var req otpRequestBody
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	if err := h.otpRequester.RequestOTP(r.Context(), req.Phone); err != nil {
		switch {
		case errors.Is(err, service.ErrInvalidPhone):
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid phone number"})
		case errors.Is(err, service.ErrOTPResendTooSoon):
			writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "try again in a moment"})
		default:
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		}
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusAccepted)
}

type otpVerifyBody struct {
	Phone string `json:"phone"`
	Code  string `json:"code"`
}

type sessionResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	UserID       string `json:"user_id"`
	// IsNewAccount tells the client whether to show the new-account
	// minimum-profile (display name) step next — the prototype only asks
	// for a name the first time an account is created, never on a
	// returning login.
	IsNewAccount bool `json:"is_new_account"`
}

// VerifyOTP answers POST /v1/auth/otp/verify (X-Device-Token required). On
// success it resolves-or-creates the account, links the calling device to
// it, and returns a fresh session.
func (h *AuthHandler) VerifyOTP(w http.ResponseWriter, r *http.Request) {
	var req otpVerifyBody
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	device := DeviceFromContext(r.Context())
	session, err := h.otpVerifier.VerifyOTP(r.Context(), req.Phone, req.Code, device.DeviceID)
	if err != nil {
		writeVerifyOTPError(w, err)
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, sessionResponse{
		AccessToken:  session.AccessToken,
		RefreshToken: session.RefreshToken,
		UserID:       session.UserID,
		IsNewAccount: session.IsNewAccount,
	})
}

func writeVerifyOTPError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, service.ErrInvalidPhone):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid phone number"})
	case errors.Is(err, service.ErrOTPNotRequested), errors.Is(err, service.ErrOTPCodeMismatch):
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid code"})
	case errors.Is(err, service.ErrOTPExpired), errors.Is(err, service.ErrOTPAlreadyConsumed):
		writeJSON(w, http.StatusGone, map[string]string{"error": "code expired"})
	case errors.Is(err, service.ErrOTPTooManyAttempts):
		writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "too many attempts"})
	case errors.Is(err, service.ErrDeviceLinkedToOtherAccount):
		writeJSON(w, http.StatusConflict, map[string]string{"error": "device already linked to a different account"})
	default:
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
}

type refreshBody struct {
	RefreshToken string `json:"refresh_token"`
}

type refreshResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
}

// Refresh answers POST /v1/auth/refresh: rotates a valid refresh token
// into a new access/refresh pair without repeating otp verification.
func (h *AuthHandler) Refresh(w http.ResponseWriter, r *http.Request) {
	var req refreshBody
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	if req.RefreshToken == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "refresh_token is required"})
		return
	}

	session, err := h.refresher.Refresh(r.Context(), req.RefreshToken)
	if err != nil {
		switch {
		case errors.Is(err, service.ErrSessionExpired), errors.Is(err, service.ErrSessionRevoked), errors.Is(err, service.ErrSessionInvalid):
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid session"})
		default:
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		}
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, refreshResponse{AccessToken: session.AccessToken, RefreshToken: session.RefreshToken})
}

// Logout answers POST /v1/auth/logout (Bearer required): revokes the
// presented refresh token, ending that session, without deleting the
// installation's device identity. Idempotent — logging out twice with the
// same (now-revoked) refresh token still answers 204.
func (h *AuthHandler) Logout(w http.ResponseWriter, r *http.Request) {
	var req refreshBody
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	if req.RefreshToken == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "refresh_token is required"})
		return
	}

	if err := h.revoker.Revoke(r.Context(), req.RefreshToken); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// meResponse mirrors docs/architecture/api.md's GET /v1/me contract.
type meResponse struct {
	DeviceID      string  `json:"device_id"`
	UserID        *string `json:"user_id"`
	PhoneVerified bool    `json:"phone_verified"`
}

// Me answers GET /v1/me (X-Device-Token required, Authorization: Bearer
// optional). The account id preferred is the bearer's, if a valid one was
// presented; otherwise it falls back to the calling device's linked
// account, if any. Every account this app creates is phone-verified at
// creation time (verification and account resolution happen atomically in
// AuthService.VerifyOTP), so phone_verified is exactly "an account is
// resolved" — never a separate persisted flag to drift out of sync.
func (h *AuthHandler) Me(w http.ResponseWriter, r *http.Request) {
	device := DeviceFromContext(r.Context())
	user := UserFromContext(r.Context())

	resp := meResponse{DeviceID: device.DeviceID}
	switch {
	case user.UserID != "":
		id := user.UserID
		resp.UserID = &id
		resp.PhoneVerified = true
	case device.UserID != nil:
		resp.UserID = device.UserID
		resp.PhoneVerified = true
	}

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, resp)
}

type displayNameBody struct {
	DisplayName string `json:"display_name"`
}

// UpdateDisplayName answers PATCH /v1/me (Bearer required): sets the
// caller's account display name — the approved prototype's new-account
// minimum-profile step. A client only calls this right after
// otp/verify reports Session.IsNewAccount; the server itself does not
// enforce "only once" or "only for a new account", since that's a client
// flow convention, not a data invariant.
func (h *AuthHandler) UpdateDisplayName(w http.ResponseWriter, r *http.Request) {
	var req displayNameBody
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	user := UserFromContext(r.Context())
	if err := h.displayNameSetter.SetDisplayName(r.Context(), user.UserID, req.DisplayName); err != nil {
		if errors.Is(err, service.ErrInvalidDisplayName) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid display name"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}

	w.WriteHeader(http.StatusNoContent)
}
