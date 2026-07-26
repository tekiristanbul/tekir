package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/tekiristanbul/tekir/backend/internal/config"
	"github.com/tekiristanbul/tekir/backend/internal/handler"
	"github.com/tekiristanbul/tekir/backend/internal/repository"
	"github.com/tekiristanbul/tekir/backend/internal/server"
	"github.com/tekiristanbul/tekir/backend/internal/service"
)

func main() {
	if err := run(); err != nil {
		slog.Error("fatal", "error", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: logLevel(cfg.LogLevel),
	}))
	slog.SetDefault(logger)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()

	store := repository.NewStore(pool)
	healthSvc := service.NewHealthService(store)
	healthHandler := handler.NewHealthHandler(healthSvc)
	catsSvc := service.NewCatsService(store)
	catsHandler := handler.NewCatsHandler(catsSvc)
	devicesSvc := service.NewDevicesService(store)
	devicesHandler := handler.NewDevicesHandler(devicesSvc)
	followsSvc := service.NewFollowsService(store)
	followsHandler := handler.NewFollowsHandler(followsSvc)

	sms, err := newSmsSender(cfg.OTPProvider)
	if err != nil {
		return err
	}
	sessionsSvc := service.NewSessionService(store, []byte(cfg.JWTSigningKey), cfg.AccessTokenTTL, cfg.RefreshTokenTTL, service.WithSessionTxRunner(store))
	authSvc := service.NewAuthService(store, sms, sessionsSvc, cfg.OTPCodeTTL, cfg.OTPMaxAttempts, cfg.OTPResendCooldown, service.WithAuthTxRunner(store))
	authHandler := handler.NewAuthHandler(authSvc, authSvc, sessionsSvc, sessionsSvc, authSvc)

	router := server.NewRouter(logger, healthHandler, catsHandler, devicesHandler, followsHandler, authHandler, devicesSvc, sessionsSvc, cfg.CORSOrigins)

	httpServer := &http.Server{
		Addr:    ":" + cfg.Port,
		Handler: router,
	}

	serveErr := make(chan error, 1)
	go func() {
		logger.Info("starting server", "port", cfg.Port)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serveErr <- err
			return
		}
		serveErr <- nil
	}()

	select {
	case <-ctx.Done():
		logger.Info("shutdown signal received")
	case err := <-serveErr:
		if err != nil {
			return err
		}
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()

	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		return err
	}

	logger.Info("server stopped")
	return nil
}

// newSmsSender selects the SmsSender implementation named by provider.
// Only "fake" (the deterministic, log-only, no-network dev/test provider —
// see docs/architecture/backend.md) is implemented as of issue #58; an
// unrecognized value fails loudly at startup rather than silently
// defaulting to a provider the operator didn't ask for.
func newSmsSender(provider string) (service.SmsSender, error) {
	switch provider {
	case "fake":
		return service.NewFakeSmsSender(), nil
	default:
		return nil, fmt.Errorf("unsupported OTP_PROVIDER %q (only \"fake\" is implemented)", provider)
	}
}

func logLevel(level string) slog.Level {
	switch level {
	case "debug":
		return slog.LevelDebug
	case "warn":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
