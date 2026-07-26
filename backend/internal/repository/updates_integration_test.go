package repository_test

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// isCheckViolation reports whether err is a postgres check-constraint
// failure (sqlstate 23514) — the mechanism updates_kind_fields_ck (issue
// #23) and update_statuses' status check use to reject an invalid
// ordinary/needs-help field combination or an unlisted category.
func isCheckViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23514"
}

// isUniqueViolation reports whether err is a postgres unique-constraint
// failure (sqlstate 23505) — notification_outbox_update_id_key (migration
// 00009) uses this to reject a duplicate enqueue for the same update.
func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

func createNeedsHelpUpdate(t *testing.T, ctx context.Context, store *repository.Store, catID pgtype.UUID, createdAt time.Time, category string) {
	t.Helper()
	_, err := store.CreateUpdate(ctx, repository.CreateUpdateParams{
		ID:                 pgtype.UUID{Bytes: uuid.New(), Valid: true},
		CatID:              catID,
		Kind:               "needs_help",
		CreatedAt:          pgtype.Timestamptz{Time: createdAt, Valid: true},
		NeedsHelpCategory:  pgtype.Text{String: category, Valid: true},
		NeedsHelpExpiresAt: pgtype.Timestamptz{Time: createdAt.Add(72 * time.Hour), Valid: true},
	})
	if err != nil {
		t.Fatalf("create needs-help update: %v", err)
	}
}

// newTestStore connects to DATABASE_URL, skipping the test if it isn't set
// (mirrors cats_integration_test.go: requires a real, migrated database).
func newTestStore(t *testing.T) *repository.Store {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set, skipping integration test")
	}

	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)

	return repository.NewStore(pool)
}

func upsertTestCat(t *testing.T, ctx context.Context, store *repository.Store, name string) pgtype.UUID {
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
		t.Fatalf("upsert cat %s: %v", name, err)
	}
	return id
}

func createTestUpdate(t *testing.T, ctx context.Context, store *repository.Store, catID pgtype.UUID, createdAt time.Time, statuses []string, comment string) {
	t.Helper()
	var commentText pgtype.Text
	if comment != "" {
		commentText = pgtype.Text{String: comment, Valid: true}
	}

	row, err := store.CreateUpdate(ctx, repository.CreateUpdateParams{
		ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
		CatID:     catID,
		Kind:      "ordinary",
		Comment:   commentText,
		CreatedAt: pgtype.Timestamptz{Time: createdAt, Valid: true},
	})
	if err != nil {
		t.Fatalf("create update: %v", err)
	}
	for _, status := range statuses {
		if err := store.CreateUpdateStatus(ctx, repository.CreateUpdateStatusParams{
			UpdateID: row.ID,
			Status:   status,
		}); err != nil {
			t.Fatalf("create update status %s: %v", status, err)
		}
	}
}

func TestStore_GetCatByID(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "tekir")

	row, err := store.GetCatByID(ctx, id)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if row.Name.String != "tekir" {
		t.Errorf("expected name %q, got %q", "tekir", row.Name.String)
	}
}

func TestStore_GetCatByID_UnknownCat(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	_, err := store.GetCatByID(ctx, pgtype.UUID{Bytes: uuid.New(), Valid: true})
	if !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("expected pgx.ErrNoRows, got %v", err)
	}
}

func TestStore_CatExists(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "tekir")

	exists, err := store.CatExists(ctx, id)
	if err != nil {
		t.Fatalf("exists: %v", err)
	}
	if !exists {
		t.Error("expected existing cat to report exists=true")
	}

	exists, err = store.CatExists(ctx, pgtype.UUID{Bytes: uuid.New(), Valid: true})
	if err != nil {
		t.Fatalf("exists: %v", err)
	}
	if exists {
		t.Error("expected unknown cat to report exists=false")
	}
}

func TestStore_ListCatUpdates_EmptyHistory(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "no history yet")

	rows, err := store.ListCatUpdates(ctx, repository.ListCatUpdatesParams{CatID: id, RowLimit: 20})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 0 {
		t.Errorf("expected no updates, got %d", len(rows))
	}
}

