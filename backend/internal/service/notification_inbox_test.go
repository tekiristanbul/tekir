package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

type fakeNotificationInboxStore struct {
	rows []repository.ListMyNotificationsRow
	err  error

	markErr            error
	capturedMarkUserID *pgtype.UUID
	capturedMarkID     *pgtype.UUID
	capturedMarkReadAt *pgtype.Timestamptz
	capturedListUserID *pgtype.UUID
	capturedListParams *repository.ListMyNotificationsParams
}

func (f fakeNotificationInboxStore) ListMyNotifications(_ context.Context, arg repository.ListMyNotificationsParams) ([]repository.ListMyNotificationsRow, error) {
	if f.capturedListUserID != nil {
		*f.capturedListUserID = arg.UserID
	}
	if f.capturedListParams != nil {
		*f.capturedListParams = arg
	}
	return f.rows, f.err
}

func (f fakeNotificationInboxStore) MarkNotificationRead(_ context.Context, arg repository.MarkNotificationReadParams) error {
	if f.capturedMarkUserID != nil {
		*f.capturedMarkUserID = arg.UserID
	}
	if f.capturedMarkID != nil {
		*f.capturedMarkID = arg.ID
	}
	if f.capturedMarkReadAt != nil {
		*f.capturedMarkReadAt = arg.ReadAt
	}
	return f.markErr
}

func TestNotificationInboxService_ListMyNotifications_Success(t *testing.T) {
	userID := uuid.New()
	notifID := uuid.New()
	catID := uuid.New()
	updateID := uuid.New()
	createdAt := time.Date(2026, 3, 1, 9, 0, 0, 0, time.UTC)

	svc := NewNotificationInboxService(fakeNotificationInboxStore{
		rows: []repository.ListMyNotificationsRow{
			{
				ID:        pgtype.UUID{Bytes: notifID, Valid: true},
				CatID:     pgtype.UUID{Bytes: catID, Valid: true},
				UpdateID:  pgtype.UUID{Bytes: updateID, Valid: true},
				ReadAt:    pgtype.Timestamptz{},
				CreatedAt: pgtype.Timestamptz{Time: createdAt, Valid: true},
			},
		},
	})

	page, err := svc.ListMyNotifications(context.Background(), userID.String(), "", 0)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(page.Items) != 1 {
		t.Fatalf("expected 1 item, got %d", len(page.Items))
	}
	item := page.Items[0]
	if item.ID != notifID.String() || item.CatID != catID.String() || item.UpdateID != updateID.String() {
		t.Errorf("unexpected item: %+v", item)
	}
	if item.Read {
		t.Errorf("expected read false for a null read_at")
	}
	if !item.CreatedAt.Equal(createdAt) {
		t.Errorf("expected created_at %v, got %v", createdAt, item.CreatedAt)
	}
	if page.NextCursor != "" {
		t.Errorf("expected no next cursor, got %q", page.NextCursor)
	}
}

func TestNotificationInboxService_ListMyNotifications_ReadTrueWhenReadAtSet(t *testing.T) {
	svc := NewNotificationInboxService(fakeNotificationInboxStore{
		rows: []repository.ListMyNotificationsRow{
			{
				ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
				CatID:     pgtype.UUID{Bytes: uuid.New(), Valid: true},
				UpdateID:  pgtype.UUID{Bytes: uuid.New(), Valid: true},
				ReadAt:    pgtype.Timestamptz{Time: time.Now(), Valid: true},
				CreatedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
			},
		},
	})
	page, err := svc.ListMyNotifications(context.Background(), uuid.New().String(), "", 0)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if !page.Items[0].Read {
		t.Errorf("expected read true when read_at is set")
	}
}

