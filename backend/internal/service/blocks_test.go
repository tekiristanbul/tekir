package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

type fakeBlocksStore struct {
	userRow repository.User
	userErr error

	createErr error
	deleteErr error

	listRows []repository.ListBlockedAccountsRow
	listErr  error

	// captured, if non-nil, records the arg the last CreateBlock/DeleteBlock
	// call received — the only way to assert the blocker is taken from the
	// session rather than anywhere else.
	capturedCreate *repository.CreateBlockParams
	capturedDelete *repository.DeleteBlockParams
}

func (f fakeBlocksStore) CreateBlock(_ context.Context, arg repository.CreateBlockParams) error {
	if f.capturedCreate != nil {
		*f.capturedCreate = arg
	}
	return f.createErr
}

func (f fakeBlocksStore) DeleteBlock(_ context.Context, arg repository.DeleteBlockParams) error {
	if f.capturedDelete != nil {
		*f.capturedDelete = arg
	}
	return f.deleteErr
}

func (f fakeBlocksStore) ListBlockedAccounts(_ context.Context, _ pgtype.UUID) ([]repository.ListBlockedAccountsRow, error) {
	return f.listRows, f.listErr
}

func (f fakeBlocksStore) GetUserByID(_ context.Context, _ pgtype.UUID) (repository.User, error) {
	return f.userRow, f.userErr
}

func TestBlocksService_Block_RecordsSessionBlocker(t *testing.T) {
	blocker := uuid.New()
	blocked := uuid.New()
	var captured repository.CreateBlockParams

	svc := NewBlocksService(fakeBlocksStore{capturedCreate: &captured})
	if err := svc.Block(context.Background(), blocker.String(), blocked.String()); err != nil {
		t.Fatalf("expected no error, got %v", err)
	}

	if uuid.UUID(captured.BlockerUserID.Bytes) != blocker {
		t.Fatalf("blocker: want %s, got %s", blocker, uuid.UUID(captured.BlockerUserID.Bytes))
	}
	if uuid.UUID(captured.BlockedUserID.Bytes) != blocked {
		t.Fatalf("blocked: want %s, got %s", blocked, uuid.UUID(captured.BlockedUserID.Bytes))
	}
}

func TestBlocksService_Block_RejectsSelf(t *testing.T) {
	self := uuid.New().String()
	svc := NewBlocksService(fakeBlocksStore{})

	if err := svc.Block(context.Background(), self, self); !errors.Is(err, ErrCannotBlockSelf) {
		t.Fatalf("expected ErrCannotBlockSelf, got %v", err)
	}
}

func TestBlocksService_Block_RejectsMalformedTarget(t *testing.T) {
	svc := NewBlocksService(fakeBlocksStore{})

	if err := svc.Block(context.Background(), uuid.New().String(), "not-a-uuid"); !errors.Is(err, ErrInvalidBlockedUserID) {
		t.Fatalf("expected ErrInvalidBlockedUserID, got %v", err)
	}
}

func TestBlocksService_Block_UnknownTargetIsNotFound(t *testing.T) {
	svc := NewBlocksService(fakeBlocksStore{userErr: pgx.ErrNoRows})

	err := svc.Block(context.Background(), uuid.New().String(), uuid.New().String())
	if !errors.Is(err, ErrBlockedUserNotFound) {
		t.Fatalf("expected ErrBlockedUserNotFound, got %v", err)
	}
}

// Blocking an account that is already blocked is a no-op at the database
// level (on conflict do nothing), so the service must simply report success
// — a second tap on "engelle" is not an error.
func TestBlocksService_Block_IsIdempotent(t *testing.T) {
	svc := NewBlocksService(fakeBlocksStore{})
	blocker, blocked := uuid.New().String(), uuid.New().String()

	for i := 0; i < 2; i++ {
		if err := svc.Block(context.Background(), blocker, blocked); err != nil {
			t.Fatalf("attempt %d: expected no error, got %v", i+1, err)
		}
	}
}

// Unblocking something that was never blocked leaves the caller in exactly
// the state they asked for, so it succeeds too.
func TestBlocksService_Unblock_IsIdempotent(t *testing.T) {
	svc := NewBlocksService(fakeBlocksStore{})

	if err := svc.Unblock(context.Background(), uuid.New().String(), uuid.New().String()); err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
}