func TestStore_ListCatUpdates_NewestFirstWithTieBreaker(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "with history")

	base := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	// two updates share the exact same created_at: seq must break the tie.
	createTestUpdate(t, ctx, store, id, base.Add(-time.Hour), []string{"seen"}, "")
	createTestUpdate(t, ctx, store, id, base, []string{"fed"}, "")
	createTestUpdate(t, ctx, store, id, base, []string{"seen", "water_provided"}, "topped up water")

	rows, err := store.ListCatUpdates(ctx, repository.ListCatUpdatesParams{CatID: id, RowLimit: 20})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 3 {
		t.Fatalf("expected 3 updates, got %d", len(rows))
	}

	// newest first: the two same-created_at rows come before the older one,
	// ordered between themselves by seq desc (insertion order, since seq is
	// a bigserial) — i.e. the later insert (with the comment) comes first.
	if rows[0].Comment.String != "topped up water" {
		t.Errorf("expected the most recently inserted same-timestamp row first, got comment %q", rows[0].Comment.String)
	}
	if rows[1].Seq.Int64 >= rows[0].Seq.Int64 {
		t.Errorf("expected seq to strictly decrease across the tie, got %d then %d", rows[0].Seq.Int64, rows[1].Seq.Int64)
	}
	if !rows[2].CreatedAt.Time.Equal(base.Add(-time.Hour)) {
		t.Errorf("expected the oldest update last, got created_at %v", rows[2].CreatedAt.Time)
	}
}

func TestStore_ListCatUpdates_Pagination(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "paginated")

	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	for i := 0; i < 5; i++ {
		createTestUpdate(t, ctx, store, id, base.Add(time.Duration(i)*time.Hour), []string{"seen"}, "")
	}

	firstPage, err := store.ListCatUpdates(ctx, repository.ListCatUpdatesParams{CatID: id, RowLimit: 2})
	if err != nil {
		t.Fatalf("first page: %v", err)
	}
	if len(firstPage) != 2 {
		t.Fatalf("expected 2 rows on the first page, got %d", len(firstPage))
	}
	// newest first: hour 4, then hour 3.
	if !firstPage[0].CreatedAt.Time.Equal(base.Add(4 * time.Hour)) {
		t.Errorf("expected newest update first, got %v", firstPage[0].CreatedAt.Time)
	}
	if !firstPage[1].CreatedAt.Time.Equal(base.Add(3 * time.Hour)) {
		t.Errorf("expected second-newest update second, got %v", firstPage[1].CreatedAt.Time)
	}

	last := firstPage[len(firstPage)-1]
	secondPage, err := store.ListCatUpdates(ctx, repository.ListCatUpdatesParams{
		CatID:           id,
		RowLimit:        2,
		BeforeCreatedAt: last.CreatedAt,
		BeforeSeq:       last.Seq,
	})
	if err != nil {
		t.Fatalf("second page: %v", err)
	}
	if len(secondPage) != 2 {
		t.Fatalf("expected 2 rows on the second page, got %d", len(secondPage))
	}
	if !secondPage[0].CreatedAt.Time.Equal(base.Add(2 * time.Hour)) {
		t.Errorf("expected hour 2 update first on second page, got %v", secondPage[0].CreatedAt.Time)
	}
	if !secondPage[1].CreatedAt.Time.Equal(base.Add(1 * time.Hour)) {
		t.Errorf("expected hour 1 update second on second page, got %v", secondPage[1].CreatedAt.Time)
	}

	// no overlap between pages.
	for _, r := range secondPage {
		if r.ID == firstPage[0].ID || r.ID == firstPage[1].ID {
			t.Error("second page must not repeat a row already served on the first page")
		}
	}
}

func TestStore_ListCatUpdates_NoCommentIsNull(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "quiet visit")
	createTestUpdate(t, ctx, store, id, time.Now(), []string{"seen"}, "")

	rows, err := store.ListCatUpdates(ctx, repository.ListCatUpdatesParams{CatID: id, RowLimit: 20})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 update, got %d", len(rows))
	}
	if rows[0].Comment.Valid {
		t.Errorf("expected no comment, got %q", rows[0].Comment.String)
	}
}

