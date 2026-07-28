// Command notifier is the separate binary/process (issue #78,
// docs/architecture/backend.md) that drains notification_outbox: for a
// needs-help update, it fans out to the cat's followers' devices; for an
// ordinary update, it just marks the row processed. See
// service.NotificationService.DispatchPending for the actual logic — this
// file only wires config/db/provider selection and the poll loop around it.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/tekiristanbul/tekir/backend/internal/config"
	"github.com/tekiristanbul/tekir/backend/internal/repository"
	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// pollInterval is how often DispatchPending is called when the previous
// call found nothing to process. Short enough that a needs-help update's
// notification shows up promptly in a local/manual walkthrough; a produced
// batch is drained immediately (see run's loop) rather than waiting out a
// full interval between batches.
const pollInterval = 2 * time.Second

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

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: logLevel(cfg.LogLevel)}))
	slog.SetDefault(logger)

	provider, err := cfg.ResolveNotificationProvider()
	if err != nil {
		return err
	}
	sender, err := newNotificationSender(provider, cfg)
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()

	store := repository.NewStore(pool)
	notifications := service.NewNotificationService(store, sender)

	logger.Info("starting notifier", "provider", provider)

	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			logger.Info("shutdown signal received")
			return nil
		case <-ticker.C:
			for {
				processed, err := notifications.DispatchPending(ctx)
				if err != nil {
					logger.Error("dispatch failed", "error", err)
					break
				}
				if processed == 0 {
					break
				}
				logger.Info("dispatched outbox batch", "processed", processed)
			}
		}
	}
}

// newNotificationSender constructs the NotificationSender for an already
// resolved provider — config.ResolveNotificationProvider (issue #84) owns
// the environment-aware defaulting and fail-closed validation (the same
// split as cmd/api's otp wiring, issue #59), so by the time this runs the
// provider is one of the known values. "fake" is the deterministic,
// log-only, no-network dev/test provider (issue #78); "fcm" is firebase
// cloud messaging over http v1 (issue #84), whose constructor separately
// fails startup on unreadable or incomplete credentials rather than ever
// degrading to fake.
func newNotificationSender(provider string, cfg config.Config) (service.NotificationSender, error) {
	switch provider {
	case config.NotificationProviderFake:
		return service.NewFakeNotificationSender(), nil
	case config.NotificationProviderFCM:
		return service.NewFCMNotificationSender(cfg.FCMCredentialsFile)
	default:
		// unreachable after ResolveNotificationProvider, kept fail-closed
		// anyway.
		return nil, fmt.Errorf("unsupported NOTIFICATION_PROVIDER %q", provider)
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
