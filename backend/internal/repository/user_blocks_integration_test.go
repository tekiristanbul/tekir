package repository_test

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// The block filter is sql, not Go — every one of these asserts against a real
// database that a blocked owner's cat is gone from one specific read surface.
// A missed surface is issue #234's most likely failure mode, so each is
// checked separately rather than through one representative query.

func TestStore_Blocks_AreIdempotent(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	blocker := createTestUser(t, ctx, store)
	blocked := createTestUser(t, ctx, store)
	arg := repository.CreateBlockParams{BlockerUserID: blocker, BlockedUserID: blocked}

	for i := 0; i < 2; i++ {
		if err := store.CreateBlock(ctx, arg); err != nil {
			t.Fatalf("create block (attempt %d): %v", i+1, err)
		}
	}

	rows, err := store.ListBlockedAccounts(ctx, blocker)
	if err != nil {
		t.Fatalf("list blocked: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected exactly one block row, got %d", len(rows))
	}

	// unblocking twice is fine too — the second delete removes nothing.
	del := repository.DeleteBlockParams{BlockerUserID: blocker, BlockedUserID: blocked}
	for i := 0; i < 2; i++ {
		if err := store.DeleteBlock(ctx, del); err != nil {
			t.Fatalf("delete block (attempt %d): %v", i+1, err)
		}
	}
	rows, err = store.ListBlockedAccounts(ctx, blocker)
	if err != nil {
		t.Fatalf("list blocked after delete: %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("expected no block rows after unblock, got %d", len(rows))
	}
}

func TestStore_CreateBlock_RejectsSelfBlock(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	self := createTestUser(t, ctx, store)
	err := store.CreateBlock(ctx, repository.CreateBlockParams{BlockerUserID: self, BlockedUserID: self})
	if err == nil {
		t.Fatal("expected the check constraint to reject a self-block")
	}
}

func TestStore_BlockHidesOwnersCatFromEveryReadSurface(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	owner := createTestUser(t, ctx, store)
	viewer := createTestUser(t, ctx, store)

	// A coordinate of its own, and a different one on every run. Two things
	// would otherwise page this cat out of a distance-ordered read before the
	// keyset limit: the shared fixture point every other integration test
	// upserts at (41.0256/28.9744, thousands of cats deep in a long-lived
	// database), and this test's own earlier runs piling up on a fixed point
	// of its own. Jittering by the owner's uuid keeps each run's cat the
	// nearest one by construction, which is what makes the assertions below
	// about *this* cat mean anything.
	lat := 41.05 + float64(owner.Bytes[0])/255*0.05
	lng := 29.00 + float64(owner.Bytes[1])/255*0.05
	created, err := store.CreateCatWithMedia(ctx, newCreateCatWithMediaParams(owner, lat, lng, pgtype.Text{}))
	if err != nil {
		t.Fatalf("create cat: %v", err)
	}
	catID := created.Cat.ID

	bounds := repository.ListCatsInBoundsParams{MinLat: lat - 0.001, MinLng: lng - 0.001, MaxLat: lat + 0.001, MaxLng: lng + 0.001}
	nearby := repository.ListNearbyCatsForDuplicateCheckParams{Lat: lat, Lng: lng, RadiusM: 300}
	discover := repository.ListCatsByDistanceParams{Lat: lat, Lng: lng, RowLimit: 25}

	containsCat := func(t *testing.T, ids []pgtype.UUID) bool {
		t.Helper()
		for _, id := range ids {
			if id == catID {
				return true
			}
		}
		return false
	}

	mapIDs := func(t *testing.T, viewerID pgtype.UUID) []pgtype.UUID {
		t.Helper()
		arg := bounds
		arg.ViewerUserID = viewerID
		rows, err := store.ListCatsInBounds(ctx, arg)
		if err != nil {
			t.Fatalf("list in bounds: %v", err)
		}
		out := make([]pgtype.UUID, 0, len(rows))
		for _, r := range rows {
			out = append(out, r.ID)
		}
		return out
	}
	duplicateIDs := func(t *testing.T, viewerID pgtype.UUID) []pgtype.UUID {
		t.Helper()
		arg := nearby
		arg.ViewerUserID = viewerID
		rows, err := store.ListNearbyCatsForDuplicateCheck(ctx, arg)
		if err != nil {
			t.Fatalf("list duplicates: %v", err)
		}
		out := make([]pgtype.UUID, 0, len(rows))
		for _, r := range rows {
			out = append(out, r.ID)
		}
		return out
	}
	discoverIDs := func(t *testing.T, viewerID pgtype.UUID) []pgtype.UUID {
		t.Helper()
		arg := discover
		arg.ViewerUserID = viewerID
		rows, err := store.ListCatsByDistance(ctx, arg)
		if err != nil {
			t.Fatalf("list by distance: %v", err)
		}
		out := make([]pgtype.UUID, 0, len(rows))
		for _, r := range rows {
			out = append(out, r.ID)
		}
		return out
	}

	// before the block, the viewer sees the cat everywhere.
	if !containsCat(t, mapIDs(t, viewer)) {
		t.Fatal("map: expected the cat before blocking")
	}
	if !containsCat(t, duplicateIDs(t, viewer)) {
		t.Fatal("duplicates: expected the cat before blocking")
	}
	if !containsCat(t, discoverIDs(t, viewer)) {
		t.Fatal("discover: expected the cat before blocking")
	}
	if _, err := store.GetCatByID(ctx, repository.GetCatByIDParams{ID: catID, ViewerUserID: viewer}); err != nil {
		t.Fatalf("detail before blocking: %v", err)
	}

	if err := store.CreateBlock(ctx, repository.CreateBlockParams{BlockerUserID: viewer, BlockedUserID: owner}); err != nil {
		t.Fatalf("create block: %v", err)
	}

	if containsCat(t, mapIDs(t, viewer)) {
		t.Error("map: cat still visible after blocking its owner")
	}
	if containsCat(t, duplicateIDs(t, viewer)) {
		t.Error("duplicates: cat still offered after blocking its owner")
	}
	if containsCat(t, discoverIDs(t, viewer)) {
		t.Error("discover: cat still listed after blocking its owner")
	}

	// detail answers exactly like an unknown id, not with a distinguishable
	// "blocked" error — that indistinguishability is the point.
	if _, err := store.GetCatByID(ctx, repository.GetCatByIDParams{ID: catID, ViewerUserID: viewer}); !errorsIsNoRows(err) {
		t.Errorf("detail: expected no rows after blocking, got %v", err)
	}
	exists, err := store.CatExists(ctx, repository.CatExistsParams{ID: catID, ViewerUserID: viewer})
	if err != nil {
		t.Fatalf("cat exists: %v", err)
	}
	if exists {
		t.Error("existence gate: cat still exists for a viewer who blocks its owner")
	}

	// everyone else is unaffected — blocking hides, it never deletes.
	if !containsCat(t, mapIDs(t, pgtype.UUID{})) {
		t.Error("map: a guest lost a cat they never blocked")
	}
	other := createTestUser(t, ctx, store)
	if !containsCat(t, mapIDs(t, other)) {
		t.Error("map: an unrelated account lost a cat they never blocked")
	}
	// and the block is directional: the owner still sees their own cat.
	if !containsCat(t, mapIDs(t, owner)) {
		t.Error("map: the owner lost their own cat to someone else's block")
	}

	// unblocking restores every surface.
	if err := store.DeleteBlock(ctx, repository.DeleteBlockParams{BlockerUserID: viewer, BlockedUserID: owner}); err != nil {
		t.Fatalf("delete block: %v", err)
	}
	if !containsCat(t, mapIDs(t, viewer)) {
		t.Error("map: cat did not come back after unblocking")
	}
	if _, err := store.GetCatByID(ctx, repository.GetCatByIDParams{ID: catID, ViewerUserID: viewer}); err != nil {
		t.Errorf("detail did not come back after unblocking: %v", err)
	}
}

func TestStore_BlockRemovesFollowedCatButKeepsTheFollow(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	owner := createTestUser(t, ctx, store)
	follower := createTestUser(t, ctx, store)

	created, err := store.CreateCatWithMedia(ctx, newCreateCatWithMediaParams(owner, 41.0805, 29.0575, pgtype.Text{}))
	if err != nil {
		t.Fatalf("create cat: %v", err)
	}
	catID := created.Cat.ID

	if err := store.CreateFollow(ctx, repository.CreateFollowParams{
		CatID:  catID,
		UserID: follower,
	}); err != nil {
		t.Fatalf("create follow: %v", err)
	}

	followed, err := store.ListFollowedCats(ctx, follower)
	if err != nil {
		t.Fatalf("list followed: %v", err)
	}
	if len(followed) != 1 {
		t.Fatalf("expected the followed cat before blocking, got %d rows", len(followed))
	}

	if err := store.CreateBlock(ctx, repository.CreateBlockParams{BlockerUserID: follower, BlockedUserID: owner}); err != nil {
		t.Fatalf("create block: %v", err)
	}

	followed, err = store.ListFollowedCats(ctx, follower)
	if err != nil {
		t.Fatalf("list followed after block: %v", err)
	}
	if len(followed) != 0 {
		t.Fatalf("expected the followed cat to disappear, got %d rows", len(followed))
	}

	// the follow row itself survives, so unblocking restores the list without
	// the user having to follow again.
	if err := store.DeleteBlock(ctx, repository.DeleteBlockParams{BlockerUserID: follower, BlockedUserID: owner}); err != nil {
		t.Fatalf("delete block: %v", err)
	}
	followed, err = store.ListFollowedCats(ctx, follower)
	if err != nil {
		t.Fatalf("list followed after unblock: %v", err)
	}
	if len(followed) != 1 {
		t.Fatalf("expected the followed cat to come back, got %d rows", len(followed))
	}
}

func errorsIsNoRows(err error) bool {
	return err == pgx.ErrNoRows || (err != nil && err.Error() == pgx.ErrNoRows.Error())
}
