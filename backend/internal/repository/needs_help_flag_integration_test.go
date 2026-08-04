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

// issue #101: the combined flag model's repository-level behavior — legacy
// category interpretation, active-alert derivation input, clearing, and the
// worker's notification-suppression signal.

// createHelpMark writes a post-#101 combined-model help mark (no category)
// with the given creation time, statuses optional.
func createHelpMark(t *testing.T, ctx context.Context, store *repository.Store, catID, userID pgtype.UUID, createdAt time.Time, statuses []string) pgtype.UUID {
	t.Helper()
	id := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.CreateOrdinaryUpdate(ctx, repository.CreateOrdinaryUpdateParams{
		ID:                 id,
		CatID:              catID,
		AuthorUserID:       userID,
		CreatedAt:          pgtype.Timestamptz{Time: createdAt, Valid: true},
		Statuses:           statuses,
		NeedsHelp:          true,
		NeedsHelpExpiresAt: pgtype.Timestamptz{Time: createdAt.Add(72 * time.Hour), Valid: true},
	}); err != nil {
		t.Fatalf("create help mark: %v", err)
	}
	return id
}

// TestStore_EveryLegacyCategorySurvivesAndServes seeds one legacy-shape row
// per 0.1 category (exactly what migration 00022's backfill produces) and
// proves each remains stored and interpretable through the active-alert
// lateral — the "migration test with every legacy category" evidence at
// the read-path level.
func TestStore_EveryLegacyCategorySurvivesAndServes(t *testing.T) {
	store := newTestStore(t)
	pool := rawPool(t)
	ctx := context.Background()

	categories := []string{"injured_or_sick", "food_needed", "water_needed", "unsafe_location", "trapped"}
	for _, category := range categories {
		catID := upsertTestCat(t, ctx, store, "legacy category "+category)
		createdAt := time.Now().Add(-time.Hour)
		if _, err := store.CreateUpdate(ctx, repository.CreateUpdateParams{
			ID:                 pgtype.UUID{Bytes: uuid.New(), Valid: true},
			CatID:              catID,
			Kind:               "needs_help",
			NeedsHelp:          true,
			CreatedAt:          pgtype.Timestamptz{Time: createdAt, Valid: true},
			NeedsHelpCategory:  pgtype.Text{String: category, Valid: true},
			NeedsHelpExpiresAt: pgtype.Timestamptz{Time: createdAt.Add(72 * time.Hour), Valid: true},
		}); err != nil {
			t.Fatalf("seed legacy %s row: %v", category, err)
		}

		row, err := store.GetCatByID(ctx, catID)
		if err != nil {
			t.Fatalf("get cat: %v", err)
		}
		if !row.NeedsHelpCategory.Valid || row.NeedsHelpCategory.String != category {
			t.Errorf("expected the lateral to serve stored category %q, got %v", category, row.NeedsHelpCategory)
		}
		if !row.NeedsHelpExpiresAt.Valid {
			t.Errorf("expected the lateral to serve the %s row's expiry", category)
		}

		var stored string
		if err := pool.QueryRow(ctx, "select needs_help_category from updates where cat_id = $1", catID).Scan(&stored); err != nil {
			t.Fatalf("read back stored category: %v", err)
		}
		if stored != category {
			t.Errorf("expected the stored category untouched, got %q", stored)
		}
	}
}

