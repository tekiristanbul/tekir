package repository_test

import (
	"context"
	"errors"
	"os"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// requires a real, migrated database: run `make migrate-up` against the
// docker-compose postgres first, or let CI's postgres service do it.
// createTestUser (follows_integration_test.go) supplies the real users.id
// foreign key these tests need.

func TestStore_CreateMedia_IdempotencyUniqueIndex(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set, skipping integration test")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer pool.Close()
	store := repository.NewStore(pool)

	userID := createTestUser(t, ctx, store)
	key := pgtype.Text{String: "media-integration-key-" + uuid.NewString(), Valid: true}

	first, err := store.CreateMedia(ctx, repository.CreateMediaParams{
		ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}, ObjectKey: "obj1.jpg", Url: "/v1/media/objects/obj1.jpg",
		ContentType: "image/jpeg", ByteSize: 100, UploadedByUserID: userID, IdempotencyKey: key,
	})
	if err != nil {
		t.Fatalf("first create: %v", err)
	}

	// A retry with the same (user, key) must not create a second row: the
	// on-conflict-do-nothing arbiter means no row comes back at all.
	_, err = store.CreateMedia(ctx, repository.CreateMediaParams{
		ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}, ObjectKey: "obj2.jpg", Url: "/v1/media/objects/obj2.jpg",
		ContentType: "image/jpeg", ByteSize: 200, UploadedByUserID: userID, IdempotencyKey: key,
	})
	if !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("expected pgx.ErrNoRows on the conflicting retry, got %v", err)
	}

	existing, err := store.GetMediaByIdempotencyKey(ctx, repository.GetMediaByIdempotencyKeyParams{
		UploadedByUserID: userID, IdempotencyKey: key,
	})
	if err != nil {
		t.Fatalf("get by idempotency key: %v", err)
	}
	if existing.ID != first.ID {
		t.Errorf("expected the original media row (%v), got %v", first.ID, existing.ID)
	}
	if existing.ObjectKey != "obj1.jpg" {
		t.Errorf("expected the retry to leave the original row untouched, got object_key %q", existing.ObjectKey)
	}
}

func TestStore_CreateMedia_SameKeyDifferentUsersBothSucceed(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set, skipping integration test")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer pool.Close()
	store := repository.NewStore(pool)

	userA := createTestUser(t, ctx, store)
	userB := createTestUser(t, ctx, store)
	key := pgtype.Text{String: "shared-key-" + uuid.NewString(), Valid: true}

	rowA, err := store.CreateMedia(ctx, repository.CreateMediaParams{
		ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}, ObjectKey: "a.jpg", Url: "/v1/media/objects/a.jpg",
		ContentType: "image/jpeg", ByteSize: 1, UploadedByUserID: userA, IdempotencyKey: key,
	})
	if err != nil {
		t.Fatalf("create for user A: %v", err)
	}
	rowB, err := store.CreateMedia(ctx, repository.CreateMediaParams{
		ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}, ObjectKey: "b.jpg", Url: "/v1/media/objects/b.jpg",
		ContentType: "image/jpeg", ByteSize: 1, UploadedByUserID: userB, IdempotencyKey: key,
	})
	if err != nil {
		t.Fatalf("expected the same idempotency key to succeed for a different account, got %v", err)
	}
	if rowA.ID == rowB.ID {
		t.Error("expected two distinct media rows, one per account")
	}
}
