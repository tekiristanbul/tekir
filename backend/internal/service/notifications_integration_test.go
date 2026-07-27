package service_test

import (
	"context"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// newNotificationTestStore connects to DATABASE_URL, skipping the test if
// it isn't set — mirrors internal/repository's newTestStore, duplicated
// here since that helper is unexported in package repository_test and this
// file needs a real *repository.Store to exercise NotificationService's
// actual transactional (issue #78's for-update-skip-locked) behavior,
// which no in-memory fake can meaningfully stand in for.
func newNotificationTestStore(t *testing.T) *repository.Store {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set, skipping integration test")
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)
	return repository.NewStore(pool)
}

var notifTestPhoneCounter int64

func notifTestPhone(t *testing.T) string {
	t.Helper()
	n := atomic.AddInt64(&notifTestPhoneCounter, 1)
	v := (time.Now().UnixNano() + n) % 10000000
	if v < 0 {
		v = -v
	}
	return "+90555" + padDigits(v)
}

func padDigits(v int64) string {
	s := ""
	for range 7 {
		s = string(rune('0'+v%10)) + s
		v /= 10
	}
	return s
}

func notifUpsertTestCat(t *testing.T, ctx context.Context, store *repository.Store, name string) pgtype.UUID {
	t.Helper()
	id := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.UpsertCat(ctx, repository.UpsertCatParams{
		ID:       id,
		Name:     pgtype.Text{String: name, Valid: true},
		Lng:      28.9744,
		Lat:      41.0256,
		PhotoUrl: pgtype.Text{String: "https://placecats.com/millie/300/200", Valid: true},
		Status:   "active",
	}); err != nil {
		t.Fatalf("upsert cat: %v", err)
	}
	return id
}

func notifCreateTestUser(t *testing.T, ctx context.Context, store *repository.Store) pgtype.UUID {
	t.Helper()
	id := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.CreateUser(ctx, repository.CreateUserParams{
		ID:              id,
		Phone:           notifTestPhone(t),
		PhoneVerifiedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}); err != nil {
		t.Fatalf("create user: %v", err)
	}
	return id
}

func notifCreateTestDevice(t *testing.T, ctx context.Context, store *repository.Store, userID pgtype.UUID) pgtype.UUID {
	t.Helper()
	id := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.CreateDevice(ctx, repository.CreateDeviceParams{
		ID:        id,
		TokenHash: service.HashDeviceToken("notif-test-token-" + uuid.New().String()),
		Platform:  "web",
	}); err != nil {
		t.Fatalf("create device: %v", err)
	}
	if err := store.LinkDeviceToUser(ctx, repository.LinkDeviceToUserParams{ID: id, UserID: userID}); err != nil {
		t.Fatalf("link device: %v", err)
	}
	return id
}

// drainPending exhausts every currently-pending outbox row through a
// throwaway NotificationService+sender before a test creates its own data
// — the shared test database accumulates unprocessed outbox rows across
// every repository/service test in the suite (CreateOrdinaryUpdate/
// CreateNeedsHelpUpdate always enqueue one), so without this a test
// asserting on exactly what DispatchPending processed would be at the
// mercy of test run order.
func drainPending(t *testing.T, ctx context.Context, store *repository.Store) {
	t.Helper()
	drain := service.NewNotificationService(store, service.NewFakeNotificationSender())
	for {
		n, err := drain.DispatchPending(ctx)
		if err != nil {
			t.Fatalf("drain dispatch: %v", err)
		}
		if n == 0 {
			return
		}
	}
}

