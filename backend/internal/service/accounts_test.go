package service

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

type fakeAccountStore struct {
	user    repository.User
	userErr error

	objectKeys []string
	deleteErr  error

	capturedUserID *pgtype.UUID
	capturedPhone  *string
	deleteCalls    *int
}

func (f fakeAccountStore) GetUserByID(_ context.Context, _ pgtype.UUID) (repository.User, error) {
	return f.user, f.userErr
}

func (f fakeAccountStore) DeleteAccount(_ context.Context, userID pgtype.UUID, phone string) ([]string, error) {
	if f.capturedUserID != nil {
		*f.capturedUserID = userID
	}
	if f.capturedPhone != nil {
		*f.capturedPhone = phone
	}
	if f.deleteCalls != nil {
		*f.deleteCalls++
	}
	return f.objectKeys, f.deleteErr
}

type recordingObjectStore struct {
	deleted []string
	err     error
}

func (r *recordingObjectStore) Put(_ context.Context, key, _ string, _ []byte) (string, error) {
	return "/v1/media/objects/" + key, nil
}

func (r *recordingObjectStore) Delete(_ context.Context, key string) error {
	r.deleted = append(r.deleted, key)
	return r.err
}

func TestAccountsService_Delete_RemovesRowsThenObjects(t *testing.T) {
	userID := uuid.New()
	var capturedID pgtype.UUID
	var capturedPhone string
	objects := &recordingObjectStore{}

	svc := NewAccountsService(fakeAccountStore{
		user:           repository.User{Phone: "+905551112233"},
		objectKeys:     []string{"a.jpg", "b.mp4"},
		capturedUserID: &capturedID,
		capturedPhone:  &capturedPhone,
	}, objects)

	if err := svc.Delete(context.Background(), userID.String()); err != nil {
		t.Fatalf("expected no error, got %v", err)
	}

	if uuid.UUID(capturedID.Bytes) != userID {
		t.Errorf("user id: want %s, got %s", userID, uuid.UUID(capturedID.Bytes))
	}
	// The phone comes from the stored account, never from the caller — it is
	// what lets the otp rows for that number go with the account.
	if capturedPhone != "+905551112233" {
		t.Errorf("phone: want the account's own, got %q", capturedPhone)
	}
	if len(objects.deleted) != 2 || objects.deleted[0] != "a.jpg" || objects.deleted[1] != "b.mp4" {
		t.Errorf("expected both media objects deleted, got %v", objects.deleted)
	}
}

// Deleting an account that is already gone is the state the caller asked
// for, so it succeeds — a retry after a dropped response must not strand a
// client holding credentials for an account that no longer exists.
func TestAccountsService_Delete_AlreadyDeletedSucceeds(t *testing.T) {
	calls := 0
	svc := NewAccountsService(
		fakeAccountStore{userErr: pgx.ErrNoRows, deleteCalls: &calls},
		&recordingObjectStore{},
	)

	if err := svc.Delete(context.Background(), uuid.New().String()); err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if calls != 0 {
		t.Errorf("expected no delete attempt for a missing account, got %d", calls)
	}
}

// Object storage cannot join the database transaction, so a failure there
// leaves an unreferenced object — logged, but not surfaced: the rows naming
// it are already gone, and reporting failure would tell the user their
// account survived when it did not.
func TestAccountsService_Delete_ObjectFailureDoesNotFailDeletion(t *testing.T) {
	objects := &recordingObjectStore{err: errors.New("bucket unreachable")}
	svc := NewAccountsService(fakeAccountStore{objectKeys: []string{"a.jpg"}}, objects)

	if err := svc.Delete(context.Background(), uuid.New().String()); err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(objects.deleted) != 1 {
		t.Errorf("expected the object delete to still be attempted, got %v", objects.deleted)
	}
}

// A database failure must surface: nothing was removed, and the client has
// to keep its session rather than sign out of a live account.
func TestAccountsService_Delete_DatabaseFailureSurfaces(t *testing.T) {
	dbErr := errors.New("deadlock")
	svc := NewAccountsService(fakeAccountStore{deleteErr: dbErr}, &recordingObjectStore{})

	if err := svc.Delete(context.Background(), uuid.New().String()); !errors.Is(err, dbErr) {
		t.Fatalf("expected the database error, got %v", err)
	}
}

func TestAccountsService_Delete_RejectsMalformedUserID(t *testing.T) {
	svc := NewAccountsService(fakeAccountStore{}, &recordingObjectStore{})

	if err := svc.Delete(context.Background(), "not-a-uuid"); err == nil {
		t.Fatal("expected an error for a malformed user id")
	}
}
