package repository_test

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

// revokeTestDevice sets revoked_at directly (no RevokeDevice query exists
// yet), mirroring rawPool's use elsewhere in this package for setup/assertions
// the generated query set doesn't cover.
func revokeTestDevice(t *testing.T, ctx context.Context, deviceID pgtype.UUID) {
	t.Helper()
	pool := rawPool(t)
	if _, err := pool.Exec(ctx, "update devices set revoked_at = now() where id = $1", deviceID); err != nil {
		t.Fatalf("revoke device: %v", err)
	}
}

// drainNotificationOutbox marks every currently-unprocessed outbox row
// processed, without resolving any recipients — a test-only sweep so a
// claim-ordering/limit assertion in one test isn't at the mercy of
// leftover unprocessed rows other tests' CreateOrdinaryUpdate/
// CreateNeedsHelpUpdate calls enqueued into the same shared database. Real
// dispatch (NotificationService.DispatchPending) never does this blind a
// drain — this is purely to give a test a clean, deterministic starting queue.
func drainNotificationOutbox(t *testing.T, ctx context.Context, store *repository.Store) {
	t.Helper()
	for {
		rows, err := store.ClaimNotificationOutboxBatch(ctx, 500)
		if err != nil {
			t.Fatalf("drain outbox claim: %v", err)
		}
		if len(rows) == 0 {
			return
		}
		for _, r := range rows {
			if err := store.MarkNotificationOutboxProcessed(ctx, repository.MarkNotificationOutboxProcessedParams{
				ID:          r.ID,
				ProcessedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
			}); err != nil {
				t.Fatalf("drain outbox mark processed: %v", err)
			}
		}
	}
}

func TestStore_CreateNeedsHelpUpdate_Success(t *testing.T) {
	store := newTestStore(t)
	pool := rawPool(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "needs-help write path recipient")
	device := createTestDevice(t, ctx, store)
	userID := createTestUser(t, ctx, store)

	createdAt := time.Date(2026, 3, 1, 10, 0, 0, 0, time.UTC)
	updateID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	row, err := store.CreateNeedsHelpUpdate(ctx, repository.CreateNeedsHelpUpdateParams{
		ID:                 updateID,
		CatID:              catID,
		AuthorDeviceID:     device,
		AuthorUserID:       userID,
		Comment:            pgtype.Text{String: "sağ arka ayağını basamıyor", Valid: true},
		CreatedAt:          pgtype.Timestamptz{Time: createdAt, Valid: true},
		NeedsHelpCategory:  "injured_or_sick",
		NeedsHelpExpiresAt: pgtype.Timestamptz{Time: createdAt.Add(72 * time.Hour), Valid: true},
	})
	if err != nil {
		t.Fatalf("create needs-help update: %v", err)
	}
	if row.ID != updateID {
		t.Errorf("expected row id %v, got %v", updateID, row.ID)
	}

	var kind string
	var category pgtype.Text
	var expiresAt pgtype.Timestamptz
	if err := pool.QueryRow(ctx, "select kind, needs_help_category, needs_help_expires_at from updates where id = $1", row.ID).
		Scan(&kind, &category, &expiresAt); err != nil {
		t.Fatalf("query update row: %v", err)
	}
	if kind != "needs_help" {
		t.Errorf("expected kind needs_help, got %q", kind)
	}
	if category.String != "injured_or_sick" {
		t.Errorf("expected category injured_or_sick, got %q", category.String)
	}
	if !expiresAt.Time.Equal(createdAt.Add(72 * time.Hour)) {
		t.Errorf("expected expires_at %v, got %v", createdAt.Add(72*time.Hour), expiresAt.Time)
	}

	cat, err := store.GetCatByID(ctx, catID)
	if err != nil {
		t.Fatalf("get cat: %v", err)
	}
	if !cat.LastUpdateAt.Valid || !cat.LastUpdateAt.Time.Equal(createdAt) {
		t.Errorf("expected last_update_at %v, got %v", createdAt, cat.LastUpdateAt.Time)
	}

	var outboxCount int
	if err := pool.QueryRow(ctx, "select count(*) from notification_outbox where update_id = $1", row.ID).Scan(&outboxCount); err != nil {
		t.Fatalf("count outbox rows: %v", err)
	}
	if outboxCount != 1 {
		t.Errorf("expected exactly 1 notification_outbox row, got %d", outboxCount)
	}
}