func TestStore_CreateUpdate_AllFiveNeedsHelpCategories(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "needs-help demo")
	categories := []string{"injured_or_sick", "food_needed", "water_needed", "unsafe_location", "trapped"}
	for i, category := range categories {
		createNeedsHelpUpdate(t, ctx, store, id, time.Now().Add(-time.Duration(i)*time.Minute), category)
	}
}

func TestStore_CreateUpdate_InvalidNeedsHelpCategoryRejected(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "invalid category")
	_, err := store.CreateUpdate(ctx, repository.CreateUpdateParams{
		ID:                 pgtype.UUID{Bytes: uuid.New(), Valid: true},
		CatID:              id,
		Kind:               "needs_help",
		CreatedAt:          pgtype.Timestamptz{Time: time.Now(), Valid: true},
		NeedsHelpCategory:  pgtype.Text{String: "not_a_real_category", Valid: true},
		NeedsHelpExpiresAt: pgtype.Timestamptz{Time: time.Now().Add(72 * time.Hour), Valid: true},
	})
	if !isCheckViolation(err) {
		t.Fatalf("expected a check-constraint violation for an unlisted category, got %v", err)
	}
}

func TestStore_CreateUpdate_OrdinaryCannotCarryNeedsHelpFields(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "ordinary with stray needs-help field")
	_, err := store.CreateUpdate(ctx, repository.CreateUpdateParams{
		ID:                pgtype.UUID{Bytes: uuid.New(), Valid: true},
		CatID:             id,
		Kind:              "ordinary",
		CreatedAt:         pgtype.Timestamptz{Time: time.Now(), Valid: true},
		NeedsHelpCategory: pgtype.Text{String: "trapped", Valid: true},
	})
	if !isCheckViolation(err) {
		t.Fatalf("expected a check-constraint violation for an ordinary update carrying a needs-help category, got %v", err)
	}
}

func TestStore_CreateUpdate_NeedsHelpRequiresCategoryAndExpiry(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "incomplete needs-help")

	t.Run("missing category", func(t *testing.T) {
		_, err := store.CreateUpdate(ctx, repository.CreateUpdateParams{
			ID:                 pgtype.UUID{Bytes: uuid.New(), Valid: true},
			CatID:              id,
			Kind:               "needs_help",
			CreatedAt:          pgtype.Timestamptz{Time: time.Now(), Valid: true},
			NeedsHelpExpiresAt: pgtype.Timestamptz{Time: time.Now().Add(72 * time.Hour), Valid: true},
		})
		if !isCheckViolation(err) {
			t.Fatalf("expected a check-constraint violation for a needs-help update missing its category, got %v", err)
		}
	})

	t.Run("missing expiry", func(t *testing.T) {
		_, err := store.CreateUpdate(ctx, repository.CreateUpdateParams{
			ID:                pgtype.UUID{Bytes: uuid.New(), Valid: true},
			CatID:             id,
			Kind:              "needs_help",
			CreatedAt:         pgtype.Timestamptz{Time: time.Now(), Valid: true},
			NeedsHelpCategory: pgtype.Text{String: "trapped", Valid: true},
		})
		if !isCheckViolation(err) {
			t.Fatalf("expected a check-constraint violation for a needs-help update missing its expiry, got %v", err)
		}
	})
}

func TestStore_ListCatUpdates_NeedsHelpEntryCarriesCategoryAndExpiry(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "needs-help history entry")
	createNeedsHelpUpdate(t, ctx, store, id, time.Now().Add(-time.Hour), "food_needed")

	rows, err := store.ListCatUpdates(ctx, repository.ListCatUpdatesParams{CatID: id, RowLimit: 20})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 update, got %d", len(rows))
	}
	if rows[0].Kind != "needs_help" {
		t.Errorf("expected kind needs_help, got %q", rows[0].Kind)
	}
	if !rows[0].NeedsHelpCategory.Valid || rows[0].NeedsHelpCategory.String != "food_needed" {
		t.Errorf("unexpected needs_help_category: %v", rows[0].NeedsHelpCategory)
	}
	if !rows[0].NeedsHelpExpiresAt.Valid {
		t.Error("expected needs_help_expires_at to be set")
	}
	// an expired needs-help update stays in history, exactly like an
	// ordinary one — expiry only ever affects active-surface emphasis,
	// never row survival (issue #4/#23).
}