func TestNotificationService_DispatchPending_NeedsHelpFansOutExcludingAuthorAndRevoked(t *testing.T) {
	store := newNotificationTestStore(t)
	ctx := context.Background()
	drainPending(t, ctx, store)

	catID := notifUpsertTestCat(t, ctx, store, "dispatch fan-out cat")

	author := notifCreateTestUser(t, ctx, store)
	authorDevice := notifCreateTestDevice(t, ctx, store, author)
	if err := store.CreateFollow(ctx, repository.CreateFollowParams{UserID: author, CatID: catID}); err != nil {
		t.Fatalf("author follow: %v", err)
	}

	follower := notifCreateTestUser(t, ctx, store)
	followerDevice := notifCreateTestDevice(t, ctx, store, follower)
	if err := store.CreateFollow(ctx, repository.CreateFollowParams{UserID: follower, CatID: catID}); err != nil {
		t.Fatalf("follower follow: %v", err)
	}

	revoked := notifCreateTestUser(t, ctx, store)
	revokedDevice := notifCreateTestDevice(t, ctx, store, revoked)
	if err := store.CreateFollow(ctx, repository.CreateFollowParams{UserID: revoked, CatID: catID}); err != nil {
		t.Fatalf("revoked follower follow: %v", err)
	}
	pool, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		t.Fatalf("connect for revoke: %v", err)
	}
	defer pool.Close()
	if _, err := pool.Exec(ctx, "update devices set revoked_at = now() where id = $1", revokedDevice); err != nil {
		t.Fatalf("revoke device: %v", err)
	}

	createdAt := time.Now()
	updateID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.CreateNeedsHelpUpdate(ctx, repository.CreateNeedsHelpUpdateParams{
		ID:                 updateID,
		CatID:              catID,
		AuthorUserID:       author,
		AuthorDeviceID:     authorDevice,
		CreatedAt:          pgtype.Timestamptz{Time: createdAt, Valid: true},
		NeedsHelpCategory:  "injured_or_sick",
		NeedsHelpExpiresAt: pgtype.Timestamptz{Time: createdAt.Add(72 * time.Hour), Valid: true},
	}); err != nil {
		t.Fatalf("create needs-help update: %v", err)
	}

	sender := service.NewFakeNotificationSender()
	notifications := service.NewNotificationService(store, sender)
	processed, err := notifications.DispatchPending(ctx)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if processed != 1 {
		t.Fatalf("expected exactly 1 outbox row processed, got %d", processed)
	}

	sent := sender.Sent()
	if len(sent) != 1 {
		t.Fatalf("expected exactly 1 notification sent, got %d: %+v", len(sent), sent)
	}
	if sent[0].DeviceID != uuid.UUID(followerDevice.Bytes).String() {
		t.Errorf("expected notification sent to follower's device, got %q", sent[0].DeviceID)
	}
	if sent[0].UpdateID != uuid.UUID(updateID.Bytes).String() {
		t.Errorf("unexpected update id: %q", sent[0].UpdateID)
	}
	if sent[0].Category != "injured_or_sick" {
		t.Errorf("unexpected category: %q", sent[0].Category)
	}

	var notifCount int
	if err := pool.QueryRow(ctx, "select count(*) from notifications where update_id = $1", updateID).Scan(&notifCount); err != nil {
		t.Fatalf("count notifications: %v", err)
	}
	if notifCount != 1 {
		t.Errorf("expected exactly 1 notifications row, got %d", notifCount)
	}

	var processedAt pgtype.Timestamptz
	if err := pool.QueryRow(ctx, "select processed_at from notification_outbox where update_id = $1", updateID).Scan(&processedAt); err != nil {
		t.Fatalf("query outbox processed_at: %v", err)
	}
	if !processedAt.Valid {
		t.Errorf("expected outbox row to be marked processed")
	}
}

func TestNotificationService_DispatchPending_OrdinaryUpdateProducesNoNotifications(t *testing.T) {
	store := newNotificationTestStore(t)
	ctx := context.Background()
	drainPending(t, ctx, store)

	catID := notifUpsertTestCat(t, ctx, store, "ordinary dispatch cat")
	author := notifCreateTestUser(t, ctx, store)
	follower := notifCreateTestUser(t, ctx, store)
	notifCreateTestDevice(t, ctx, store, follower)
	if err := store.CreateFollow(ctx, repository.CreateFollowParams{UserID: follower, CatID: catID}); err != nil {
		t.Fatalf("follow: %v", err)
	}

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

	sender := service.NewFakeNotificationSender()
	notifications := service.NewNotificationService(store, sender)
	processed, err := notifications.DispatchPending(ctx)
	if err != nil {
		t.Fatalf("dispatch: %v", err)
	}
	if processed != 1 {
		t.Fatalf("expected exactly 1 outbox row processed, got %d", processed)
	}
	if len(sender.Sent()) != 0 {
		t.Fatalf("expected no notifications sent for an ordinary update, got %+v", sender.Sent())
	}
}

