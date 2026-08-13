package repository_test

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// requires a real, migrated database: run `make migrate-up` against the
// docker-compose postgres first, or let CI's postgres service do it.
func TestStore_ListCatsInBounds(t *testing.T) {
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

	// galata tower, istanbul.
	const centerLat, centerLng = 41.0256, 28.9744

	insideID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.UpsertCat(ctx, repository.UpsertCatParams{
		ID:           insideID,
		Name:         pgtype.Text{String: "inside cat", Valid: true},
		Lng:          centerLng,
		Lat:          centerLat,
		AreaLabel:    pgtype.Text{String: "Galata Kulesi çevresi, Beyoğlu", Valid: true},
		PhotoUrl:     pgtype.Text{String: "https://placecats.com/millie/300/200", Valid: true},
		Status:       "active",
		LastUpdateAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}); err != nil {
		t.Fatalf("upsert inside cat: %v", err)
	}

	// kadıköy, across the strait — well outside the galata bbox below.
	outsideID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.UpsertCat(ctx, repository.UpsertCatParams{
		ID:           outsideID,
		Name:         pgtype.Text{String: "outside cat", Valid: true},
		Lng:          29.0269,
		Lat:          40.9911,
		PhotoUrl:     pgtype.Text{String: "https://placecats.com/neo/300/200", Valid: true},
		Status:       "active",
		LastUpdateAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}); err != nil {
		t.Fatalf("upsert outside cat: %v", err)
	}

	// inactive cat inside the bbox: must not appear on the map.
	inactiveID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.UpsertCat(ctx, repository.UpsertCatParams{
		ID:           inactiveID,
		Name:         pgtype.Text{String: "inactive cat", Valid: true},
		Lng:          centerLng,
		Lat:          centerLat,
		PhotoUrl:     pgtype.Text{String: "https://placecats.com/bella/300/200", Valid: true},
		Status:       "inactive",
		LastUpdateAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}); err != nil {
		t.Fatalf("upsert inactive cat: %v", err)
	}

	rows, err := store.ListCatsInBounds(ctx, repository.ListCatsInBoundsParams{
		MinLng: 28.9700,
		MinLat: 41.0200,
		MaxLng: 28.9800,
		MaxLat: 41.0300,
	})
	if err != nil {
		t.Fatalf("list: %v", err)
	}

	seen := make(map[pgtype.UUID]bool, len(rows))
	byID := make(map[pgtype.UUID]repository.ListCatsInBoundsRow, len(rows))
	for _, r := range rows {
		seen[r.ID] = true
		byID[r.ID] = r
	}

	if !seen[insideID] {
		t.Error("expected cat inside the bounds to be returned")
	}
	if row, ok := byID[insideID]; ok {
		if row.Name.String != "inside cat" {
			t.Errorf("expected name %q, got %q", "inside cat", row.Name.String)
		}
		if !row.AreaLabel.Valid || row.AreaLabel.String != "Galata Kulesi çevresi, Beyoğlu" {
			t.Errorf("unexpected area_label: %v", row.AreaLabel)
		}
	}
	if seen[outsideID] {
		t.Error("expected cat outside the bounds not to be returned")
	}
	if seen[inactiveID] {
		t.Error("expected inactive cat inside the bounds not to be returned")
	}
}

// newCreateCatWithMediaParams builds a minimal, valid CreateCatWithMediaParams
// for userID at (lat, lng), so issue #70's CreateCatWithMedia tests don't
// each repeat the same boilerplate.
func newCreateCatWithMediaParams(userID pgtype.UUID, lat, lng float64, idempotencyKey pgtype.Text) repository.CreateCatWithMediaParams {
	return repository.CreateCatWithMediaParams{
		Media: repository.CreateMediaParams{
			ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}, ObjectKey: uuid.NewString() + ".jpg",
			Url: "/v1/media/objects/" + uuid.NewString() + ".jpg", ContentType: "image/jpeg", ByteSize: 100,
			UploadedByUserID: userID,
		},
		Cat: repository.CreateCatParams{
			ID: pgtype.UUID{Bytes: uuid.New(), Valid: true}, Lat: lat, Lng: lng,
			CreatedByUserID: userID, IdempotencyKey: idempotencyKey,
		},
	}
}