func TestStore_GetCatByID_LatestNeedsHelpUpdate(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "repeated alerts")
	createNeedsHelpUpdate(t, ctx, store, id, time.Now().Add(-10*time.Hour), "water_needed")
	createNeedsHelpUpdate(t, ctx, store, id, time.Now().Add(-time.Hour), "trapped")

	row, err := store.GetCatByID(ctx, id)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if !row.NeedsHelpCategory.Valid || row.NeedsHelpCategory.String != "trapped" {
		t.Errorf("expected the latest needs-help update's category (trapped), got %v", row.NeedsHelpCategory)
	}
}

// rawPool opens a second, direct connection to DATABASE_URL for assertions
// the sqlc-generated Store has no query for (e.g. counting
// notification_outbox rows, or checking a table for rows that must not
// exist after a rolled-back transaction).
func rawPool(t *testing.T) *pgxpool.Pool {
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
	return pool
}

// TestStore_CreateOrdinaryUpdate_Success exercises issue #36's atomic write
// end to end against real postgres: the update row, its statuses, the
// cat's last_update_at, and the notification_outbox row
// Store.CreateOrdinaryUpdate enqueues explicitly (issue #38, migration
// 00009 — no trigger is involved anymore) all need to commit together, and
// the new update needs to surface correctly through the existing
// ListCatUpdates pagination path. Uses a fixed timestamp rather than
// time.Now() so the test is deterministic (issue #38).
func TestStore_CreateOrdinaryUpdate_Success(t *testing.T) {
	store := newTestStore(t)
	pool := rawPool(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "ordinary update recipient")
	device, err := store.CreateDevice(ctx, repository.CreateDeviceParams{
		ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
		TokenHash: uuid.NewString(),
		Platform:  "ios",
	})
	if err != nil {
		t.Fatalf("create device: %v", err)
	}

	userID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.CreateUser(ctx, repository.CreateUserParams{
		ID:              userID,
		Phone:           "+90555" + testDigits(t),
		PhoneVerifiedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}); err != nil {
		t.Fatalf("create user: %v", err)
	}

	createdAt := time.Date(2026, 2, 1, 9, 30, 0, 0, time.UTC)
	updateID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	row, err := store.CreateOrdinaryUpdate(ctx, repository.CreateOrdinaryUpdateParams{
		ID:             updateID,
		CatID:          catID,
		AuthorDeviceID: device.ID,
		AuthorUserID:   userID,
		Comment:        pgtype.Text{String: "mama verildi", Valid: true},
		CreatedAt:      pgtype.Timestamptz{Time: createdAt, Valid: true},
		Statuses:       []string{"fed", "seen"},
	})
	if err != nil {
		t.Fatalf("create ordinary update: %v", err)
	}
	if row.ID != updateID {
		t.Errorf("expected row id %v, got %v", updateID, row.ID)
	}

	// author attribution landed on the update row.
	var authorDeviceID, authorUserID pgtype.UUID
	if err := pool.QueryRow(ctx, "select author_device_id, author_user_id from updates where id = $1", row.ID).Scan(&authorDeviceID, &authorUserID); err != nil {
		t.Fatalf("query author attribution: %v", err)
	}
	if authorDeviceID != device.ID {
		t.Errorf("expected author_device_id %v, got %v", device.ID, authorDeviceID)
	}
	if authorUserID != userID {
		t.Errorf("expected author_user_id %v, got %v", userID, authorUserID)
	}

	// cats.last_update_at moved to the update's created_at, atomically.
	cat, err := store.GetCatByID(ctx, catID)
	if err != nil {
		t.Fatalf("get cat: %v", err)
	}
	if !cat.LastUpdateAt.Valid || !cat.LastUpdateAt.Time.Equal(createdAt) {
		t.Errorf("expected last_update_at %v, got %v", createdAt, cat.LastUpdateAt.Time)
	}

	// exactly one notification_outbox row was enqueued explicitly.
	var outboxCount int
	if err := pool.QueryRow(ctx, "select count(*) from notification_outbox where update_id = $1", row.ID).Scan(&outboxCount); err != nil {
		t.Fatalf("count outbox rows: %v", err)
	}
	if outboxCount != 1 {
		t.Errorf("expected exactly 1 notification_outbox row, got %d", outboxCount)
	}

	// the new update surfaces correctly through the existing pagination path.
	rows, err := store.ListCatUpdates(ctx, repository.ListCatUpdatesParams{CatID: catID, RowLimit: 20})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 update, got %d", len(rows))
	}
	if rows[0].ID != row.ID {
		t.Errorf("expected listed update id %v, got %v", row.ID, rows[0].ID)
	}
	if rows[0].Kind != "ordinary" {
		t.Errorf("expected kind ordinary, got %q", rows[0].Kind)
	}
	if len(rows[0].Statuses) != 2 {
		t.Errorf("unexpected statuses: %v", rows[0].Statuses)
	}
	if rows[0].Comment.String != "mama verildi" {
		t.Errorf("unexpected comment: %q", rows[0].Comment.String)
	}
}