// TestStore_ActiveAlertLateral_FlagRowAndDeletedFallback proves the lateral
// keys on the flag (a category-less combined row is an alert source), skips
// soft-deleted marks, and serves the mark's comment as the note.
func TestStore_ActiveAlertLateral_FlagRowAndDeletedFallback(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "flag lateral cat")
	userID := createTestUser(t, ctx, store)

	// postgres stores timestamptz at microsecond precision — truncate so
	// read-back equality holds.
	older := time.Now().Truncate(time.Microsecond).Add(-2 * time.Hour)
	newer := time.Now().Truncate(time.Microsecond).Add(-time.Hour)
	createHelpMark(t, ctx, store, catID, userID, older, nil)
	note := "akşam biri daha bakabilir mi?"
	newerID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.CreateOrdinaryUpdate(ctx, repository.CreateOrdinaryUpdateParams{
		ID:                 newerID,
		CatID:              catID,
		AuthorUserID:       userID,
		Comment:            pgtype.Text{String: note, Valid: true},
		CreatedAt:          pgtype.Timestamptz{Time: newer, Valid: true},
		Statuses:           []string{"water_provided"},
		NeedsHelp:          true,
		NeedsHelpExpiresAt: pgtype.Timestamptz{Time: newer.Add(72 * time.Hour), Valid: true},
	}); err != nil {
		t.Fatalf("create newer mark: %v", err)
	}

	row, err := store.GetCatByID(ctx, catID)
	if err != nil {
		t.Fatalf("get cat: %v", err)
	}
	if row.NeedsHelpCategory.Valid {
		t.Errorf("expected no category on a combined-model mark, got %v", row.NeedsHelpCategory)
	}
	if !row.NeedsHelpComment.Valid || row.NeedsHelpComment.String != note {
		t.Errorf("expected the newer mark's note, got %v", row.NeedsHelpComment)
	}
	if !row.NeedsHelpCreatedAt.Time.Equal(newer) {
		t.Errorf("expected the newer mark to be the alert source, got %v", row.NeedsHelpCreatedAt.Time)
	}

	// soft-delete the newer mark: the lateral must fall back to the older,
	// still-active one instead of keeping a deleted mark visible.
	if _, err := store.DeleteOwnUpdate(ctx, repository.DeleteOwnUpdateParams{
		ID:           newerID,
		CatID:        catID,
		AuthorUserID: userID,
		DeletedAt:    pgtype.Timestamptz{Time: time.Now(), Valid: true},
		WindowStart:  pgtype.Timestamptz{Time: newer.Add(-time.Minute), Valid: true},
	}); err != nil {
		t.Fatalf("delete newer mark: %v", err)
	}
	row, err = store.GetCatByID(ctx, catID)
	if err != nil {
		t.Fatalf("get cat after delete: %v", err)
	}
	if !row.NeedsHelpCreatedAt.Time.Equal(older) {
		t.Errorf("expected fallback to the older mark after deletion, got %v", row.NeedsHelpCreatedAt.Time)
	}
}

// TestStore_CorrectOwnUpdate_ClearNeedsHelp proves clearing nulls the whole
// help aspect atomically (flag, expiry, compat category) and that the
// post-state invariant blocks a clear that would leave a husk.
func TestStore_CorrectOwnUpdate_ClearNeedsHelp(t *testing.T) {
	store := newTestStore(t)
	pool := rawPool(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "clear help cat")
	userID := createTestUser(t, ctx, store)
	createdAt := time.Now()
	markID := createHelpMark(t, ctx, store, catID, userID, createdAt, []string{"seen"})

	row, err := store.CorrectOwnUpdate(ctx, repository.CorrectOwnUpdateParams{
		ID:              markID,
		CatID:           catID,
		AuthorUserID:    userID,
		UpdatedAt:       pgtype.Timestamptz{Time: createdAt.Add(time.Minute), Valid: true},
		WindowStart:     pgtype.Timestamptz{Time: createdAt.Add(time.Minute).Add(-10 * time.Minute), Valid: true},
		ReplaceStatuses: true,
		Statuses:        []string{"seen"},
		ClearNeedsHelp:  true,
	})
	if err != nil {
		t.Fatalf("clear help mark: %v", err)
	}
	if row.NeedsHelp {
		t.Error("expected the returning row to show the flag cleared")
	}

	var needsHelp bool
	var category pgtype.Text
	var expiresAt pgtype.Timestamptz
	if err := pool.QueryRow(ctx, "select needs_help, needs_help_category, needs_help_expires_at from updates where id = $1", markID).
		Scan(&needsHelp, &category, &expiresAt); err != nil {
		t.Fatalf("read back cleared row: %v", err)
	}
	if needsHelp || category.Valid || expiresAt.Valid {
		t.Errorf("expected flag/category/expiry all cleared, got %v/%v/%v", needsHelp, category, expiresAt)
	}

	// the cleared mark must no longer surface as an active alert.
	catRow, err := store.GetCatByID(ctx, catID)
	if err != nil {
		t.Fatalf("get cat: %v", err)
	}
	if catRow.NeedsHelpExpiresAt.Valid {
		t.Errorf("expected no alert source after clearing, got %v", catRow.NeedsHelpExpiresAt)
	}

	// husk guard: a help-only mark cannot be cleared into nothing.
	helpOnly := createHelpMark(t, ctx, store, catID, userID, createdAt, nil)
	_, err = store.CorrectOwnUpdate(ctx, repository.CorrectOwnUpdateParams{
		ID:             helpOnly,
		CatID:          catID,
		AuthorUserID:   userID,
		UpdatedAt:      pgtype.Timestamptz{Time: createdAt.Add(time.Minute), Valid: true},
		WindowStart:    pgtype.Timestamptz{Time: createdAt.Add(time.Minute).Add(-10 * time.Minute), Valid: true},
		ClearNeedsHelp: true,
	})
	if !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("expected the post-state invariant to affect zero rows, got %v", err)
	}
}