func TestNotificationInboxService_ListMyNotifications_NextCursorWhenMoreRows(t *testing.T) {
	rows := make([]repository.ListMyNotificationsRow, 3)
	base := time.Date(2026, 3, 1, 9, 0, 0, 0, time.UTC)
	for i := range rows {
		rows[i] = repository.ListMyNotificationsRow{
			ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
			CatID:     pgtype.UUID{Bytes: uuid.New(), Valid: true},
			UpdateID:  pgtype.UUID{Bytes: uuid.New(), Valid: true},
			CreatedAt: pgtype.Timestamptz{Time: base.Add(-time.Duration(i) * time.Minute), Valid: true},
		}
	}
	var captured repository.ListMyNotificationsParams
	svc := NewNotificationInboxService(fakeNotificationInboxStore{rows: rows, capturedListParams: &captured})

	page, err := svc.ListMyNotifications(context.Background(), uuid.New().String(), "", 2)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(page.Items) != 2 {
		t.Fatalf("expected 2 items (extra row trimmed), got %d", len(page.Items))
	}
	if page.NextCursor == "" {
		t.Fatalf("expected a next cursor when more rows exist")
	}
	if captured.RowLimit != 3 {
		t.Errorf("expected row_limit+1 = 3 fetched, got %d", captured.RowLimit)
	}

	// the cursor round-trips through a second call, decodeable without error.
	if _, err := svc.ListMyNotifications(context.Background(), uuid.New().String(), page.NextCursor, 2); err != nil {
		t.Fatalf("expected cursor to be accepted on a second call, got %v", err)
	}
}

func TestNotificationInboxService_ListMyNotifications_InvalidCursor(t *testing.T) {
	svc := NewNotificationInboxService(fakeNotificationInboxStore{})
	_, err := svc.ListMyNotifications(context.Background(), uuid.New().String(), "not-valid-base64!!", 0)
	if !errors.Is(err, ErrInvalidCursor) {
		t.Fatalf("expected ErrInvalidCursor, got %v", err)
	}
}

func TestNotificationInboxService_ListMyNotifications_InvalidLimit(t *testing.T) {
	svc := NewNotificationInboxService(fakeNotificationInboxStore{})
	_, err := svc.ListMyNotifications(context.Background(), uuid.New().String(), "", maxNotificationsLimit+1)
	if !errors.Is(err, ErrInvalidLimit) {
		t.Fatalf("expected ErrInvalidLimit, got %v", err)
	}
}

func TestNotificationInboxService_ListMyNotifications_InvalidUserID(t *testing.T) {
	svc := NewNotificationInboxService(fakeNotificationInboxStore{})
	_, err := svc.ListMyNotifications(context.Background(), "not-a-uuid", "", 0)
	if err == nil {
		t.Fatal("expected an error for invalid user id, got nil")
	}
}

func TestNotificationInboxService_MarkRead_Success(t *testing.T) {
	userID := uuid.New()
	notifID := uuid.New()
	fixedNow := time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC)
	var capturedUser, capturedID pgtype.UUID
	var capturedReadAt pgtype.Timestamptz
	svc := NewNotificationInboxService(fakeNotificationInboxStore{
		capturedMarkUserID: &capturedUser,
		capturedMarkID:     &capturedID,
		capturedMarkReadAt: &capturedReadAt,
	}, WithNotificationInboxClock(func() time.Time { return fixedNow }))

	if err := svc.MarkRead(context.Background(), userID.String(), notifID.String()); err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if uuid.UUID(capturedUser.Bytes) != userID {
		t.Errorf("unexpected captured user id: %v", capturedUser)
	}
	if uuid.UUID(capturedID.Bytes) != notifID {
		t.Errorf("unexpected captured notification id: %v", capturedID)
	}
	if !capturedReadAt.Time.Equal(fixedNow) {
		t.Errorf("expected read_at %v, got %v", fixedNow, capturedReadAt.Time)
	}
}

func TestNotificationInboxService_MarkRead_InvalidNotificationID(t *testing.T) {
	svc := NewNotificationInboxService(fakeNotificationInboxStore{})
	err := svc.MarkRead(context.Background(), uuid.New().String(), "not-a-uuid")
	if !errors.Is(err, ErrInvalidNotificationID) {
		t.Fatalf("expected ErrInvalidNotificationID, got %v", err)
	}
}

func TestNotificationInboxService_MarkRead_InvalidUserID(t *testing.T) {
	svc := NewNotificationInboxService(fakeNotificationInboxStore{})
	err := svc.MarkRead(context.Background(), "not-a-uuid", uuid.New().String())
	if err == nil {
		t.Fatal("expected an error for invalid user id, got nil")
	}
}
