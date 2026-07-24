package repository_test

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// requires a real, migrated database: run `make migrate-up` against the
// docker-compose postgres first, or let CI's postgres service do it.
func TestStore_CreateDevice_AndLookupByHash(t *testing.T) {
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

	rawToken := "integration-test-token-" + uuid.New().String()
	hash := service.HashDeviceToken(rawToken)
	id := pgtype.UUID{Bytes: uuid.New(), Valid: true}

	row, err := store.CreateDevice(ctx, repository.CreateDeviceParams{
		ID:        id,
		TokenHash: hash,
		PushToken: pgtype.Text{},
		Platform:  "web",
	})
	if err != nil {
		t.Fatalf("create device: %v", err)
	}
	if row.ID != id {
		t.Errorf("returned id mismatch: %v vs %v", row.ID, id)
	}
	if !row.CreatedAt.Valid {
		t.Error("created_at must be set")
	}

	// lookup by the hash of the raw token.
	got, err := store.GetDeviceByTokenHash(ctx, hash)
	if err != nil {
		t.Fatalf("lookup by hash: %v", err)
	}
	if got.ID != id {
		t.Errorf("expected id %v, got %v", id, got.ID)
	}
	if got.RevokedAt.Valid {
		t.Error("fresh device must not be revoked")
	}
}

func TestStore_GetDeviceByTokenHash_UnknownHash(t *testing.T) {
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

	_, err = store.GetDeviceByTokenHash(ctx, "this-hash-does-not-exist")
	if err == nil || !isNoRows(err) {
		t.Errorf("expected pgx.ErrNoRows for unknown hash, got %v", err)
	}
}

func TestStore_CreateDevice_RevokedToken_Rejected(t *testing.T) {
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

	rawToken := "revoked-token-" + uuid.New().String()
	hash := service.HashDeviceToken(rawToken)
	id := pgtype.UUID{Bytes: uuid.New(), Valid: true}

	if _, err = store.CreateDevice(ctx, repository.CreateDeviceParams{
		ID:        id,
		TokenHash: hash,
		PushToken: pgtype.Text{},
		Platform:  "ios",
	}); err != nil {
		t.Fatalf("create device: %v", err)
	}

	// manually revoke via sql.
	_, err = pool.Exec(ctx,
		`update devices set revoked_at = $1 where id = $2`,
		pgtype.Timestamptz{Time: time.Now(), Valid: true},
		id,
	)
	if err != nil {
		t.Fatalf("revoke: %v", err)
	}

	got, err := store.GetDeviceByTokenHash(ctx, hash)
	if err != nil {
		t.Fatalf("lookup revoked device: %v", err)
	}
	if !got.RevokedAt.Valid {
		t.Error("revoked_at must be set after revocation")
	}

	// the service layer (not the query) is responsible for rejecting revoked devices.
	svc := service.NewDevicesService(store)
	_, err = svc.ResolveToken(ctx, rawToken)
	if err == nil {
		t.Fatal("expected error for revoked token, got nil")
	}
}

func TestStore_CreateDevice_UniqueHashConstraint(t *testing.T) {
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

	hash := service.HashDeviceToken("duplicate-hash-" + uuid.New().String())

	if _, err = store.CreateDevice(ctx, repository.CreateDeviceParams{
		ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
		TokenHash: hash,
		Platform:  "android",
	}); err != nil {
		t.Fatalf("first create: %v", err)
	}

	_, err = store.CreateDevice(ctx, repository.CreateDeviceParams{
		ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
		TokenHash: hash,
		Platform:  "android",
	})
	if err == nil {
		t.Fatal("expected unique constraint violation on duplicate token_hash, got nil")
	}
}

func isNoRows(err error) bool {
	return err != nil && (err == pgx.ErrNoRows || err.Error() == pgx.ErrNoRows.Error())
}
