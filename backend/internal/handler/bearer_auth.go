package handler

import (
	"context"
	"net/http"
	"strings"
)

// userContextKey is an unexported type for the account-identity context
// key, preventing collisions with keys defined in other packages (mirrors
// deviceContextKey).
type userContextKey struct{}

// UserIdentity is the non-secret representation of a resolved account,
// placed in request context by RequireBearer.
type UserIdentity struct {
	UserID string
}

// AccessTokenValidator is satisfied by service.SessionService; kept as an
// interface so the middleware is testable without a real database
// connection or a real signing key.
type AccessTokenValidator interface {
	ValidateAccessToken(rawToken string) (string, error)
}

// RequireBearer is HTTP middleware that reads exactly one non-empty
// "Authorization: Bearer <token>" header value, validates it as an access
// token, and places the non-secret UserIdentity in the request context. It
// returns 401 for a missing, malformed, expired, or invalid-signature
// token — mirroring RequireDeviceToken's generic-401 convention so a
// caller never learns which of those applies.
func RequireBearer(svc AccessTokenValidator) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			values := r.Header.Values("Authorization")
			if len(values) != 1 {
				writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "missing bearer token"})
				return
			}

			const prefix = "Bearer "
			if !strings.HasPrefix(values[0], prefix) {
				writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "missing bearer token"})
				return
			}

			token := strings.TrimSpace(strings.TrimPrefix(values[0], prefix))
			if token == "" {
				writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "missing bearer token"})
				return
			}

			userID, err := svc.ValidateAccessToken(token)
			if err != nil {
				writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid bearer token"})
				return
			}

			ctx := context.WithValue(r.Context(), userContextKey{}, UserIdentity{UserID: userID})
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// UserFromContext retrieves the UserIdentity from context. Returns the
// zero value if not present. Handlers on bearer-gated routes can rely on
// it being set; other routes should not call this.
func UserFromContext(ctx context.Context) UserIdentity {
	v, _ := ctx.Value(userContextKey{}).(UserIdentity)
	return v
}

// OptionalBearer behaves like RequireBearer but never rejects the
// request: if Authorization is absent or invalid, it simply proceeds
// without a UserIdentity in context (UserFromContext then returns the
// zero value). This backs GET /v1/me's "X-Device-Token required, Bearer
// optional" contract (docs/architecture/api.md).
func OptionalBearer(svc AccessTokenValidator) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			values := r.Header.Values("Authorization")
			const prefix = "Bearer "
			if len(values) == 1 && strings.HasPrefix(values[0], prefix) {
				token := strings.TrimSpace(strings.TrimPrefix(values[0], prefix))
				if token != "" {
					if userID, err := svc.ValidateAccessToken(token); err == nil {
						r = r.WithContext(context.WithValue(r.Context(), userContextKey{}, UserIdentity{UserID: userID}))
					}
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}
