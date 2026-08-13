// Package server wires the HTTP router and its lifecycle.
package server

import (
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/go-chi/cors"

	"github.com/tekiristanbul/tekir/backend/internal/handler"
)

func NewRouter(logger *slog.Logger, health *handler.HealthHandler, cats *handler.CatsHandler, devices *handler.DevicesHandler, follows *handler.FollowsHandler, auth *handler.AuthHandler, media *handler.MediaHandler, mediaServe *handler.MediaServeHandler, notifications *handler.NotificationsHandler, profile *handler.ProfileHandler, deviceTokens handler.DeviceTokenResolver, accessTokens handler.AccessTokenValidator, corsOrigins []string) http.Handler {
	r := chi.NewRouter()

	r.Use(middleware.RequestID)
	// no RealIP: it's deprecated and spoofable (blindly trusts X-Forwarded-For)
	// with no reverse proxy / trust boundary decided yet. add a trusted-proxy-aware
	// alternative (e.g. ClientIPFromXFFTrustedProxies) once that's settled.
	r.Use(requestLogger(logger))
	r.Use(middleware.Recoverer)
	r.Use(middleware.Timeout(60 * time.Second))
	// the flutter web target makes browser-side requests to the api, which
	// are subject to CORS; origins are configurable since the eventual
	// deployed app origin isn't decided yet.
	r.Use(cors.Handler(cors.Options{
		AllowedOrigins: corsOrigins,
		AllowedMethods: []string{http.MethodGet, http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete},
		AllowedHeaders: []string{"Content-Type", "Authorization", "X-Device-Token", "Idempotency-Key"},
	}))

	r.Get("/healthz", health.Live)
	r.Get("/readyz", health.Ready)

	r.Get("/v1/cats", cats.Nearby)
	r.Get("/v1/cats/nearby", cats.NearbyDuplicates)
	r.Get("/v1/cats/discover", cats.Discover)
	r.With(handler.OptionalBearer(accessTokens)).Get("/v1/cats/{cat_id}", cats.Detail)
	r.With(handler.RequireBearer(accessTokens)).Patch("/v1/cats/{cat_id}", cats.Rename)
	r.With(handler.RequireBearer(accessTokens)).Delete("/v1/cats/{cat_id}", cats.Delete)
	r.Get("/v1/cats/{cat_id}/media", cats.Media)
	r.With(handler.RequireBearer(accessTokens)).Patch("/v1/cats/{cat_id}/cover", cats.SetCover)
	r.With(handler.OptionalBearer(accessTokens)).Get("/v1/cats/{cat_id}/updates", cats.UpdateHistory)
	r.With(handler.RequireBearer(accessTokens), handler.OptionalDeviceToken(deviceTokens)).Post("/v1/cats", cats.Create)
	r.With(handler.RequireBearer(accessTokens), handler.OptionalDeviceToken(deviceTokens)).Post("/v1/cats/{cat_id}/updates", cats.CreateUpdate)
	r.With(handler.RequireBearer(accessTokens)).Patch("/v1/cats/{cat_id}/updates/{update_id}", cats.CorrectUpdate)
	r.With(handler.RequireBearer(accessTokens)).Delete("/v1/cats/{cat_id}/updates/{update_id}", cats.DeleteUpdate)
	r.With(handler.RequireBearer(accessTokens), handler.OptionalDeviceToken(deviceTokens)).Post("/v1/cats/{cat_id}/needs-help", cats.CreateNeedsHelp)
	r.With(handler.RequireBearer(accessTokens), handler.OptionalDeviceToken(deviceTokens)).Post("/v1/cats/{cat_id}/follow", follows.Follow)
	r.With(handler.RequireBearer(accessTokens)).Delete("/v1/cats/{cat_id}/follow", follows.Unfollow)
	r.With(handler.RequireBearer(accessTokens)).Get("/v1/me/follows", follows.ListFollows)

	r.With(handler.RequireBearer(accessTokens)).Get("/v1/me/notifications", notifications.List)
	r.With(handler.RequireBearer(accessTokens)).Post("/v1/me/notifications/{id}/read", notifications.MarkRead)

	r.With(handler.RequireBearer(accessTokens)).Get("/v1/me/profile", profile.Profile)
	r.With(handler.RequireBearer(accessTokens)).Get("/v1/me/badges", profile.Badges)

	r.With(handler.RequireBearer(accessTokens), handler.OptionalDeviceToken(deviceTokens)).Post("/v1/media", media.Upload)
	r.Get("/v1/media/objects/{key}", mediaServe.ServeObject)

	r.Post("/v1/devices", devices.Register)
	// device-authenticated, deliberately not bearer-gated (issue #84): the
	// push token is installation state, like the device credential itself —
	// account linkage only decides notification *eligibility* server-side.
	r.With(handler.RequireDeviceToken(deviceTokens)).Put("/v1/devices/me", devices.UpdatePushToken)

	r.Post("/v1/auth/otp/request", auth.RequestOTP)
	r.With(handler.RequireDeviceToken(deviceTokens)).Post("/v1/auth/otp/verify", auth.VerifyOTP)
	r.Post("/v1/auth/refresh", auth.Refresh)
	r.With(handler.RequireBearer(accessTokens), handler.OptionalDeviceToken(deviceTokens)).Post("/v1/auth/logout", auth.Logout)
	r.With(handler.RequireDeviceToken(deviceTokens), handler.OptionalBearer(accessTokens)).Get("/v1/me", auth.Me)
	r.With(handler.RequireBearer(accessTokens)).Patch("/v1/me", auth.UpdateDisplayName)

	return r
}

// requestLogger logs each request as a single structured line once it completes.
func requestLogger(logger *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)

			next.ServeHTTP(ww, r)

			logger.Info("request",
				"method", r.Method,
				"path", r.URL.Path,
				"status", ww.Status(),
				"bytes", ww.BytesWritten(),
				"duration_ms", time.Since(start).Milliseconds(),
				"request_id", middleware.GetReqID(r.Context()),
			)
		})
	}
}