// TestStore_CreateOrdinaryUpdate_WithoutAuthorDeviceID_Succeeds proves an
// ordinary update can be created with only an author_user_id and no
// author_device_id (issue #65: device association is optional on this
// write path — a bearer-only request, with no X-Device-Token, is valid).
func TestStore_CreateOrdinaryUpdate_WithoutAuthorDeviceID_Succeeds(t *testing.T) {
	store := newTestStore(t)
	pool := rawPool(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "device-optional recipient")
	userID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.CreateUser(ctx, repository.CreateUserParams{
		ID:              userID,
		Phone:           "+90555" + testDigits(t),
		PhoneVerifiedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}); err != nil {
		t.Fatalf("create user: %v", err)
	}

	updateID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	row, err := store.CreateOrdinaryUpdate(ctx, repository.CreateOrdinaryUpdateParams{
		ID:           updateID,
		CatID:        catID,
		AuthorUserID: userID,
		CreatedAt:    pgtype.Timestamptz{Time: time.Date(2026, 2, 2, 9, 0, 0, 0, time.UTC), Valid: true},
		Statuses:     []string{"seen"},
	})
	if err != nil {
		t.Fatalf("create ordinary update without device: %v", err)
	}

	var authorDeviceID, authorUserID pgtype.UUID
	if err := pool.QueryRow(ctx, "select author_device_id, author_user_id from updates where id = $1", row.ID).Scan(&authorDeviceID, &authorUserID); err != nil {
		t.Fatalf("query author attribution: %v", err)
	}
	if authorDeviceID.Valid {
		t.Errorf("expected no author_device_id, got %v", authorDeviceID)
	}
	if authorUserID != userID {
		t.Errorf("expected author_user_id %v, got %v", userID, authorUserID)
	}
}

