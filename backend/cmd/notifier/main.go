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

	sender, err := newNotificationSender(cfg.NotificationProvider)
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

	logger.Info("starting notifier", "provider", cfg.NotificationProvider)

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

// newNotificationSender selects the NotificationSender implementation
// named by provider. Only "fake" (the deterministic, log-only, no-network
// dev/test provider — see docs/architecture/backend.md) is implemented as
// of issue #78. Unlike newObjectStore in cmd/api, an empty provider is
// rejected too, not defaulted to "fake" — a production deployment that
// never set NOTIFICATION_PROVIDER must fail to start rather than silently
// run the dev/test provider (issue #78's explicit fail-closed constraint;
// OTP_PROVIDER gained the same production posture in issue #59 via
// config.ResolveOTPProvider).
func newNotificationSender(provider string) (service.NotificationSender, error) {
	switch provider {
	case "fake":
		return service.NewFakeNotificationSender(), nil
	case "":
		return nil, fmt.Errorf("NOTIFICATION_PROVIDER is required (only \"fake\" is implemented)")
	default:
		return nil, fmt.Errorf("unsupported NOTIFICATION_PROVIDER %q (only \"fake\" is implemented)", provider)
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