// TestStore_CreateNeedsHelpUpdate_InvalidCategoryRejected proves
// updates_kind_fields_ck/the needs_help_category check constraint (migration
// 00006) rejects an unrecognized category at the database level even though
// CatsService.CreateNeedsHelpUpdate already validates against the same
// closed vocabulary before ever reaching this call — belt and suspenders,
// like TestStore_CreateUpdate_InvalidNeedsHelpCategoryRejected already
// proves for the lower-level CreateUpdate query this method wraps.
func TestStore_CreateNeedsHelpUpdate_InvalidCategoryRejected(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "invalid category recipient")
	userID := createTestUser(t, ctx, store)

	createdAt := time.Date(2026, 3, 1, 10, 0, 0, 0, time.UTC)
	_, err := store.CreateNeedsHelpUpdate(ctx, repository.CreateNeedsHelpUpdateParams{
		ID:                 pgtype.UUID{Bytes: uuid.New(), Valid: true},
		CatID:              catID,
		AuthorUserID:       userID,
		CreatedAt:          pgtype.Timestamptz{Time: createdAt, Valid: true},
		NeedsHelpCategory:  "not_a_real_category",
		NeedsHelpExpiresAt: pgtype.Timestamptz{Time: createdAt.Add(72 * time.Hour), Valid: true},
	})
	if !isCheckViolation(err) {
		t.Fatalf("expected check violation, got %v", err)
	}
}

func TestStore_ListNeedsHelpRecipientDevices_ExcludesAuthorRevokedAndNonFollowers(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "recipient resolution cat")

	author := createTestUser(t, ctx, store)
	authorDevice := createTestDevice(t, ctx, store)
	if err := store.LinkDeviceToUser(ctx, repository.LinkDeviceToUserParams{ID: authorDevice, UserID: author}); err != nil {
		t.Fatalf("link author device: %v", err)
	}
	if err := store.CreateFollow(ctx, repository.CreateFollowParams{UserID: author, CatID: catID}); err != nil {
		t.Fatalf("author follow: %v", err)
	}

	follower := createTestUser(t, ctx, store)
	followerDevice := createTestDevice(t, ctx, store)
	if err := store.LinkDeviceToUser(ctx, repository.LinkDeviceToUserParams{ID: followerDevice, UserID: follower}); err != nil {
		t.Fatalf("link follower device: %v", err)
	}
	if err := store.CreateFollow(ctx, repository.CreateFollowParams{UserID: follower, CatID: catID}); err != nil {
		t.Fatalf("follower follow: %v", err)
	}

	revokedFollower := createTestUser(t, ctx, store)
	revokedDevice := createTestDevice(t, ctx, store)
	if err := store.LinkDeviceToUser(ctx, repository.LinkDeviceToUserParams{ID: revokedDevice, UserID: revokedFollower}); err != nil {
		t.Fatalf("link revoked follower device: %v", err)
	}
	if err := store.CreateFollow(ctx, repository.CreateFollowParams{UserID: revokedFollower, CatID: catID}); err != nil {
		t.Fatalf("revoked follower follow: %v", err)
	}
	revokeTestDevice(t, ctx, revokedDevice)

	// a non-follower with a perfectly good device must never appear.
	nonFollower := createTestUser(t, ctx, store)
	nonFollowerDevice := createTestDevice(t, ctx, store)
	if err := store.LinkDeviceToUser(ctx, repository.LinkDeviceToUserParams{ID: nonFollowerDevice, UserID: nonFollower}); err != nil {
		t.Fatalf("link non-follower device: %v", err)
	}

	devices, err := store.ListNeedsHelpRecipientDevices(ctx, repository.ListNeedsHelpRecipientDevicesParams{
		CatID:        catID,
		AuthorUserID: author,
	})
	if err != nil {
		t.Fatalf("list recipient devices: %v", err)
	}
	if len(devices) != 1 || devices[0].DeviceID != followerDevice {
		t.Fatalf("expected exactly [followerDevice], got %v", devices)
	}
}