func TestStore_CreateCatWithMedia_Success(t *testing.T) {
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
	result, err := store.CreateCatWithMedia(ctx, newCreateCatWithMediaParams(userID, 41.03, 28.98, pgtype.Text{}))
	if err != nil {
		t.Fatalf("CreateCatWithMedia: %v", err)
	}
	if result.Cat.PrimaryPhotoID != result.Media.ID {
		t.Errorf("expected the cat's primary_photo_id to reference the just-created media row, got cat=%v media=%v", result.Cat.PrimaryPhotoID, result.Media.ID)
	}

	// the coalesce(photo_url, media.url) read path (issue #70) must resolve
	// the new cat's photo through the media join, exactly like a seeded
	// photo_url-only cat.
	detail, err := store.GetCatByID(ctx, result.Cat.ID)
	if err != nil {
		t.Fatalf("GetCatByID: %v", err)
	}
	if detail.PhotoUrl != result.Media.Url {
		t.Errorf("expected GetCatByID's photo_url %q to resolve to the media row's url %q", detail.PhotoUrl, result.Media.Url)
	}
}

// TestStore_CreateCatWithMedia_ArchivesCoverPhoto covers issue #121: the
// cover photo CreateCatWithMedia inserts must also land in cat_media, so
// CountCatMedia/ListCatMedia see it as the cat's first archive entry
// without any separate write.
func TestStore_CreateCatWithMedia_ArchivesCoverPhoto(t *testing.T) {
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
	result, err := store.CreateCatWithMedia(ctx, newCreateCatWithMediaParams(userID, 41.03, 28.98, pgtype.Text{}))
	if err != nil {
		t.Fatalf("CreateCatWithMedia: %v", err)
	}

	count, err := store.CountCatMedia(ctx, result.Cat.ID)
	if err != nil {
		t.Fatalf("CountCatMedia: %v", err)
	}
	if count != 1 {
		t.Fatalf("expected media_count 1, got %d", count)
	}

	rows, err := store.ListCatMedia(ctx, result.Cat.ID)
	if err != nil {
		t.Fatalf("ListCatMedia: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 archive row, got %d", len(rows))
	}
	if rows[0].MediaID != result.Media.ID {
		t.Errorf("expected archive entry to reference media %v, got %v", result.Media.ID, rows[0].MediaID)
	}
	if !rows[0].IsCover {
		t.Error("expected the cover photo's archive entry to be flagged is_cover")
	}
}

func TestStore_CreateCatWithMedia_IdempotencyUniqueIndex(t *testing.T) {
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
	key := pgtype.Text{String: "cat-integration-key-" + uuid.NewString(), Valid: true}

	first, err := store.CreateCatWithMedia(ctx, newCreateCatWithMediaParams(userID, 41.03, 28.98, key))
	if err != nil {
		t.Fatalf("first create: %v", err)
	}

	mediaCountBefore := countMediaRows(t, ctx, pool, userID)

	// A retry with the same (user, key) must not create a second cat — and,
	// since CreateCatWithMedia's whole transaction rolls back when CreateCat
	// itself returns no row, the media row this retry attempted to insert
	// must not survive either (issue #70: never an orphan media row no cat
	// references).
	_, err = store.CreateCatWithMedia(ctx, newCreateCatWithMediaParams(userID, 41.03, 28.98, key))
	if !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("expected pgx.ErrNoRows on the conflicting retry, got %v", err)
	}

	mediaCountAfter := countMediaRows(t, ctx, pool, userID)
	if mediaCountAfter != mediaCountBefore {
		t.Errorf("expected the retry's media insert to roll back (count unchanged at %d), got %d", mediaCountBefore, mediaCountAfter)
	}

	existing, err := store.GetCatByIdempotencyKey(ctx, repository.GetCatByIdempotencyKeyParams{
		CreatedByUserID: userID, IdempotencyKey: key,
	})
	if err != nil {
		t.Fatalf("get by idempotency key: %v", err)
	}
	if existing.ID != first.Cat.ID {
		t.Errorf("expected the original cat (%v), got %v", first.Cat.ID, existing.ID)
	}
}