// TestStore_CorrectOwnUpdate_PartialPatchPreserves (issue #105) proves the
// presence-aware statement: a patch carrying only the clear leaves the
// combined update's statuses and comment untouched (and returns them so
// the response can echo them), and a comment-only patch likewise preserves
// the statuses.
func TestStore_CorrectOwnUpdate_PartialPatchPreserves(t *testing.T) {
	store := newTestStore(t)
	pool := rawPool(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "partial patch cat")
	userID := createTestUser(t, ctx, store)
	createdAt := time.Now()
	note := "çeşmenin orada, su kabı boş"
	markID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.CreateOrdinaryUpdate(ctx, repository.CreateOrdinaryUpdateParams{
		ID:                 markID,
		CatID:              catID,
		AuthorUserID:       userID,
		Comment:            pgtype.Text{String: note, Valid: true},
		CreatedAt:          pgtype.Timestamptz{Time: createdAt, Valid: true},
		Statuses:           []string{"seen", "water_provided"},
		NeedsHelp:          true,
		NeedsHelpExpiresAt: pgtype.Timestamptz{Time: createdAt.Add(72 * time.Hour), Valid: true},
	}); err != nil {
		t.Fatalf("create combined update: %v", err)
	}

	// clear-only patch: no ReplaceStatuses, no SetComment.
	row, err := store.CorrectOwnUpdate(ctx, repository.CorrectOwnUpdateParams{
		ID:             markID,
		CatID:          catID,
		AuthorUserID:   userID,
		UpdatedAt:      pgtype.Timestamptz{Time: createdAt.Add(time.Minute), Valid: true},
		WindowStart:    pgtype.Timestamptz{Time: createdAt.Add(-time.Minute), Valid: true},
		ClearNeedsHelp: true,
	})
	if err != nil {
		t.Fatalf("clear-only patch: %v", err)
	}
	if row.NeedsHelp {
		t.Error("expected the flag cleared")
	}
	if len(row.Statuses) != 2 || row.Statuses[0] != "seen" || row.Statuses[1] != "water_provided" {
		t.Errorf("expected preserved statuses [seen water_provided] returned, got %v", row.Statuses)
	}
	if !row.Comment.Valid || row.Comment.String != note {
		t.Errorf("expected preserved comment returned, got %v", row.Comment)
	}
	var statusCount int
	if err := pool.QueryRow(ctx, "select count(*) from update_statuses where update_id = $1", markID).Scan(&statusCount); err != nil {
		t.Fatalf("count statuses: %v", err)
	}
	if statusCount != 2 {
		t.Errorf("expected both status rows to survive the clear-only patch, got %d", statusCount)
	}

	// comment-only patch: statuses still untouched.
	newNote := "düzeltildi"
	row, err = store.CorrectOwnUpdate(ctx, repository.CorrectOwnUpdateParams{
		ID:           markID,
		CatID:        catID,
		AuthorUserID: userID,
		SetComment:   true,
		Comment:      pgtype.Text{String: newNote, Valid: true},
		UpdatedAt:    pgtype.Timestamptz{Time: createdAt.Add(2 * time.Minute), Valid: true},
		WindowStart:  pgtype.Timestamptz{Time: createdAt.Add(-time.Minute), Valid: true},
	})
	if err != nil {
		t.Fatalf("comment-only patch: %v", err)
	}
	if !row.Comment.Valid || row.Comment.String != newNote {
		t.Errorf("expected the replaced comment, got %v", row.Comment)
	}
	if len(row.Statuses) != 2 {
		t.Errorf("expected statuses preserved by a comment-only patch, got %v", row.Statuses)
	}
}