func TestStore_ListNeedsHelpRecipientDevices_MultipleDevicesPerFollower(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "multi-device follower cat")
	author := createTestUser(t, ctx, store)

	follower := createTestUser(t, ctx, store)
	deviceA := createTestDevice(t, ctx, store)
	deviceB := createTestDevice(t, ctx, store)
	for _, d := range []pgtype.UUID{deviceA, deviceB} {
		if err := store.LinkDeviceToUser(ctx, repository.LinkDeviceToUserParams{ID: d, UserID: follower}); err != nil {
			t.Fatalf("link device: %v", err)
		}
	}
	if err := store.CreateFollow(ctx, repository.CreateFollowParams{UserID: follower, CatID: catID}); err != nil {
		t.Fatalf("follow: %v", err)
	}

	devices, err := store.ListNeedsHelpRecipientDevices(ctx, repository.ListNeedsHelpRecipientDevicesParams{
		CatID:        catID,
		AuthorUserID: author,
	})
	if err != nil {
		t.Fatalf("list recipient devices: %v", err)
	}
	if len(devices) != 2 {
		t.Fatalf("expected 2 devices, got %d: %v", len(devices), devices)
	}
}

func TestStore_ClaimNotificationOutboxBatch_CarriesKindAuthorAndCategory(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	drainNotificationOutbox(t, ctx, store)

	catID := upsertTestCat(t, ctx, store, "claim batch cat")
	author := createTestUser(t, ctx, store)

	needsHelpID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	createdAt := time.Date(2026, 3, 5, 8, 0, 0, 0, time.UTC)
	if _, err := store.CreateNeedsHelpUpdate(ctx, repository.CreateNeedsHelpUpdateParams{
		ID:                 needsHelpID,
		CatID:              catID,
		AuthorUserID:       author,
		CreatedAt:          pgtype.Timestamptz{Time: createdAt, Valid: true},
		NeedsHelpCategory:  "trapped",
		NeedsHelpExpiresAt: pgtype.Timestamptz{Time: createdAt.Add(72 * time.Hour), Valid: true},
	}); err != nil {
		t.Fatalf("create needs-help update: %v", err)
	}

	ordinaryID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.CreateOrdinaryUpdate(ctx, repository.CreateOrdinaryUpdateParams{
		ID:           ordinaryID,
		CatID:        catID,
		AuthorUserID: author,
		CreatedAt:    pgtype.Timestamptz{Time: createdAt.Add(time.Minute), Valid: true},
		Statuses:     []string{"seen"},
	}); err != nil {
		t.Fatalf("create ordinary update: %v", err)
	}

	rows, err := store.ClaimNotificationOutboxBatch(ctx, 10)
	if err != nil {
		t.Fatalf("claim batch: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("expected 2 claimed rows, got %d", len(rows))
	}

	byUpdate := map[pgtype.UUID]repository.ClaimNotificationOutboxBatchRow{}
	for _, r := range rows {
		byUpdate[r.UpdateID] = r
	}

	nh, ok := byUpdate[needsHelpID]
	if !ok {
		t.Fatalf("expected needs-help row claimed")
	}
	if nh.Kind != "needs_help" || nh.NeedsHelpCategory.String != "trapped" || nh.AuthorUserID != author {
		t.Errorf("unexpected needs-help claim row: %+v", nh)
	}

	ord, ok := byUpdate[ordinaryID]
	if !ok {
		t.Fatalf("expected ordinary row claimed")
	}
	if ord.Kind != "ordinary" || ord.NeedsHelpCategory.Valid {
		t.Errorf("unexpected ordinary claim row: %+v", ord)
	}
}

func TestStore_MarkNotificationOutboxProcessed_ExcludesFromFutureClaims(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	drainNotificationOutbox(t, ctx, store)

	catID := upsertTestCat(t, ctx, store, "mark processed cat")
	author := createTestUser(t, ctx, store)

	updateID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.CreateOrdinaryUpdate(ctx, repository.CreateOrdinaryUpdateParams{
		ID:           updateID,
		CatID:        catID,
		AuthorUserID: author,
		CreatedAt:    pgtype.Timestamptz{Time: time.Now(), Valid: true},
		Statuses:     []string{"seen"},
	}); err != nil {
		t.Fatalf("create ordinary update: %v", err)
	}

	rows, err := store.ClaimNotificationOutboxBatch(ctx, 10)
	if err != nil {
		t.Fatalf("claim: %v", err)
	}
	var claimedID pgtype.UUID
	for _, r := range rows {
		if r.UpdateID == updateID {
			claimedID = r.ID
		}
	}
	if !claimedID.Valid {
		t.Fatalf("expected to claim the row just enqueued")
	}

	if err := store.MarkNotificationOutboxProcessed(ctx, repository.MarkNotificationOutboxProcessedParams{
		ID:          claimedID,
		ProcessedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}); err != nil {
		t.Fatalf("mark processed: %v", err)
	}

	again, err := store.ClaimNotificationOutboxBatch(ctx, 10)
	if err != nil {
		t.Fatalf("claim again: %v", err)
	}
	for _, r := range again {
		if r.UpdateID == updateID {
			t.Fatalf("expected processed row to be excluded from a later claim")
		}
	}
}

func TestStore_ClaimNotificationOutboxBatch_SkipsRowsLockedByAnotherTransaction(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	drainNotificationOutbox(t, ctx, store)

	catID := upsertTestCat(t, ctx, store, "skip locked cat")
	author := createTestUser(t, ctx, store)
	updateID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.CreateOrdinaryUpdate(ctx, repository.CreateOrdinaryUpdateParams{
		ID:           updateID,
		CatID:        catID,
		AuthorUserID: author,
		CreatedAt:    pgtype.Timestamptz{Time: time.Now(), Valid: true},
		Statuses:     []string{"seen"},
	}); err != nil {
		t.Fatalf("create ordinary update: %v", err)
	}

	pool := rawPool(t)
	tx1, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("begin tx1: %v", err)
	}
	defer tx1.Rollback(ctx)

	q1 := repository.New(tx1)
	claimed1, err := q1.ClaimNotificationOutboxBatch(ctx, 10)
	if err != nil {
		t.Fatalf("tx1 claim: %v", err)
	}
	if len(claimed1) != 1 {
		t.Fatalf("expected tx1 to claim 1 row, got %d", len(claimed1))
	}

	// tx1 holds the row lock, uncommitted — a concurrent claim must skip it
	// rather than block or double-claim it.
	tx2, err := pool.Begin(ctx)
	if err != nil {
		t.Fatalf("begin tx2: %v", err)
	}
	defer tx2.Rollback(ctx)

	q2 := repository.New(tx2)
	claimed2, err := q2.ClaimNotificationOutboxBatch(ctx, 10)
	if err != nil {
		t.Fatalf("tx2 claim: %v", err)
	}
	if len(claimed2) != 0 {
		t.Fatalf("expected tx2 to skip the row tx1 holds locked, got %d rows", len(claimed2))
	}
}

