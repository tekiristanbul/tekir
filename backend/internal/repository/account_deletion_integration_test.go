package repository_test

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// Account deletion touches almost every table, in one transaction, in
// foreign-key order. These run it against a real database with an account
// that actually owns things — the only way to prove the order holds and
// that nothing account-linked survives.

func TestStore_DeleteAccount_RemovesTheAccountAndItsContent(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	owner := createTestUser(t, ctx, store)
	phone := userPhone(t, ctx, store, owner)

	created, err := store.CreateCatWithMedia(ctx, newCreateCatWithMediaParams(owner, 41.0812, 29.0583, pgtype.Text{}))
	if err != nil {
		t.Fatalf("create cat: %v", err)
	}
	catID := created.Cat.ID
	mediaID := created.Media.ID

	// Someone else follows the cat and blocks the owner: both rows hang off
	// content that is about to disappear.
	follower := createTestUser(t, ctx, store)
	if err := store.CreateFollow(ctx, repository.CreateFollowParams{CatID: catID, UserID: follower}); err != nil {
		t.Fatalf("create follow: %v", err)
	}
	if err := store.CreateBlock(ctx, repository.CreateBlockParams{BlockerUserID: follower, BlockedUserID: owner}); err != nil {
		t.Fatalf("create block: %v", err)
	}

	objectKeys, err := store.DeleteAccount(ctx, owner, phone)
	if err != nil {
		t.Fatalf("delete account: %v", err)
	}

	// The object keys have to come back: once the media rows are gone there
	// is nothing left to derive them from, and an orphaned object is a
	// privacy problem rather than just wasted storage.
	if len(objectKeys) == 0 {
		t.Error("expected the deleted media's object keys to come back for cleanup")
	}

	if _, err := store.GetUserByID(ctx, owner); err != pgx.ErrNoRows {
		t.Errorf("user: expected no rows, got %v", err)
	}
	if _, err := store.GetCatByID(ctx, repository.GetCatByIDParams{ID: catID}); err != pgx.ErrNoRows {
		t.Errorf("cat: expected no rows, got %v", err)
	}
	if _, err := store.GetMediaByID(ctx, mediaID); err != pgx.ErrNoRows {
		t.Errorf("media: expected no rows, got %v", err)
	}

	// The follower survives untouched, but their follow and their block of
	// the deleted account are gone with the content they pointed at.
	if _, err := store.GetUserByID(ctx, follower); err != nil {
		t.Errorf("follower account must survive: %v", err)
	}
	followed, err := store.ListFollowedCats(ctx, follower)
	if err != nil {
		t.Fatalf("list followed: %v", err)
	}
	if len(followed) != 0 {
		t.Errorf("expected the follow to be gone, got %d rows", len(followed))
	}
	blocks, err := store.ListBlockedAccounts(ctx, follower)
	if err != nil {
		t.Fatalf("list blocked: %v", err)
	}
	if len(blocks) != 0 {
		t.Errorf("expected the block of the deleted account to be gone, got %d rows", len(blocks))
	}
}

// Retry-safety is what lets the client clear its session only after a
// confirmed success: a second call after a dropped response must not fail.
func TestStore_DeleteAccount_IsIdempotent(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	owner := createTestUser(t, ctx, store)
	phone := userPhone(t, ctx, store, owner)
	if _, err := store.CreateCatWithMedia(ctx, newCreateCatWithMediaParams(owner, 41.0812, 29.0583, pgtype.Text{})); err != nil {
		t.Fatalf("create cat: %v", err)
	}

	for i := 0; i < 2; i++ {
		if _, err := store.DeleteAccount(ctx, owner, phone); err != nil {
			t.Fatalf("delete account (attempt %d): %v", i+1, err)
		}
	}
}

// A cat someone else owns keeps existing when the deleted account merely
// contributed to it — only its cover, if it was this account's photo, is
// cleared. Losing another owner's cat to an unrelated deletion would be a
// far worse failure than losing a cover image.
func TestStore_DeleteAccount_LeavesAnotherOwnersCatInPlace(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	otherOwner := createTestUser(t, ctx, store)
	deleted := createTestUser(t, ctx, store)
	phone := userPhone(t, ctx, store, deleted)

	created, err := store.CreateCatWithMedia(ctx, newCreateCatWithMediaParams(otherOwner, 41.0813, 29.0584, pgtype.Text{}))
	if err != nil {
		t.Fatalf("create cat: %v", err)
	}

	if _, err := store.DeleteAccount(ctx, deleted, phone); err != nil {
		t.Fatalf("delete account: %v", err)
	}

	if _, err := store.GetCatByID(ctx, repository.GetCatByIDParams{ID: created.Cat.ID}); err != nil {
		t.Errorf("another owner's cat must survive: %v", err)
	}
}

func userPhone(t *testing.T, ctx context.Context, store *repository.Store, id pgtype.UUID) string {
	t.Helper()
	user, err := store.GetUserByID(ctx, id)
	if err != nil {
		t.Fatalf("get user: %v", err)
	}
	return user.Phone
}