// TestStore_ClaimNotificationOutboxBatch_SuppressionSemantics proves the
// re-marking decision through the enqueue-frozen eligibility flag (issue
// #105): a mark made while another mark's 72h window was still open is
// ineligible; one made after every earlier mark expired is eligible.
func TestStore_ClaimNotificationOutboxBatch_SuppressionSemantics(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	drainNotificationOutbox(t, ctx, store)

	catID := upsertTestCat(t, ctx, store, "suppression cat")
	userID := createTestUser(t, ctx, store)

	// first mark long ago; second while the first was still active; third
	// after both had expired.
	first := time.Now().Add(-200 * time.Hour)
	second := first.Add(time.Hour)
	third := time.Now().Add(-time.Hour)
	firstID := createHelpMark(t, ctx, store, catID, userID, first, nil)
	secondID := createHelpMark(t, ctx, store, catID, userID, second, nil)
	thirdID := createHelpMark(t, ctx, store, catID, userID, third, nil)

	rows, err := store.ClaimNotificationOutboxBatch(ctx, 10)
	if err != nil {
		t.Fatalf("claim batch: %v", err)
	}
	claimed := map[pgtype.UUID]repository.ClaimNotificationOutboxBatchRow{}
	for _, r := range rows {
		claimed[r.UpdateID] = r
	}

	if row, ok := claimed[firstID]; !ok || !row.NeedsHelp || !row.NeedsHelpEligible {
		t.Errorf("first mark: expected fan-out (no suppression), got %+v", row)
	}
	if row, ok := claimed[secondID]; !ok || row.NeedsHelpEligible {
		t.Errorf("second mark: expected suppression while the first was active, got %+v", row)
	}
	if row, ok := claimed[thirdID]; !ok || !row.NeedsHelpEligible {
		t.Errorf("third mark: expected fan-out after earlier marks expired, got %+v", row)
	}
}

// TestStore_GetUpdateByIdempotencyKey_CarriesNeedsHelp proves an
// idempotent retry of a help-carrying POST resolves with the flag intact.
func TestStore_GetUpdateByIdempotencyKey_CarriesNeedsHelp(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "idempotent help cat")
	userID := createTestUser(t, ctx, store)
	createdAt := time.Now()
	key := uuid.NewString()
	if _, err := store.CreateOrdinaryUpdate(ctx, repository.CreateOrdinaryUpdateParams{
		ID:                 pgtype.UUID{Bytes: uuid.New(), Valid: true},
		CatID:              catID,
		AuthorUserID:       userID,
		CreatedAt:          pgtype.Timestamptz{Time: createdAt, Valid: true},
		Statuses:           []string{"fed"},
		IdempotencyKey:     pgtype.Text{String: key, Valid: true},
		NeedsHelp:          true,
		NeedsHelpExpiresAt: pgtype.Timestamptz{Time: createdAt.Add(72 * time.Hour), Valid: true},
	}); err != nil {
		t.Fatalf("create keyed help mark: %v", err)
	}

	row, err := store.GetUpdateByIdempotencyKey(ctx, repository.GetUpdateByIdempotencyKeyParams{
		AuthorUserID:   userID,
		IdempotencyKey: pgtype.Text{String: key, Valid: true},
	})
	if err != nil {
		t.Fatalf("resolve idempotency key: %v", err)
	}
	if !row.NeedsHelp || !row.NeedsHelpExpiresAt.Valid {
		t.Errorf("expected the retry row to carry the help flag and expiry, got %+v", row)
	}
}
