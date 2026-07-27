package service

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

const (
	defaultNotificationsLimit = 20
	maxNotificationsLimit     = 50
)

// ErrInvalidNotificationID means the {id} path segment of
// POST /v1/me/notifications/{id}/read isn't a well-formed uuid.
var ErrInvalidNotificationID = errors.New("invalid notification id")

// Notification is one entry of the authenticated account's own notification
// inbox (issue #78) — the in-app representation of "a followed cat got a
// needs-help update", since this mvp slice has no real push transport (see
// NotificationSender's doc comment). Read is server-decided from
// notifications.read_at, never left for the client to track locally.
type Notification struct {
	ID        string
	CatID     string
	UpdateID  string
	Read      bool
	CreatedAt time.Time
}

// NotificationsPage is one newest-first page of an account's notifications.
// NextCursor is empty when there is no further page.
type NotificationsPage struct {
	Items      []Notification
	NextCursor string
}

// notificationsCursor is the decoded, opaque pagination position: the
// (created_at, id) of the last item on the previous page — mirrors
// updatesCursor's shape, keyed by notifications' own uuid primary key
// rather than a seq column, since notifications has no sequence.
type notificationsCursor struct {
	createdAt time.Time
	id        uuid.UUID
}

// NotificationInboxStore is satisfied by repository.Store; kept as an
// interface here so NotificationInboxService stays testable without a real
// database connection.
type NotificationInboxStore interface {
	ListMyNotifications(ctx context.Context, arg repository.ListMyNotificationsParams) ([]repository.ListMyNotificationsRow, error)
	MarkNotificationRead(ctx context.Context, arg repository.MarkNotificationReadParams) error
}

// NotificationInboxService answers GET /v1/me/notifications and its
// mark-read endpoint — distinct from NotificationService (issue #78's
// outbox-draining worker): this is the read/ack side an authenticated
// account uses, that the worker's fan-out writes into.
type NotificationInboxService struct {
	db    NotificationInboxStore
	clock func() time.Time
}

// NotificationInboxServiceOption configures optional NotificationInboxService behavior.
type NotificationInboxServiceOption func(*NotificationInboxService)

// WithNotificationInboxClock overrides the clock MarkRead stamps read_at
// with — production wiring doesn't need this, but it lets tests assert an
// exact timestamp deterministically.
func WithNotificationInboxClock(clock func() time.Time) NotificationInboxServiceOption {
	return func(s *NotificationInboxService) { s.clock = clock }
}

func NewNotificationInboxService(db NotificationInboxStore, opts ...NotificationInboxServiceOption) *NotificationInboxService {
	s := &NotificationInboxService{db: db, clock: time.Now}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

// ListMyNotifications returns one newest-first page of userID's own
// notifications — never another account's, since the underlying query
// joins through the caller's own linked devices (see
// db/queries/notifications.sql's ListMyNotifications).
func (s *NotificationInboxService) ListMyNotifications(ctx context.Context, userID, cursor string, limit int) (NotificationsPage, error) {
	authorUserID, err := uuid.Parse(userID)
	if err != nil {
		return NotificationsPage{}, err
	}

	if limit == 0 {
		limit = defaultNotificationsLimit
	}
	if limit < 0 || limit > maxNotificationsLimit {
		return NotificationsPage{}, ErrInvalidLimit
	}

	decoded, err := decodeNotificationsCursor(cursor)
	if err != nil {
		return NotificationsPage{}, err
	}

	params := repository.ListMyNotificationsParams{
		UserID: pgtype.UUID{Bytes: authorUserID, Valid: true},
		// fetch one extra row to detect a next page without a separate count query.
		RowLimit: int32(limit + 1),
	}
	if decoded != nil {
		params.BeforeCreatedAt = pgtype.Timestamptz{Time: decoded.createdAt, Valid: true}
		params.BeforeID = pgtype.UUID{Bytes: decoded.id, Valid: true}
	}

	rows, err := s.db.ListMyNotifications(ctx, params)
	if err != nil {
		return NotificationsPage{}, err
	}

	hasMore := len(rows) > limit
	if hasMore {
		rows = rows[:limit]
	}

	items := make([]Notification, 0, len(rows))
	for _, r := range rows {
		items = append(items, Notification{
			ID:        uuid.UUID(r.ID.Bytes).String(),
			CatID:     uuid.UUID(r.CatID.Bytes).String(),
			UpdateID:  uuid.UUID(r.UpdateID.Bytes).String(),
			Read:      r.ReadAt.Valid,
			CreatedAt: r.CreatedAt.Time,
		})
	}

	page := NotificationsPage{Items: items}
	if hasMore {
		last := rows[len(rows)-1]
		page.NextCursor = encodeNotificationsCursor(notificationsCursor{createdAt: last.CreatedAt.Time, id: uuid.UUID(last.ID.Bytes)})
	}
	return page, nil
}

// MarkRead marks notification id read for userID. Owner-scoped and
// idempotent (see MarkNotificationRead's query comment) — marking another
// account's notification, or an already-read one, is never an error; the
// former simply updates zero rows.
func (s *NotificationInboxService) MarkRead(ctx context.Context, userID, id string) error {
	authorUserID, err := uuid.Parse(userID)
	if err != nil {
		return err
	}
	notificationID, err := uuid.Parse(id)
	if err != nil {
		return ErrInvalidNotificationID
	}
	return s.db.MarkNotificationRead(ctx, repository.MarkNotificationReadParams{
		ReadAt: pgtype.Timestamptz{Time: s.clock(), Valid: true},
		ID:     pgtype.UUID{Bytes: notificationID, Valid: true},
		UserID: pgtype.UUID{Bytes: authorUserID, Valid: true},
	})
}

func encodeNotificationsCursor(c notificationsCursor) string {
	raw := fmt.Sprintf("%d:%s", c.createdAt.UnixNano(), c.id.String())
	return base64.RawURLEncoding.EncodeToString([]byte(raw))
}

func decodeNotificationsCursor(raw string) (*notificationsCursor, error) {
	if raw == "" {
		return nil, nil
	}
	decoded, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return nil, ErrInvalidCursor
	}
	nanosPart, idPart, ok := strings.Cut(string(decoded), ":")
	if !ok {
		return nil, ErrInvalidCursor
	}
	nanos, err := strconv.ParseInt(nanosPart, 10, 64)
	if err != nil {
		return nil, ErrInvalidCursor
	}
	id, err := uuid.Parse(idPart)
	if err != nil {
		return nil, ErrInvalidCursor
	}
	return &notificationsCursor{createdAt: time.Unix(0, nanos).UTC(), id: id}, nil
}