func TestStore_CreateNotification_DedupOnConflict(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "dedup cat")
	author := createTestUser(t, ctx, store)
	follower := createTestUser(t, ctx, store)
	device := createTestDevice(t, ctx, store)
	if err := store.LinkDeviceToUser(ctx, repository.LinkDeviceToUserParams{ID: device, UserID: follower}); err != nil {
		t.Fatalf("link device: %v", err)
	}

	updateID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	createdAt := time.Now()
	if _, err := store.CreateNeedsHelpUpdate(ctx, repository.CreateNeedsHelpUpdateParams{
		ID:                 updateID,
		CatID:              catID,
		AuthorUserID:       author,
		CreatedAt:          pgtype.Timestamptz{Time: createdAt, Valid: true},
		NeedsHelpCategory:  "food_needed",
		NeedsHelpExpiresAt: pgtype.Timestamptz{Time: createdAt.Add(72 * time.Hour), Valid: true},
	}); err != nil {
		t.Fatalf("create needs-help update: %v", err)
	}

	first, err := store.CreateNotification(ctx, repository.CreateNotificationParams{
		ID:       pgtype.UUID{Bytes: uuid.New(), Valid: true},
		DeviceID: device,
		CatID:    catID,
		UpdateID: updateID,
	})
	if err != nil {
		t.Fatalf("first create: %v", err)
	}

	_, err = store.CreateNotification(ctx, repository.CreateNotificationParams{
		ID:       pgtype.UUID{Bytes: uuid.New(), Valid: true},
		DeviceID: device,
		CatID:    catID,
		UpdateID: updateID,
	})
	if !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("expected pgx.ErrNoRows on conflicting insert, got %v", err)
	}

	var count int
	if err := rawPool(t).QueryRow(ctx, "select count(*) from notifications where device_id = $1 and update_id = $2", device, updateID).Scan(&count); err != nil {
		t.Fatalf("count notifications: %v", err)
	}
	if count != 1 {
		t.Fatalf("expected exactly 1 notifications row, got %d", count)
	}
	_ = first
}

