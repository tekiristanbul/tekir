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

	// resolved before anything else so a misconfigured otp provider —
	// production with fake/unset/unknown, or twilio with missing settings —
	// stops startup here, before a database connection is even attempted
	// (issue #59). There is no fallback path from this error.
	otpProvider, err := cfg.ResolveOTPProvider()
	if err != nil {
		return err
	}

	// same fail-closed gate for the app-review otp allowlist (issue #184):
	// a half-configured OTP_REVIEW_TEST_NUMBERS/OTP_REVIEW_TEST_CODE pair
	// stops startup here rather than silently running as "off" or as a
	// global bypass. reviewNumbers is nil when the feature is unconfigured.
	reviewNumbers, reviewCode, err := cfg.ResolveOTPReviewAllowlist()
	if err != nil {
		return err
	}

	// same fail-closed startup gate for media storage (issue #89):
	// production with fake/unset/unknown, or s3 with missing settings,
	// stops here — there is no fallback path to local disk.
	objectStorageProvider, err := cfg.ResolveObjectStorageProvider()
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

	objectStore, err := newObjectStore(cfg, objectStorageProvider)
	if err != nil {
		return err
	}
	catsSvc := service.NewCatsService(store, service.WithCatsMediaPipeline(objectStore, cfg.MediaMaxBytes))
	catsHandler := handler.NewCatsHandler(catsSvc, cfg.MediaMaxBytes)
	mediaSvc := service.NewMediaService(store, objectStore, cfg.MediaMaxBytes, cfg.MediaVideoMaxBytes)
	mediaHandler := handler.NewMediaHandler(mediaSvc, max(cfg.MediaMaxBytes, cfg.MediaVideoMaxBytes))
	// GET /v1/media/objects/{key} only ever serves what FakeObjectStore
	// wrote — see docs/architecture/backend.md's OBJECT_STORAGE_PROVIDER.
	// With the s3 provider, media urls point straight at the bucket's
	// public endpoint, so this route answers 404 for everything rather
	// than proxying reads through the api.
	localObjects := handler.LocalObjectReader(noLocalObjects{})
	if fake, ok := objectStore.(*service.FakeObjectStore); ok {
		localObjects = fake
	}
	mediaServeHandler := handler.NewMediaServeHandler(localObjects)

	sessionsSvc := service.NewSessionService(store, []byte(cfg.JWTSigningKey), cfg.AccessTokenTTL, cfg.RefreshTokenTTL, service.WithSessionTxRunner(store))

	// otpProvider was already validated by cfg.ResolveOTPProvider above —
	// this switch is exhaustive over its possible returns. With twilio,
	// the SmsSender stays nil (never called — see WithExternalOTPProvider)
	// and a failing provider surfaces its mapped error rather than ever
	// degrading to the fake flow.
	authOpts := []service.AuthServiceOption{service.WithAuthTxRunner(store)}
	var sms service.SmsSender
	switch otpProvider {
	case config.OTPProviderFake:
		sms = service.NewFakeSmsSender()
	case config.OTPProviderTwilio:
		twilio, err := service.NewTwilioVerifier(cfg.TwilioAccountSID, cfg.TwilioAuthToken, cfg.TwilioVerifyServiceSID)
		if err != nil {
			return err
		}
		var external service.OTPVerificationProvider = twilio
		if len(reviewNumbers) > 0 {
			// only ever wraps twilio with the reviewer allowlist (issue
			// #184) — never active unless both env vars above resolved a
			// non-empty list, and every number outside that list still
			// goes straight through to twilio unchanged.
			external, err = service.NewReviewAllowlistOTPProvider(twilio, reviewNumbers, reviewCode)
			if err != nil {
				return err
			}
		}
		authOpts = append(authOpts, service.WithExternalOTPProvider(external))
	default:
		return fmt.Errorf("unsupported resolved otp provider %q", otpProvider)
	}
	authSvc := service.NewAuthService(store, sms, sessionsSvc, cfg.OTPCodeTTL, cfg.OTPMaxAttempts, cfg.OTPResendCooldown, authOpts...)
	authHandler := handler.NewAuthHandler(authSvc, authSvc, sessionsSvc, sessionsSvc, authSvc, authSvc)

	// the api process only ever reads/acks notifications on an account's
	// behalf; draining notification_outbox into them is cmd/notifier's
	// separate process (see docs/architecture/backend.md).
	notificationsInboxSvc := service.NewNotificationInboxService(store)
	notificationsHandler := handler.NewNotificationsHandler(notificationsInboxSvc)

	profileSvc := service.NewProfileService(store)
	profileHandler := handler.NewProfileHandler(profileSvc)

	reportsSvc := service.NewReportsService(store)
	reportsHandler := handler.NewReportsHandler(reportsSvc)

	blocksSvc := service.NewBlocksService(store)
	blocksHandler := handler.NewBlocksHandler(blocksSvc)

	accountsSvc := service.NewAccountsService(store, objectStore)
	accountsHandler := handler.NewAccountsHandler(accountsSvc)

	router := server.NewRouter(logger, healthHandler, catsHandler, devicesHandler, followsHandler, authHandler, mediaHandler, mediaServeHandler, notificationsHandler, profileHandler, reportsHandler, blocksHandler, accountsHandler, devicesSvc, sessionsSvc, cfg.CORSOrigins)

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

// newObjectStore builds the ObjectStore implementation named by provider.
// provider was already validated by cfg.ResolveObjectStorageProvider —
// this switch is exhaustive over its possible returns, mirroring the otp
// provider switch above.
func newObjectStore(cfg config.Config, provider string) (service.ObjectStore, error) {
	switch provider {
	case config.ObjectStorageProviderFake:
		return service.NewFakeObjectStore(cfg.MediaLocalDir, cfg.MediaPublicBaseURL)
	case config.ObjectStorageProviderS3:
		var opts []service.S3ObjectStoreOption
		if cfg.S3ForcePathStyle {
			opts = append(opts, service.WithS3ForcePathStyle())
		}
		return service.NewS3ObjectStore(cfg.S3Endpoint, cfg.S3Region, cfg.S3Bucket, cfg.S3AccessKeyID, cfg.S3SecretAccessKey, cfg.S3PublicBaseURL, opts...)
	default:
		return nil, fmt.Errorf("unsupported resolved object storage provider %q", provider)
	}
}

// noLocalObjects backs GET /v1/media/objects/{key} when the s3 provider is
// selected: nothing is stored locally, so every key is a clean 404 instead
// of the route disappearing (a stale local url then degrades exactly like
// a deleted object).
type noLocalObjects struct{}

func (noLocalObjects) Get(context.Context, string) ([]byte, error) {
	return nil, service.ErrObjectNotFound
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
