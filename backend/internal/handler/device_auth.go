package handler

import (
	"context"
	"net/http"
	"strings"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// deviceContextKey is an unexported type for the device-identity context key,
// preventing collisions with keys defined in other packages.
type deviceContextKey struct{}

// DeviceTokenResolver is satisfied by service.DevicesService; kept as an
// interface so the middleware is testable without a real database connection.
type DeviceTokenResolver interface {
	ResolveToken(ctx context.Context, rawToken string) (service.DeviceIdentity, error)
}

// RequireDeviceToken is HTTP middleware that reads exactly one non-empty
// X-Device-Token header value, hashes it, resolves it to a device, and
// places the non-secret DeviceIdentity in the request context. It returns
// 401 for missing, empty, unknown, malformed, or revoked credentials.
// Do not apply this middleware to existing public read routes.
func RequireDeviceToken(svc DeviceTokenResolver) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			values := r.Header.Values("X-Device-Token")
			if len(values) != 1 {
				writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "missing device token"})
				return
			}

			token := strings.TrimSpace(values[0])
			if token == "" {
				writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "missing device token"})
				return
			}

			identity, err := svc.ResolveToken(r.Context(), token)
			if err != nil {
				writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid device token"})
				return
			}

			ctx := context.WithValue(r.Context(), deviceContextKey{}, identity)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// DeviceFromContext retrieves the DeviceIdentity from context. Returns the
// zero value if not present. Downstream handlers on device-gated routes can
// rely on it being set; public routes should not call this.
func DeviceFromContext(ctx context.Context) service.DeviceIdentity {
	v, _ := ctx.Value(deviceContextKey{}).(service.DeviceIdentity)
	return v
}

// OptionalDeviceToken behaves like RequireDeviceToken but never rejects the
// request: if X-Device-Token is absent, malformed, or unresolvable, it
// simply proceeds without a DeviceIdentity in context (DeviceFromContext
// then returns the zero value). This backs the "device association is
// optional, never sufficient authorization" contract on the follow and
// ordinary-update write routes (issue #65), which require RequireBearer
// instead.
func OptionalDeviceToken(svc DeviceTokenResolver) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			values := r.Header.Values("X-Device-Token")
			if len(values) == 1 {
				token := strings.TrimSpace(values[0])
				if token != "" {
					if identity, err := svc.ResolveToken(r.Context(), token); err == nil {
						r = r.WithContext(context.WithValue(r.Context(), deviceContextKey{}, identity))
					}
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}