func TestStore_ListMyNotifications_And_MarkNotificationRead_OwnerScoped(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "inbox cat")
	author := createTestUser(t, ctx, store)

	userA := createTestUser(t, ctx, store)
	deviceA := createTestDevice(t, ctx, store)
	if err := store.LinkDeviceToUser(ctx, repository.LinkDeviceToUserParams{ID: deviceA, UserID: userA}); err != nil {
		t.Fatalf("link device a: %v", err)
	}

	userB := createTestUser(t, ctx, store)
	deviceB := createTestDevice(t, ctx, store)
	if err := store.LinkDeviceToUser(ctx, repository.LinkDeviceToUserParams{ID: deviceB, UserID: userB}); err != nil {
		t.Fatalf("link device b: %v", err)
	}

	updateID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	createdAt := time.Now()
	if _, err := store.CreateNeedsHelpUpdate(ctx, repository.CreateNeedsHelpUpdateParams{
		ID:                 updateID,
		CatID:              catID,
		AuthorUserID:       author,
		CreatedAt:          pgtype.Timestamptz{Time: createdAt, Valid: true},
		NeedsHelpCategory:  "water_needed",
		NeedsHelpExpiresAt: pgtype.Timestamptz{Time: createdAt.Add(72 * time.Hour), Valid: true},
	}); err != nil {
		t.Fatalf("create needs-help update: %v", err)
	}

	notifA, err := store.CreateNotification(ctx, repository.CreateNotificationParams{
		ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}, DeviceID: deviceA, CatID: catID, UpdateID: updateID,
	})
	if err != nil {
		t.Fatalf("create notification a: %v", err)
	}
	if _, err := store.CreateNotification(ctx, repository.CreateNotificationParams{
		ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}, DeviceID: deviceB, CatID: catID, UpdateID: updateID,
	}); err != nil {
		t.Fatalf("create notification b: %v", err)
	}

	rowsA, err := store.ListMyNotifications(ctx, repository.ListMyNotificationsParams{UserID: userA, RowLimit: 20})
	if err != nil {
		t.Fatalf("list for user a: %v", err)
	}
	if len(rowsA) != 1 || rowsA[0].ID != notifA.ID {
		t.Fatalf("expected user a to see only their own notification, got %v", rowsA)
	}

	// marking user b's notification as user a is a no-op, not an error or a
	// cross-account leak.
	if err := store.MarkNotificationRead(ctx, repository.MarkNotificationReadParams{
		ReadAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
		ID:     notifA.ID,
		UserID: userB,
	}); err != nil {
		t.Fatalf("mark read as wrong owner: %v", err)
	}
	rowsA, err = store.ListMyNotifications(ctx, repository.ListMyNotificationsParams{UserID: userA, RowLimit: 20})
	if err != nil {
		t.Fatalf("list for user a after wrong-owner mark: %v", err)
	}
	if rowsA[0].ReadAt.Valid {
		t.Fatalf("expected user a's notification to remain unread after a different owner's mark-read")
	}

	if err := store.MarkNotificationRead(ctx, repository.MarkNotificationReadParams{
		ReadAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
		ID:     notifA.ID,
		UserID: userA,
	}); err != nil {
		t.Fatalf("mark read: %v", err)
	}
	rowsA, err = store.ListMyNotifications(ctx, repository.ListMyNotificationsParams{UserID: userA, RowLimit: 20})
	if err != nil {
		t.Fatalf("list for user a after mark-read: %v", err)
	}
	if !rowsA[0].ReadAt.Valid {
		t.Fatalf("expected user a's notification to be read")
	}
}
