package service

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// defaultDispatchBatchSize bounds how many outbox rows one DispatchPending
// call claims — small enough that one slow/large fan-out never starves
// other pending rows behind it, generous enough that a normal poll drains
// the queue in one pass under everyday load.
const defaultDispatchBatchSize = 50

// NotificationService drains notification_outbox (issue #78): for each
// claimed row, a needs-help update fans out to the cat's followers'
// devices (excluding the author) via NotificationSender, deduplicated
// against notifications' (device_id, update_id) unique constraint; an
// ordinary update's row is marked processed with no fan-out at all — mvp
// only ever notifies for needs-help (docs/product/notifications.md).
type NotificationService struct {
	tx        TxRunner
	sender    NotificationSender
	clock     func() time.Time
	batchSize int32
}

// NotificationServiceOption configures optional NotificationService behavior.
type NotificationServiceOption func(*NotificationService)

// WithNotificationClock overrides the clock DispatchPending stamps
// notification_outbox.processed_at with — production wiring doesn't need
// this (it defaults to time.Now), but it lets tests assert exact
// timestamps deterministically.
func WithNotificationClock(clock func() time.Time) NotificationServiceOption {
	return func(s *NotificationService) { s.clock = clock }
}

// WithDispatchBatchSize overrides defaultDispatchBatchSize — mainly so
// tests can force multiple DispatchPending calls to observe multi-batch
// behavior without enqueueing 50 rows.
func WithDispatchBatchSize(size int32) NotificationServiceOption {
	return func(s *NotificationService) { s.batchSize = size }
}

// NewNotificationService requires tx (not optional, unlike AuthService's
// TxRunner): ClaimNotificationOutboxBatch's `for update skip locked` claim
// must hold for the entire duration of recipient resolution, notification
// inserts, and the outbox row's processed_at update, or two concurrent
// workers could both claim and double-process the same row.
func NewNotificationService(tx TxRunner, sender NotificationSender, opts ...NotificationServiceOption) *NotificationService {
	s := &NotificationService{tx: tx, sender: sender, clock: time.Now, batchSize: defaultDispatchBatchSize}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

// DispatchPending claims and processes one batch of pending outbox rows,
// returning how many it processed. Called directly (no sleep, no
// goroutine) by integration tests for deterministic assertions, and on an
// interval by cmd/notifier in production. A send failure for one recipient
// device is logged and skipped, never returned as an error — a
// notification-delivery problem must not roll back the whole batch's
// outbox claim, let alone the needs-help update itself (issue #78's
// explicit constraint).
func (s *NotificationService) DispatchPending(ctx context.Context) (int, error) {
	processed := 0
	err := s.tx.WithinTx(ctx, func(q *repository.Queries) error {
		rows, err := q.ClaimNotificationOutboxBatch(ctx, s.batchSize)
		if err != nil {
			return err
		}
		for _, row := range rows {
			// issue #101: the fan-out gate is the help flag, not the legacy
			// kind column. A mark made while the cat already had an active
			// help state (NeedsHelpAlreadyActive, decided by the claim query
			// against the mark's own created_at) is processed with no
			// recipients at all — the product decision on the #100
			// contract's re-marking question: the state continues, the 72h
			// window restarts, nobody is notified twice.
			if row.NeedsHelp && !row.NeedsHelpAlreadyActive {
				if err := s.dispatchNeedsHelp(ctx, q, row); err != nil {
					return err
				}
			}
			if err := q.MarkNotificationOutboxProcessed(ctx, repository.MarkNotificationOutboxProcessedParams{
				ID:          row.ID,
				ProcessedAt: pgtype.Timestamptz{Time: s.clock(), Valid: true},
			}); err != nil {
				return err
			}
			processed++
		}
		return nil
	})
	return processed, err
}

func (s *NotificationService) dispatchNeedsHelp(ctx context.Context, q *repository.Queries, row repository.ClaimNotificationOutboxBatchRow) error {
	recipients, err := q.ListNeedsHelpRecipientDevices(ctx, repository.ListNeedsHelpRecipientDevicesParams{
		CatID:        row.CatID,
		AuthorUserID: row.AuthorUserID,
	})
	if err != nil {
		return err
	}

	catIDStr := uuid.UUID(row.CatID.Bytes).String()
	updateIDStr := uuid.UUID(row.UpdateID.Bytes).String()

	for _, rec := range recipients {
		_, err := q.CreateNotification(ctx, repository.CreateNotificationParams{
			ID:       pgtype.UUID{Bytes: uuid.New(), Valid: true},
			DeviceID: rec.DeviceID,
			CatID:    row.CatID,
			UpdateID: row.UpdateID,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				// already delivered to this device for this update — a
				// retried dispatch of the same claimed row, or (in theory)
				// another worker having raced this one before the unique
				// constraint applies. Either way, not a new send.
				continue
			}
			return err
		}

		// the in-app notifications row above is the source of truth and was
		// created unconditionally — push is additive on top of it (issue
		// #84). A device that never registered a push token (opt-in
		// declined, web without permission) simply isn't pushed to.
		if !rec.PushToken.Valid || rec.PushToken.String == "" {
			continue
		}

		deviceIDStr := uuid.UUID(rec.DeviceID.Bytes).String()
		if err := s.sender.Send(ctx, PushMessage{
			DeviceID:  deviceIDStr,
			PushToken: rec.PushToken.String,
			CatID:     catIDStr,
			UpdateID:  updateIDStr,
		}); err != nil {
			if errors.Is(err, ErrPushTokenInvalid) {
				// permanent rejection (unregistered/invalid token — issue
				// #84): retire the token so this device stops being pushed
				// to until the client registers a fresh one. Token-matched
				// in the query, so a concurrently refreshed token survives.
				if clearErr := q.ClearDevicePushToken(ctx, repository.ClearDevicePushTokenParams(rec)); clearErr != nil {
					return clearErr
				}
				slog.Info("retired invalid push token", "device_id", deviceIDStr)
				continue
			}
			slog.Warn("needs-help notification send failed (delivery is at-most-once for mvp — not retried)",
				"device_id", deviceIDStr, "update_id", updateIDStr, "error", err)
		}
	}
	return nil
}
