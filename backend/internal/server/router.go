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

func NewRouter(logger *slog.Logger, health *handler.HealthHandler, cats *handler.CatsHandler, devices *handler.DevicesHandler, deviceTokens handler.DeviceTokenResolver, corsOrigins []string) http.Handler {
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
		AllowedMethods: []string{http.MethodGet, http.MethodPost, http.MethodPut, http.MethodDelete},
		AllowedHeaders: []string{"Content-Type", "Authorization", "X-Device-Token"},
	}))

	r.Get("/healthz", health.Live)
	r.Get("/readyz", health.Ready)

	r.Get("/v1/cats", cats.Nearby)
	r.Get("/v1/cats/{cat_id}", cats.Detail)
	r.Get("/v1/cats/{cat_id}/updates", cats.UpdateHistory)
	r.With(handler.RequireDeviceToken(deviceTokens)).Post("/v1/cats/{cat_id}/updates", cats.CreateUpdate)

	r.Post("/v1/devices", devices.Register)

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
