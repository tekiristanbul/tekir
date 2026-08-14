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

// TestStore_CreateReport_EachTargetType writes a report against each of the
// three reportable surfaces (issue #233: cat, update, media) and checks the
// row lands with status 'open' and the submitted reason/note.
func TestStore_CreateReport_EachTargetType(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "report target cat")
	reporterID := createTestUser(t, ctx, store)
	mediaID := createTestMedia(t, ctx, store, reporterID)

	updateID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.CreateUpdate(ctx, repository.CreateUpdateParams{
		ID:        updateID,
		CatID:     catID,
		Kind:      "ordinary",
		CreatedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}); err != nil {
		t.Fatalf("create update: %v", err)
	}

	targets := []struct {
		targetType string
		targetID   pgtype.UUID
	}{
		{"cat", catID},
		{"update", updateID},
		{"media", mediaID},
	}

	for _, tc := range targets {
		t.Run(tc.targetType, func(t *testing.T) {
			row, err := store.CreateReport(ctx, repository.CreateReportParams{
				ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
				ReporterUserID: reporterID,
				TargetType:     tc.targetType,
				TargetID:       tc.targetID,
				Reason:         "spam",
			})
			if err != nil {
				t.Fatalf("create report: %v", err)
			}
			if row.Status != "open" {
				t.Errorf("expected status open, got %q", row.Status)
			}
			if row.Reason != "spam" {
				t.Errorf("expected reason spam, got %q", row.Reason)
			}
			if row.Note.Valid {
				t.Errorf("expected no note, got %q", row.Note.String)
			}
		})
	}
}

// TestStore_CreateReport_DuplicateReporterAndTargetIsIdempotent exercises
// reports_reporter_target_open_uq (migration 00027): a second report from
// the same account against the same still-open target returns no row
// (pgx.ErrNoRows) rather than a duplicate active report, and
// GetOpenReportByReporterAndTarget resolves back to the original.
func TestStore_CreateReport_DuplicateReporterAndTargetIsIdempotent(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "duplicate report target")
	reporterID := createTestUser(t, ctx, store)

	first, err := store.CreateReport(ctx, repository.CreateReportParams{
		ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
		ReporterUserID: reporterID,
		TargetType:     "cat",
		TargetID:       catID,
		Reason:         "inappropriate",
	})
	if err != nil {
		t.Fatalf("create first report: %v", err)
	}

	_, err = store.CreateReport(ctx, repository.CreateReportParams{
		ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
		ReporterUserID: reporterID,
		TargetType:     "cat",
		TargetID:       catID,
		Reason:         "spam",
	})
	if !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("expected pgx.ErrNoRows on duplicate, got %v", err)
	}

	existing, err := store.GetOpenReportByReporterAndTarget(ctx, repository.GetOpenReportByReporterAndTargetParams{
		ReporterUserID: reporterID,
		TargetType:     "cat",
		TargetID:       catID,
	})
	if err != nil {
		t.Fatalf("get open report: %v", err)
	}
	if existing.ID != first.ID {
		t.Errorf("expected existing report %v, got %v", first.ID, existing.ID)
	}
	if existing.Reason != "inappropriate" {
		t.Errorf("expected the original reason to survive, got %q", existing.Reason)
	}

	// a different reporter against the same target is a distinct report,
	// not a conflict.
	otherReporter := createTestUser(t, ctx, store)
	if _, err := store.CreateReport(ctx, repository.CreateReportParams{
		ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
		ReporterUserID: otherReporter,
		TargetType:     "cat",
		TargetID:       catID,
		Reason:         "spam",
	}); err != nil {
		t.Fatalf("create report from a different reporter: %v", err)
	}
}

// TestStore_CreateReport_OtherReasonRequiresNote exercises the
// reports_other_requires_note_ck check constraint directly at the database
// layer — the service also validates this before ever writing (see
// service.ReportsService.Create), but the constraint is the last line of
// defense against any other write path.
func TestStore_CreateReport_OtherReasonRequiresNote(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "other-reason target")
	reporterID := createTestUser(t, ctx, store)

	_, err := store.CreateReport(ctx, repository.CreateReportParams{
		ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
		ReporterUserID: reporterID,
		TargetType:     "cat",
		TargetID:       catID,
		Reason:         "other",
	})
	if !isCheckViolation(err) {
		t.Fatalf("expected a check-constraint violation for a note-less 'other' reason, got %v", err)
	}

	if _, err := store.CreateReport(ctx, repository.CreateReportParams{
		ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
		ReporterUserID: reporterID,
		TargetType:     "cat",
		TargetID:       catID,
		Reason:         "other",
		Note:           pgtype.Text{String: "plaka görünüyor", Valid: true},
	}); err != nil {
		t.Fatalf("create report with note: %v", err)
	}
}

// TestStore_CatExists_ExcludesSoftDeletedCat and TestStore_UpdateExists_*
// back service.ReportsService's target-existence checks (issue #233): a
// soft-deleted cat/update must read as not reportable, exactly like every
// other write path already excludes it.
func TestStore_UpdateExists(t *testing.T) {
	store := newTestStore(t)
	pool := rawPool(t)
	ctx := context.Background()

	catID := upsertTestCat(t, ctx, store, "update-exists target")
	updateID := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	if _, err := store.CreateUpdate(ctx, repository.CreateUpdateParams{
		ID:        updateID,
		CatID:     catID,
		Kind:      "ordinary",
		CreatedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
	}); err != nil {
		t.Fatalf("create update: %v", err)
	}

	exists, err := store.UpdateExists(ctx, updateID)
	if err != nil {
		t.Fatalf("update exists: %v", err)
	}
	if !exists {
		t.Errorf("expected a live update to exist")
	}

	if _, err := pool.Exec(ctx, "update updates set deleted_at = now() where id = $1", updateID); err != nil {
		t.Fatalf("soft delete update: %v", err)
	}

	exists, err = store.UpdateExists(ctx, updateID)
	if err != nil {
		t.Fatalf("update exists after delete: %v", err)
	}
	if exists {
		t.Errorf("expected a soft-deleted update to no longer exist")
	}

	missing, err := store.UpdateExists(ctx, pgtype.UUID{Bytes: uuid.New(), Valid: true})
	if err != nil {
		t.Fatalf("update exists for unknown id: %v", err)
	}
	if missing {
		t.Errorf("expected an unknown update id to not exist")
	}
}
