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
	devicesSvc := service.NewDevicesService(store)
	devicesHandler := handler.NewDevicesHandler(devicesSvc)
	followsSvc := service.NewFollowsService(store)
	followsHandler := handler.NewFollowsHandler(followsSvc)

	sms, err := newSmsSender(cfg.OTPProvider)
	if err != nil {
		return err
	}

	objectStore, err := newObjectStore(cfg.ObjectStorageProvider, cfg.MediaLocalDir, cfg.MediaPublicBaseURL)
	if err != nil {
		return err
	}
	catsSvc := service.NewCatsService(store, service.WithCatsMediaPipeline(objectStore, cfg.MediaMaxBytes))
	catsHandler := handler.NewCatsHandler(catsSvc, cfg.MediaMaxBytes)
	mediaSvc := service.NewMediaService(store, objectStore, cfg.MediaMaxBytes)
	mediaHandler := handler.NewMediaHandler(mediaSvc, cfg.MediaMaxBytes)
	// GET /v1/media/objects/{key} only ever serves what FakeObjectStore
	// wrote — see docs/architecture/backend.md's OBJECT_STORAGE_PROVIDER.
	// newObjectStore fails startup on any other provider value, so this
	// concrete-type assertion always succeeds as of issue #70.
	mediaServeHandler := handler.NewMediaServeHandler(objectStore.(*service.FakeObjectStore))

	sessionsSvc := service.NewSessionService(store, []byte(cfg.JWTSigningKey), cfg.AccessTokenTTL, cfg.RefreshTokenTTL, service.WithSessionTxRunner(store))
	authSvc := service.NewAuthService(store, sms, sessionsSvc, cfg.OTPCodeTTL, cfg.OTPMaxAttempts, cfg.OTPResendCooldown, service.WithAuthTxRunner(store))
	authHandler := handler.NewAuthHandler(authSvc, authSvc, sessionsSvc, sessionsSvc, authSvc, authSvc)

	// the api process only ever reads/acks notifications on an account's
	// behalf; draining notification_outbox into them is cmd/notifier's
	// separate process (see docs/architecture/backend.md).
	notificationsInboxSvc := service.NewNotificationInboxService(store)
	notificationsHandler := handler.NewNotificationsHandler(notificationsInboxSvc)

	profileSvc := service.NewProfileService(store)
	profileHandler := handler.NewProfileHandler(profileSvc)

	router := server.NewRouter(logger, healthHandler, catsHandler, devicesHandler, followsHandler, authHandler, mediaHandler, mediaServeHandler, notificationsHandler, profileHandler, devicesSvc, sessionsSvc, cfg.CORSOrigins)

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

// newObjectStore selects the ObjectStore implementation named by provider.
// Only "fake" (the deterministic, local-disk dev/test provider — see
// docs/architecture/backend.md) is implemented as of issue #70, mirroring
// newSmsSender: an unrecognized value fails loudly at startup rather than
// silently defaulting to a provider the operator didn't ask for.
func newObjectStore(provider, localDir, publicBaseURL string) (service.ObjectStore, error) {
	switch provider {
	case "fake":
		return service.NewFakeObjectStore(localDir, publicBaseURL)
	default:
		return nil, fmt.Errorf("unsupported OBJECT_STORAGE_PROVIDER %q (only \"fake\" is implemented)", provider)
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