// TestStore_BackfillUpdatesAuthorUserID_Idempotent proves the backfill
// query AuthService.linkDevice runs inside its transaction only touches
// rows still missing author_user_id, and rerunning it (a retried or
// repeated link) never overwrites an already-attributed row toward a
// different account.
func TestStore_BackfillUpdatesAuthorUserID_Idempotent(t *testing.T) {
	store := newTestStore(t)
	pool := rawPool(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "backfill recipient")
	device, err := store.CreateDevice(ctx, repository.CreateDeviceParams{
		ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
		TokenHash: uuid.NewString(),
		Platform:  "ios",
	})
	if err != nil {
		t.Fatalf("create device: %v", err)
	}

	updateID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.CreateOrdinaryUpdate(ctx, repository.CreateOrdinaryUpdateParams{
		ID:             updateID,
		CatID:          catID,
		AuthorDeviceID: device.ID,
		CreatedAt:      pgtype.Timestamptz{Time: time.Date(2026, 2, 3, 9, 0, 0, 0, time.UTC), Valid: true},
		Statuses:       []string{"seen"},
	}); err != nil {
		t.Fatalf("seed device-owned update: %v", err)
	}

	accountA := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.CreateUser(ctx, repository.CreateUserParams{
		ID:              accountA,
		Phone:           "+90555" + testDigits(t),
		PhoneVerifiedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}); err != nil {
		t.Fatalf("create account A: %v", err)
	}

	// First backfill attributes the row to account A.
	if err := store.BackfillUpdatesAuthorUserID(ctx, repository.BackfillUpdatesAuthorUserIDParams{
		AuthorUserID:   accountA,
		AuthorDeviceID: device.ID,
	}); err != nil {
		t.Fatalf("first backfill: %v", err)
	}

	accountB := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.CreateUser(ctx, repository.CreateUserParams{
		ID:              accountB,
		Phone:           "+90555" + testDigits(t),
		PhoneVerifiedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}); err != nil {
		t.Fatalf("create account B: %v", err)
	}

	// A repeat backfill (e.g. a retried transaction) targeting a different
	// account must be a no-op — the row is already attributed.
	if err := store.BackfillUpdatesAuthorUserID(ctx, repository.BackfillUpdatesAuthorUserIDParams{
		AuthorUserID:   accountB,
		AuthorDeviceID: device.ID,
	}); err != nil {
		t.Fatalf("second backfill: %v", err)
	}

	var authorUserID pgtype.UUID
	if err := pool.QueryRow(ctx, "select author_user_id from updates where id = $1", updateID).Scan(&authorUserID); err != nil {
		t.Fatalf("query author_user_id: %v", err)
	}
	if authorUserID != accountA {
		t.Errorf("expected author_user_id to stay %v after a repeat backfill, got %v", accountA, authorUserID)
	}
}

// TestStore_CreateOrdinaryUpdate_RollsBackOnInvalidStatus verifies the
// transaction is a real, all-or-nothing unit rather than a best-effort
// sequence of writes: an update_statuses check-constraint violation (a real
// postgres failure, not a mock) must leave no trace of the update row, no
// cats.last_update_at change, and no notification_outbox row. Uses a fixed
// timestamp rather than time.Now() so the test is deterministic (issue #38).
func TestStore_CreateOrdinaryUpdate_RollsBackOnInvalidStatus(t *testing.T) {
	store := newTestStore(t)
	pool := rawPool(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "rollback target")
	before, err := store.GetCatByID(ctx, catID)
	if err != nil {
		t.Fatalf("get cat: %v", err)
	}

	updateID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	_, err = store.CreateOrdinaryUpdate(ctx, repository.CreateOrdinaryUpdateParams{
		ID:        updateID,
		CatID:     catID,
		CreatedAt: pgtype.Timestamptz{Time: time.Date(2026, 2, 1, 9, 31, 0, 0, time.UTC), Valid: true},
		Statuses:  []string{"not_a_real_status"},
	})
	if !isCheckViolation(err) {
		t.Fatalf("expected a check-constraint violation, got %v", err)
	}

	// the update row itself did not survive the rollback.
	var updateCount int
	if err := pool.QueryRow(ctx, "select count(*) from updates where id = $1", updateID).Scan(&updateCount); err != nil {
		t.Fatalf("count update rows: %v", err)
	}
	if updateCount != 0 {
		t.Errorf("expected the update row to be rolled back, found %d", updateCount)
	}

	// cats.last_update_at is untouched.
	after, err := store.GetCatByID(ctx, catID)
	if err != nil {
		t.Fatalf("get cat: %v", err)
	}
	if after.LastUpdateAt != before.LastUpdateAt {
		t.Errorf("expected last_update_at to stay %v, got %v", before.LastUpdateAt, after.LastUpdateAt)
	}

	// no outbox row: the enqueue runs inside the same transaction as the
	// insert that rolled back, so it never committed either.
	var outboxCount int
	if err := pool.QueryRow(ctx, "select count(*) from notification_outbox where update_id = $1", updateID).Scan(&outboxCount); err != nil {
		t.Fatalf("count outbox rows: %v", err)
	}
	if outboxCount != 0 {
		t.Errorf("expected no notification_outbox row after rollback, got %d", outboxCount)
	}
}