func TestBlocksService_Unblock_RejectsSelf(t *testing.T) {
	self := uuid.New().String()
	svc := NewBlocksService(fakeBlocksStore{})

	if err := svc.Unblock(context.Background(), self, self); !errors.Is(err, ErrCannotBlockSelf) {
		t.Fatalf("expected ErrCannotBlockSelf, got %v", err)
	}
}

func TestBlocksService_ListBlocked(t *testing.T) {
	blocked := uuid.New()
	created := time.Date(2026, 8, 14, 10, 0, 0, 0, time.UTC)
	svc := NewBlocksService(fakeBlocksStore{listRows: []repository.ListBlockedAccountsRow{{
		BlockedUserID: pgtype.UUID{Bytes: blocked, Valid: true},
		DisplayName:   pgtype.Text{String: "Komşu", Valid: true},
		CreatedAt:     pgtype.Timestamptz{Time: created, Valid: true},
	}}})

	list, err := svc.ListBlocked(context.Background(), uuid.New().String())
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(list) != 1 {
		t.Fatalf("expected 1 entry, got %d", len(list))
	}
	if list[0].UserID != blocked.String() {
		t.Fatalf("user id: want %s, got %s", blocked, list[0].UserID)
	}
	if list[0].DisplayName == nil || *list[0].DisplayName != "Komşu" {
		t.Fatalf("display name: want Komşu, got %v", list[0].DisplayName)
	}
	if !list[0].CreatedAt.Equal(created) {
		t.Fatalf("created at: want %s, got %s", created, list[0].CreatedAt)
	}
}

// An account that never set a display name still appears in the list — the
// screen shows a fallback, it does not hide the entry (which would leave the
// user unable to unblock).
func TestBlocksService_ListBlocked_KeepsEntryWithoutDisplayName(t *testing.T) {
	svc := NewBlocksService(fakeBlocksStore{listRows: []repository.ListBlockedAccountsRow{{
		BlockedUserID: pgtype.UUID{Bytes: uuid.New(), Valid: true},
		CreatedAt:     pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}}})

	list, err := svc.ListBlocked(context.Background(), uuid.New().String())
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(list) != 1 || list[0].DisplayName != nil {
		t.Fatalf("expected one entry with a nil display name, got %+v", list)
	}
}

// The block predicate itself lives in sql (see db/queries/cats.sql), so the
// service's job is narrower and testable here: pass the caller down as the
// viewer on every read that can return someone else's cat, and pass nothing
// for a guest. A regression here silently disables blocking on that surface.
func TestCatsService_ThreadsViewerIntoReads(t *testing.T) {
	caller := uuid.New()

	t.Run("map read", func(t *testing.T) {
		var captured repository.ListCatsInBoundsParams
		svc := NewCatsService(fakeCatsLister{capturedBounds: &captured})
		if _, err := svc.ListNearby(context.Background(), Bounds{MinLat: 40, MinLng: 28, MaxLat: 41, MaxLng: 29}, caller.String()); err != nil {
			t.Fatalf("expected no error, got %v", err)
		}
		if !captured.ViewerUserID.Valid || uuid.UUID(captured.ViewerUserID.Bytes) != caller {
			t.Fatalf("viewer: want %s, got %+v", caller, captured.ViewerUserID)
		}
	})

	t.Run("guest map read passes no viewer", func(t *testing.T) {
		var captured repository.ListCatsInBoundsParams
		svc := NewCatsService(fakeCatsLister{capturedBounds: &captured})
		if _, err := svc.ListNearby(context.Background(), Bounds{MinLat: 40, MinLng: 28, MaxLat: 41, MaxLng: 29}, ""); err != nil {
			t.Fatalf("expected no error, got %v", err)
		}
		if captured.ViewerUserID.Valid {
			t.Fatalf("guest read must carry no viewer, got %+v", captured.ViewerUserID)
		}
	})

	t.Run("media archive gate", func(t *testing.T) {
		var captured repository.CatExistsParams
		svc := NewCatsService(fakeCatsLister{exists: true, capturedCatExists: &captured})
		if _, err := svc.ListCatMedia(context.Background(), uuid.New().String(), caller.String()); err != nil {
			t.Fatalf("expected no error, got %v", err)
		}
		if !captured.ViewerUserID.Valid || uuid.UUID(captured.ViewerUserID.Bytes) != caller {
			t.Fatalf("viewer: want %s, got %+v", caller, captured.ViewerUserID)
		}
	})
}
