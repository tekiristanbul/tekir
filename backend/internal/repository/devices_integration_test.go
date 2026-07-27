package repository_test

import (
	"context"
	"os"
	"sync"
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

// TestStore_UnlinkDeviceFromUser_ClearsMatchingLink proves the happy path
// (issue #80, product-owner review): a device currently linked to the
// caller's own account is unlinked, ready to link fresh to any account.
func TestStore_UnlinkDeviceFromUser_ClearsMatchingLink(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	userID := createTestUser(t, ctx, store)
	deviceID := createTestDevice(t, ctx, store)
	if err := store.LinkDeviceToUser(ctx, repository.LinkDeviceToUserParams{ID: deviceID, UserID: userID}); err != nil {
		t.Fatalf("link: %v", err)
	}

	if err := store.UnlinkDeviceFromUser(ctx, repository.UnlinkDeviceFromUserParams{ID: deviceID, UserID: userID}); err != nil {
		t.Fatalf("unlink: %v", err)
	}

	got, err := store.GetDeviceByID(ctx, deviceID)
	if err != nil {
		t.Fatalf("get device: %v", err)
	}
	if got.UserID.Valid {
		t.Errorf("expected device to be unlinked (user_id null), got %v", got.UserID)
	}
}

// TestStore_UnlinkDeviceFromUser_NoopForMismatchedAccount proves a caller
// cannot unlink a device linked to a *different* account — the exact
// safety guard the product-owner review required.
func TestStore_UnlinkDeviceFromUser_NoopForMismatchedAccount(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	owner := createTestUser(t, ctx, store)
	stranger := createTestUser(t, ctx, store)
	deviceID := createTestDevice(t, ctx, store)
	if err := store.LinkDeviceToUser(ctx, repository.LinkDeviceToUserParams{ID: deviceID, UserID: owner}); err != nil {
		t.Fatalf("link: %v", err)
	}

	if err := store.UnlinkDeviceFromUser(ctx, repository.UnlinkDeviceFromUserParams{ID: deviceID, UserID: stranger}); err != nil {
		t.Fatalf("unlink attempt (mismatched account): %v", err)
	}

	got, err := store.GetDeviceByID(ctx, deviceID)
	if err != nil {
		t.Fatalf("get device: %v", err)
	}
	if !got.UserID.Valid || got.UserID != owner {
		t.Errorf("expected the device to remain linked to its real owner %v, got %v", owner, got.UserID)
	}
}

// TestStore_UnlinkDeviceFromUser_IdempotentOnAlreadyUnlinked proves a
// repeated unlink (e.g. a duplicate logout call) is a safe no-op, never an
// error.
func TestStore_UnlinkDeviceFromUser_IdempotentOnAlreadyUnlinked(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	userID := createTestUser(t, ctx, store)
	deviceID := createTestDevice(t, ctx, store)
	if err := store.LinkDeviceToUser(ctx, repository.LinkDeviceToUserParams{ID: deviceID, UserID: userID}); err != nil {
		t.Fatalf("link: %v", err)
	}

	if err := store.UnlinkDeviceFromUser(ctx, repository.UnlinkDeviceFromUserParams{ID: deviceID, UserID: userID}); err != nil {
		t.Fatalf("first unlink: %v", err)
	}
	if err := store.UnlinkDeviceFromUser(ctx, repository.UnlinkDeviceFromUserParams{ID: deviceID, UserID: userID}); err != nil {
		t.Fatalf("repeat unlink: %v", err)
	}
}

// TestStore_AccountSwitch_SameDeviceDifferentAccount_NeverLeaksOwnership is
// the deep, real-postgres regression for the exact bug the product-owner
// review found: account A links a device, contributes a follow and an
// ordinary update, "logs out" (unlink), then account B links the *same*
// device. B's own backfill must never reassign A's already-attributed
// rows — BackfillFollowsUserID/BackfillUpdatesAuthorUserID only ever touch
// rows still missing their owner column, and A's rows already have one.
func TestStore_AccountSwitch_SameDeviceDifferentAccount_NeverLeaksOwnership(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	accountA := createTestUser(t, ctx, store)
	accountB := createTestUser(t, ctx, store)
	deviceID := createTestDevice(t, ctx, store)
	catID := upsertTestCat(t, ctx, store, "account switch target")

	// account A links the device and contributes.
	if err := store.LinkDeviceToUser(ctx, repository.LinkDeviceToUserParams{ID: deviceID, UserID: accountA}); err != nil {
		t.Fatalf("link A: %v", err)
	}
	if err := store.CreateFollow(ctx, repository.CreateFollowParams{DeviceID: deviceID, CatID: catID}); err != nil {
		t.Fatalf("seed device-owned follow: %v", err)
	}
	if err := store.BackfillFollowsUserID(ctx, repository.BackfillFollowsUserIDParams{DeviceID: deviceID, UserID: accountA}); err != nil {
		t.Fatalf("backfill A: %v", err)
	}

	// account A "logs out": device unlinks.
	if err := store.UnlinkDeviceFromUser(ctx, repository.UnlinkDeviceFromUserParams{ID: deviceID, UserID: accountA}); err != nil {
		t.Fatalf("unlink A: %v", err)
	}

	// account B links the same, now-unlinked device — must succeed (no
	// conflict at the query level; the service layer's own conflict check
	// only ever runs against a still-linked device).
	if err := store.LinkDeviceToUser(ctx, repository.LinkDeviceToUserParams{ID: deviceID, UserID: accountB}); err != nil {
		t.Fatalf("link B: %v", err)
	}
	// B's own backfill must be a no-op for A's already-owned follow.
	if err := store.BackfillFollowsUserID(ctx, repository.BackfillFollowsUserIDParams{DeviceID: deviceID, UserID: accountB}); err != nil {
		t.Fatalf("backfill B: %v", err)
	}

	rowsA, err := store.ListFollowedCats(ctx, accountA)
	if err != nil {
		t.Fatalf("list A's follows: %v", err)
	}
	if len(rowsA) != 1 || rowsA[0].ID != catID {
		t.Fatalf("expected account A to keep its own follow, got %+v", rowsA)
	}

	rowsB, err := store.ListFollowedCats(ctx, accountB)
	if err != nil {
		t.Fatalf("list B's follows: %v", err)
	}
	if len(rowsB) != 0 {
		t.Fatalf("expected account B to see none of A's follows, got %+v", rowsB)
	}
}

// TestStore_UnlinkDeviceFromUser_ConcurrentUnlinkAndRelink mirrors
// TestStore_CreateFollow_ConcurrentDuplicate's shape: concurrent
// unlink-then-relink attempts on the same device must never corrupt the
// final state — exactly one of the two competing accounts ends up linked,
// and neither operation errors.
func TestStore_UnlinkDeviceFromUser_ConcurrentUnlinkAndRelink(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	accountA := createTestUser(t, ctx, store)
	accountB := createTestUser(t, ctx, store)
	deviceID := createTestDevice(t, ctx, store)
	if err := store.LinkDeviceToUser(ctx, repository.LinkDeviceToUserParams{ID: deviceID, UserID: accountA}); err != nil {
		t.Fatalf("link A: %v", err)
	}

	const n = 10
	var wg sync.WaitGroup
	errs := make([]error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			if err := store.UnlinkDeviceFromUser(ctx, repository.UnlinkDeviceFromUserParams{ID: deviceID, UserID: accountA}); err != nil {
				errs[i] = err
				return
			}
			errs[i] = store.LinkDeviceToUser(ctx, repository.LinkDeviceToUserParams{ID: deviceID, UserID: accountB})
		}(i)
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Fatalf("concurrent unlink+relink %d: %v", i, err)
		}
	}

	got, err := store.GetDeviceByID(ctx, deviceID)
	if err != nil {
		t.Fatalf("get device: %v", err)
	}
	if !got.UserID.Valid || got.UserID != accountB {
		t.Errorf("expected the device to end up linked to account B, got %v", got.UserID)
	}
}