func TestNotificationService_DispatchPending_IdempotentRedispatch(t *testing.T) {
	store := newNotificationTestStore(t)
	ctx := context.Background()
	drainPending(t, ctx, store)

	catID := notifUpsertTestCat(t, ctx, store, "idempotent redispatch cat")
	author := notifCreateTestUser(t, ctx, store)
	follower := notifCreateTestUser(t, ctx, store)
	notifCreateTestDevice(t, ctx, store, follower)
	if err := store.CreateFollow(ctx, repository.CreateFollowParams{UserID: follower, CatID: catID}); err != nil {
		t.Fatalf("follow: %v", err)
	}

	createdAt := time.Now()
	if _, err := store.CreateNeedsHelpUpdate(ctx, repository.CreateNeedsHelpUpdateParams{
		ID:                 pgtype.UUID{Bytes: uuid.New(), Valid: true},
		CatID:              catID,
		AuthorUserID:       author,
		CreatedAt:          pgtype.Timestamptz{Time: createdAt, Valid: true},
		NeedsHelpCategory:  "water_needed",
		NeedsHelpExpiresAt: pgtype.Timestamptz{Time: createdAt.Add(72 * time.Hour), Valid: true},
	}); err != nil {
		t.Fatalf("create needs-help update: %v", err)
	}

	sender := service.NewFakeNotificationSender()
	notifications := service.NewNotificationService(store, sender)

	first, err := notifications.DispatchPending(ctx)
	if err != nil {
		t.Fatalf("first dispatch: %v", err)
	}
	if first != 1 {
		t.Fatalf("expected 1 processed on first dispatch, got %d", first)
	}
	if len(sender.Sent()) != 1 {
		t.Fatalf("expected 1 send after first dispatch, got %d", len(sender.Sent()))
	}

	// the row is already marked processed — a second call must find
	// nothing left to claim, and must not send again.
	second, err := notifications.DispatchPending(ctx)
	if err != nil {
		t.Fatalf("second dispatch: %v", err)
	}
	if second != 0 {
		t.Fatalf("expected 0 processed on second dispatch, got %d", second)
	}
	if len(sender.Sent()) != 1 {
		t.Fatalf("expected still exactly 1 send after second dispatch, got %d", len(sender.Sent()))
	}
}

// TestNotificationService_DispatchPending_ConcurrentDispatchNoDuplicateSends
// proves ClaimNotificationOutboxBatch's `for update skip locked` (issue
// #78) plus notifications' (device_id, update_id) unique constraint
// together make concurrent DispatchPending calls against the same pending
// work safe: every recipient device gets exactly one send, never more,
// regardless of how the two calls' claims happen to interleave.
func TestNotificationService_DispatchPending_ConcurrentDispatchNoDuplicateSends(t *testing.T) {
	store := newNotificationTestStore(t)
	ctx := context.Background()
	drainPending(t, ctx, store)

	catID := notifUpsertTestCat(t, ctx, store, "concurrent dispatch cat")
	author := notifCreateTestUser(t, ctx, store)

	const followerCount = 5
	followerDevices := make(map[string]bool, followerCount)
	for i := 0; i < followerCount; i++ {
		follower := notifCreateTestUser(t, ctx, store)
		device := notifCreateTestDevice(t, ctx, store, follower)
		followerDevices[uuid.UUID(device.Bytes).String()] = true
		if err := store.CreateFollow(ctx, repository.CreateFollowParams{UserID: follower, CatID: catID}); err != nil {
			t.Fatalf("follow: %v", err)
		}
	}

	createdAt := time.Now()
	updateID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.CreateNeedsHelpUpdate(ctx, repository.CreateNeedsHelpUpdateParams{
		ID:                 updateID,
		CatID:              catID,
		AuthorUserID:       author,
		CreatedAt:          pgtype.Timestamptz{Time: createdAt, Valid: true},
		NeedsHelpCategory:  "unsafe_location",
		NeedsHelpExpiresAt: pgtype.Timestamptz{Time: createdAt.Add(72 * time.Hour), Valid: true},
	}); err != nil {
		t.Fatalf("create needs-help update: %v", err)
	}

	sender := service.NewFakeNotificationSender()
	notifications := service.NewNotificationService(store, sender)

	var wg sync.WaitGroup
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for attempt := 0; attempt < 5; attempt++ {
				if _, err := notifications.DispatchPending(ctx); err != nil {
					t.Errorf("concurrent dispatch: %v", err)
					return
				}
			}
		}()
	}
	wg.Wait()

	sent := sender.Sent()
	seen := map[string]int{}
	for _, s := range sent {
		if s.UpdateID != uuid.UUID(updateID.Bytes).String() {
			continue
		}
		seen[s.DeviceID]++
	}
	if len(seen) != followerCount {
		t.Fatalf("expected %d distinct devices notified, got %d: %v", followerCount, len(seen), seen)
	}
	for device, count := range seen {
		if !followerDevices[device] {
			t.Errorf("unexpected device notified: %s", device)
		}
		if count != 1 {
			t.Errorf("expected device %s notified exactly once, got %d", device, count)
		}
	}
}