// TestStore_CreateOrdinaryUpdate_DuplicateEnqueueRollsBack verifies
// notification_outbox_update_id_key (migration 00009) does its job: retrying
// CreateOrdinaryUpdate with the same update id must fail the enqueue with a
// unique-constraint violation and roll the whole retried write back, rather
// than silently duplicating notification work.
func TestStore_CreateOrdinaryUpdate_DuplicateEnqueueRollsBack(t *testing.T) {
	store := newTestStore(t)
	pool := rawPool(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "duplicate enqueue target")
	updateID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	createdAt := time.Date(2026, 2, 1, 9, 32, 0, 0, time.UTC)
	params := repository.CreateOrdinaryUpdateParams{
		ID:        updateID,
		CatID:     catID,
		CreatedAt: pgtype.Timestamptz{Time: createdAt, Valid: true},
		Statuses:  []string{"seen"},
	}

	if _, err := store.CreateOrdinaryUpdate(ctx, params); err != nil {
		t.Fatalf("first create ordinary update: %v", err)
	}

	// retry with the same update id: CreateUpdate's on-conflict upsert lets
	// the update/statuses writes succeed again, but the outbox insert for
	// the same update_id must now hit the unique constraint.
	retryCreatedAt := createdAt.Add(time.Minute)
	retryParams := params
	retryParams.CreatedAt = pgtype.Timestamptz{Time: retryCreatedAt, Valid: true}
	_, err := store.CreateOrdinaryUpdate(ctx, retryParams)
	if !isUniqueViolation(err) {
		t.Fatalf("expected a unique-constraint violation on retry, got %v", err)
	}

	// exactly one outbox row exists — the retry's enqueue never committed.
	var outboxCount int
	if err := pool.QueryRow(ctx, "select count(*) from notification_outbox where update_id = $1", updateID).Scan(&outboxCount); err != nil {
		t.Fatalf("count outbox rows: %v", err)
	}
	if outboxCount != 1 {
		t.Errorf("expected exactly 1 notification_outbox row, got %d", outboxCount)
	}

	// the retried transaction rolled back entirely: last_update_at still
	// reflects the first call, not the retry's later timestamp.
	cat, err := store.GetCatByID(ctx, catID)
	if err != nil {
		t.Fatalf("get cat: %v", err)
	}
	if !cat.LastUpdateAt.Valid || !cat.LastUpdateAt.Time.Equal(createdAt) {
		t.Errorf("expected last_update_at to stay %v, got %v", createdAt, cat.LastUpdateAt.Time)
	}
}

// TestStore_CreateUpdate_DirectInsertProducesNoOutboxRow guards the boundary
// issue #38 introduces: only Store.CreateOrdinaryUpdate enqueues
// notification_outbox work now that migration 00009 removed the table-wide
// insert trigger. A direct CreateUpdate call — the path seed/fixtures and
// other repository writes use — must never produce an outbox row.
func TestStore_CreateUpdate_DirectInsertProducesNoOutboxRow(t *testing.T) {
	store := newTestStore(t)
	pool := rawPool(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "direct insert target")
	row, err := store.CreateUpdate(ctx, repository.CreateUpdateParams{
		ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
		CatID:     catID,
		Kind:      "ordinary",
		CreatedAt: pgtype.Timestamptz{Time: time.Date(2026, 2, 1, 9, 33, 0, 0, time.UTC), Valid: true},
	})
	if err != nil {
		t.Fatalf("create update: %v", err)
	}

	var outboxCount int
	if err := pool.QueryRow(ctx, "select count(*) from notification_outbox where update_id = $1", row.ID).Scan(&outboxCount); err != nil {
		t.Fatalf("count outbox rows: %v", err)
	}
	if outboxCount != 0 {
		t.Errorf("expected no notification_outbox row for a direct insert, got %d", outboxCount)
	}
}