func countMediaRows(t *testing.T, ctx context.Context, pool *pgxpool.Pool, userID pgtype.UUID) int {
	t.Helper()
	var count int
	if err := pool.QueryRow(ctx, "select count(*) from media where uploaded_by_user_id = $1", userID).Scan(&count); err != nil {
		t.Fatalf("count media rows: %v", err)
	}
	return count
}

func TestStore_CreateCatWithMedia_SameKeyDifferentUsersBothSucceed(t *testing.T) {
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
	key := pgtype.Text{String: "shared-cat-key-" + uuid.NewString(), Valid: true}

	resultA, err := store.CreateCatWithMedia(ctx, newCreateCatWithMediaParams(userA, 41.03, 28.98, key))
	if err != nil {
		t.Fatalf("create for user A: %v", err)
	}
	resultB, err := store.CreateCatWithMedia(ctx, newCreateCatWithMediaParams(userB, 41.03, 28.98, key))
	if err != nil {
		t.Fatalf("expected the same idempotency key to succeed for a different account, got %v", err)
	}
	if resultA.Cat.ID == resultB.Cat.ID {
		t.Error("expected two distinct cats, one per account — another account must never claim ownership through a shared idempotency key")
	}
}

func TestStore_ListNearbyCatsForDuplicateCheck(t *testing.T) {
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
	const centerLat, centerLng = 40.70, 29.20 // an area with no other seed/fixture cats nearby

	near, err := store.CreateCatWithMedia(ctx, newCreateCatWithMediaParams(userID, centerLat, centerLng, pgtype.Text{}))
	if err != nil {
		t.Fatalf("create near cat: %v", err)
	}
	// ~5.5km away — well outside the 50m duplicate-check radius.
	far, err := store.CreateCatWithMedia(ctx, newCreateCatWithMediaParams(userID, centerLat+0.05, centerLng, pgtype.Text{}))
	if err != nil {
		t.Fatalf("create far cat: %v", err)
	}
	inactiveNear, err := store.CreateCatWithMedia(ctx, newCreateCatWithMediaParams(userID, centerLat, centerLng+0.0001, pgtype.Text{}))
	if err != nil {
		t.Fatalf("create inactive-near cat: %v", err)
	}
	if _, err := pool.Exec(ctx, "update cats set status = 'inactive' where id = $1", inactiveNear.Cat.ID); err != nil {
		t.Fatalf("mark inactive: %v", err)
	}

	rows, err := store.ListNearbyCatsForDuplicateCheck(ctx, repository.ListNearbyCatsForDuplicateCheckParams{
		Lat: centerLat, Lng: centerLng, RadiusM: 50,
	})
	if err != nil {
		t.Fatalf("list: %v", err)
	}

	seen := make(map[pgtype.UUID]bool, len(rows))
	for _, r := range rows {
		seen[r.ID] = true
	}
	if !seen[near.Cat.ID] {
		t.Error("expected the cat within the radius to be returned")
	}
	if seen[far.Cat.ID] {
		t.Error("expected the cat outside the radius not to be returned")
	}
	if seen[inactiveNear.Cat.ID] {
		t.Error("expected an inactive cat within the radius not to be returned")
	}
}