// TestStore_UpdateCatLastUpdateAt_Monotonic verifies issue #38's freshness
// fix: committing an older-timestamped update after a newer one must not
// move a cat's last_update_at backwards. Both writes use fixed timestamps
// applied in a deliberately out-of-order sequence, so the assertion is
// deterministic rather than depending on real concurrency or sleeps.
func TestStore_UpdateCatLastUpdateAt_Monotonic(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "monotonic freshness target")
	newer := time.Date(2026, 2, 1, 12, 0, 0, 0, time.UTC)
	older := newer.Add(-time.Hour)

	if _, err := store.CreateOrdinaryUpdate(ctx, repository.CreateOrdinaryUpdateParams{
		ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
		CatID:     catID,
		CreatedAt: pgtype.Timestamptz{Time: newer, Valid: true},
		Statuses:  []string{"seen"},
	}); err != nil {
		t.Fatalf("create ordinary update: %v", err)
	}
	cat, err := store.GetCatByID(ctx, catID)
	if err != nil {
		t.Fatalf("get cat: %v", err)
	}
	if !cat.LastUpdateAt.Valid || !cat.LastUpdateAt.Time.Equal(newer) {
		t.Fatalf("expected last_update_at %v after first write, got %v", newer, cat.LastUpdateAt.Time)
	}

	if err := store.UpdateCatLastUpdateAt(ctx, repository.UpdateCatLastUpdateAtParams{
		ID:           catID,
		LastUpdateAt: pgtype.Timestamptz{Time: older, Valid: true},
	}); err != nil {
		t.Fatalf("update last_update_at with an older timestamp: %v", err)
	}

	cat, err = store.GetCatByID(ctx, catID)
	if err != nil {
		t.Fatalf("get cat: %v", err)
	}
	if !cat.LastUpdateAt.Valid || !cat.LastUpdateAt.Time.Equal(newer) {
		t.Errorf("expected last_update_at to stay at the newer value %v, got %v", newer, cat.LastUpdateAt.Time)
	}
}

// TestStore_CreateOrdinaryUpdate_PaginationRegression guards against the
// write path silently breaking the existing keyset-pagination contract on
// ListCatUpdates: a created ordinary update must take its correct
// newest-first position alongside pre-existing history, not just appear in
// an unpaginated read.
func TestStore_CreateOrdinaryUpdate_PaginationRegression(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "pagination regression")
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	createTestUpdate(t, ctx, store, catID, base, []string{"seen"}, "")

	newest := base.Add(time.Hour)
	row, err := store.CreateOrdinaryUpdate(ctx, repository.CreateOrdinaryUpdateParams{
		ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
		CatID:     catID,
		CreatedAt: pgtype.Timestamptz{Time: newest, Valid: true},
		Statuses:  []string{"water_provided"},
	})
	if err != nil {
		t.Fatalf("create ordinary update: %v", err)
	}

	firstPage, err := store.ListCatUpdates(ctx, repository.ListCatUpdatesParams{CatID: catID, RowLimit: 1})
	if err != nil {
		t.Fatalf("first page: %v", err)
	}
	if len(firstPage) != 1 || firstPage[0].ID != row.ID {
		t.Fatalf("expected the newly created update first on page 1, got %+v", firstPage)
	}

	secondPage, err := store.ListCatUpdates(ctx, repository.ListCatUpdatesParams{
		CatID:           catID,
		RowLimit:        1,
		BeforeCreatedAt: firstPage[0].CreatedAt,
		BeforeSeq:       firstPage[0].Seq,
	})
	if err != nil {
		t.Fatalf("second page: %v", err)
	}
	if len(secondPage) != 1 || !secondPage[0].CreatedAt.Time.Equal(base) {
		t.Fatalf("expected the older pre-existing update second, got %+v", secondPage)
	}
}

func TestStore_GetCatByID_NoNeedsHelpUpdateIsNull(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "never needed help")

	row, err := store.GetCatByID(ctx, id)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if row.NeedsHelpCategory.Valid || row.NeedsHelpCreatedAt.Valid || row.NeedsHelpExpiresAt.Valid {
		t.Errorf("expected no needs-help fields for a cat with no needs-help update, got %+v", row)
	}
}