// TestStore_SoftDeleteCat covers issue #200's terminal soft delete end to
// end against a real database: the owner's delete succeeds and is
// idempotent on retry, a non-owner's attempt affects zero rows, no row is
// ever physically removed (cats, its media, and its updates all survive),
// and the two read paths the issue names — GetCatByID (detail) and
// CatExists (the media/updates-history/write-path existence gate) — both
// stop seeing the cat once it's deleted.
func TestStore_SoftDeleteCat(t *testing.T) {
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

	ownerID := createTestUser(t, ctx, store)
	otherID := createTestUser(t, ctx, store)

	created, err := store.CreateCatWithMedia(ctx, newCreateCatWithMediaParams(ownerID, 40.98, 29.03, pgtype.Text{}))
	if err != nil {
		t.Fatalf("create cat: %v", err)
	}
	catID := created.Cat.ID

	// a non-owner's delete attempt must affect zero rows and leave the cat
	// exactly as it was.
	if _, err := store.SoftDeleteCat(ctx, repository.SoftDeleteCatParams{ID: catID, CreatedByUserID: otherID}); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("expected pgx.ErrNoRows for a non-owner delete, got %v", err)
	}
	stillActive, err := store.GetCatOwnershipForDelete(ctx, catID)
	if err != nil {
		t.Fatalf("get ownership after rejected delete: %v", err)
	}
	if stillActive.Status != "active" {
		t.Fatalf("expected status to remain active after a non-owner delete attempt, got %q", stillActive.Status)
	}

	// the owner's delete succeeds.
	deletedID, err := store.SoftDeleteCat(ctx, repository.SoftDeleteCatParams{ID: catID, CreatedByUserID: ownerID})
	if err != nil {
		t.Fatalf("owner delete: %v", err)
	}
	if deletedID != catID {
		t.Fatalf("expected SoftDeleteCat to return %v, got %v", catID, deletedID)
	}

	// no physical deletion: the row survives with status = 'deleted'.
	afterDelete, err := store.GetCatOwnershipForDelete(ctx, catID)
	if err != nil {
		t.Fatalf("get ownership after delete: %v", err)
	}
	if afterDelete.Status != "deleted" {
		t.Fatalf("expected status = deleted, got %q", afterDelete.Status)
	}
	if afterDelete.CreatedByUserID != ownerID {
		t.Fatalf("expected created_by_user_id to survive deletion unchanged")
	}
	var mediaCount, catMediaCount int
	if err := pool.QueryRow(ctx, "select count(*) from media where id = $1", created.Media.ID).Scan(&mediaCount); err != nil {
		t.Fatalf("count media: %v", err)
	}
	if mediaCount != 1 {
		t.Errorf("expected the cat's cover media row to survive deletion, found %d", mediaCount)
	}
	if err := pool.QueryRow(ctx, "select count(*) from cat_media where cat_id = $1", catID).Scan(&catMediaCount); err != nil {
		t.Fatalf("count cat_media: %v", err)
	}
	if catMediaCount != 1 {
		t.Errorf("expected the cat's cat_media archive row to survive deletion, found %d", catMediaCount)
	}

	// a repeated delete by the same owner is a safe no-op: zero rows
	// affected (nothing left to transition), never an error surfaced to
	// the caller by this query itself — CatsService.DeleteCat is what turns
	// this specific zero-rows outcome into a successful idempotent retry.
	if _, err := store.SoftDeleteCat(ctx, repository.SoftDeleteCatParams{ID: catID, CreatedByUserID: ownerID}); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("expected pgx.ErrNoRows on a repeated delete, got %v", err)
	}

	// the detail read (GetCatByID) and the shared existence gate (CatExists,
	// backing the media archive, updates history, and update-write paths)
	// both now treat the cat as not found.
	if _, err := store.GetCatByID(ctx, catID); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("expected GetCatByID to answer pgx.ErrNoRows for a deleted cat, got %v", err)
	}
	exists, err := store.CatExists(ctx, catID)
	if err != nil {
		t.Fatalf("cat exists: %v", err)
	}
	if exists {
		t.Error("expected CatExists to report false for a deleted cat")
	}
}
