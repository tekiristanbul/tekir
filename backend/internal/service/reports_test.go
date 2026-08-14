package service

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

type fakeReportsStore struct {
	catExists    bool
	catExistsErr error

	updateExists    bool
	updateExistsErr error

	mediaRow repository.Medium
	mediaErr error

	createRow repository.Report
	createErr error
	// captured, if non-nil, records the arg the last CreateReport call
	// received.
	captured *repository.CreateReportParams

	existingRow repository.Report
	existingErr error
}

func (f fakeReportsStore) CreateReport(_ context.Context, arg repository.CreateReportParams) (repository.Report, error) {
	if f.captured != nil {
		*f.captured = arg
	}
	return f.createRow, f.createErr
}

func (f fakeReportsStore) GetOpenReportByReporterAndTarget(_ context.Context, _ repository.GetOpenReportByReporterAndTargetParams) (repository.Report, error) {
	return f.existingRow, f.existingErr
}

func (f fakeReportsStore) CatExists(_ context.Context, _ pgtype.UUID) (bool, error) {
	return f.catExists, f.catExistsErr
}

func (f fakeReportsStore) UpdateExists(_ context.Context, _ pgtype.UUID) (bool, error) {
	return f.updateExists, f.updateExistsErr
}

func (f fakeReportsStore) GetMediaByID(_ context.Context, _ pgtype.UUID) (repository.Medium, error) {
	return f.mediaRow, f.mediaErr
}

func TestReportsService_Create_Success(t *testing.T) {
	reporterID := uuid.New()
	catID := uuid.New()
	reportID := uuid.New()

	var captured repository.CreateReportParams
	svc := NewReportsService(fakeReportsStore{
		catExists: true,
		createRow: repository.Report{
			ID:             pgtype.UUID{Bytes: reportID, Valid: true},
			ReporterUserID: pgtype.UUID{Bytes: reporterID, Valid: true},
			TargetType:     ReportTargetCat,
			TargetID:       pgtype.UUID{Bytes: catID, Valid: true},
			Reason:         "spam",
			Status:         "open",
		},
		captured: &captured,
	})

	report, err := svc.Create(context.Background(), reporterID.String(), ReportTargetCat, catID.String(), "spam", nil)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if report.ID != reportID.String() || report.Status != "open" || report.Reason != "spam" {
		t.Errorf("unexpected report: %+v", report)
	}
	if captured.ReporterUserID.Bytes != reporterID || captured.TargetID.Bytes != catID {
		t.Errorf("unexpected captured params: %+v", captured)
	}
	if captured.Note.Valid {
		t.Errorf("expected no note, got %+v", captured.Note)
	}
}

func TestReportsService_Create_EachTargetType(t *testing.T) {
	reporterID := uuid.New()
	targetID := uuid.New()

	for _, targetType := range []string{ReportTargetCat, ReportTargetUpdate, ReportTargetMedia} {
		t.Run(targetType, func(t *testing.T) {
			svc := NewReportsService(fakeReportsStore{
				catExists:    true,
				updateExists: true,
				mediaRow:     repository.Medium{ID: pgtype.UUID{Bytes: targetID, Valid: true}},
				createRow: repository.Report{
					ID:         pgtype.UUID{Bytes: uuid.New(), Valid: true},
					TargetType: targetType,
					TargetID:   pgtype.UUID{Bytes: targetID, Valid: true},
					Reason:     "inappropriate",
					Status:     "open",
				},
			})

			report, err := svc.Create(context.Background(), reporterID.String(), targetType, targetID.String(), "inappropriate", nil)
			if err != nil {
				t.Fatalf("expected no error for target type %s, got %v", targetType, err)
			}
			if report.TargetType != targetType {
				t.Errorf("expected target type %s, got %s", targetType, report.TargetType)
			}
		})
	}
}

func TestReportsService_Create_InvalidTargetType(t *testing.T) {
	svc := NewReportsService(fakeReportsStore{})
	_, err := svc.Create(context.Background(), uuid.New().String(), "colony", uuid.New().String(), "spam", nil)
	if !errors.Is(err, ErrInvalidReportTargetType) {
		t.Fatalf("expected ErrInvalidReportTargetType, got %v", err)
	}
}

func TestReportsService_Create_InvalidTargetID(t *testing.T) {
	svc := NewReportsService(fakeReportsStore{})
	_, err := svc.Create(context.Background(), uuid.New().String(), ReportTargetCat, "not-a-uuid", "spam", nil)
	if !errors.Is(err, ErrInvalidReportTargetID) {
		t.Fatalf("expected ErrInvalidReportTargetID, got %v", err)
	}
}

func TestReportsService_Create_InvalidReason(t *testing.T) {
	svc := NewReportsService(fakeReportsStore{catExists: true})
	_, err := svc.Create(context.Background(), uuid.New().String(), ReportTargetCat, uuid.New().String(), "because_i_said_so", nil)
	if !errors.Is(err, ErrInvalidReportReason) {
		t.Fatalf("expected ErrInvalidReportReason, got %v", err)
	}
}

func TestReportsService_Create_OtherRequiresNote(t *testing.T) {
	svc := NewReportsService(fakeReportsStore{catExists: true})

	_, err := svc.Create(context.Background(), uuid.New().String(), ReportTargetCat, uuid.New().String(), "other", nil)
	if !errors.Is(err, ErrReportNoteRequired) {
		t.Fatalf("expected ErrReportNoteRequired for nil note, got %v", err)
	}

	blank := "   "
	_, err = svc.Create(context.Background(), uuid.New().String(), ReportTargetCat, uuid.New().String(), "other", &blank)
	if !errors.Is(err, ErrReportNoteRequired) {
		t.Fatalf("expected ErrReportNoteRequired for blank note, got %v", err)
	}
}

func TestReportsService_Create_OtherWithNoteSucceeds(t *testing.T) {
	note := "  plaka görünüyor  "
	reportID := uuid.New()

	var captured repository.CreateReportParams
	svc := NewReportsService(fakeReportsStore{
		catExists: true,
		createRow: repository.Report{
			ID:     pgtype.UUID{Bytes: reportID, Valid: true},
			Reason: "other",
			Status: "open",
			Note:   pgtype.Text{String: "plaka görünüyor", Valid: true},
		},
		captured: &captured,
	})

	report, err := svc.Create(context.Background(), uuid.New().String(), ReportTargetCat, uuid.New().String(), "other", &note)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if report.Note == nil || *report.Note != "plaka görünüyor" {
		t.Errorf("unexpected note: %+v", report.Note)
	}
	if captured.Note.String != "plaka görünüyor" {
		t.Errorf("expected trimmed note to be sent, got %q", captured.Note.String)
	}
}

func TestReportsService_Create_TargetNotFound(t *testing.T) {
	cases := []struct {
		name       string
		targetType string
		store      fakeReportsStore
	}{
		{"cat", ReportTargetCat, fakeReportsStore{catExists: false}},
		{"update", ReportTargetUpdate, fakeReportsStore{updateExists: false}},
		{"media", ReportTargetMedia, fakeReportsStore{mediaErr: pgx.ErrNoRows}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			svc := NewReportsService(tc.store)
			_, err := svc.Create(context.Background(), uuid.New().String(), tc.targetType, uuid.New().String(), "spam", nil)
			if !errors.Is(err, ErrReportTargetNotFound) {
				t.Fatalf("expected ErrReportTargetNotFound, got %v", err)
			}
		})
	}
}

func TestReportsService_Create_DuplicateReturnsExistingOpenReport(t *testing.T) {
	reporterID := uuid.New()
	catID := uuid.New()
	existingID := uuid.New()

	svc := NewReportsService(fakeReportsStore{
		catExists: true,
		// CreateReport's own on-conflict-do-nothing hit the partial unique
		// index and returned no row — mirrors CreateMedia/CreateCat's own
		// idempotent-retry conflict shape.
		createErr: pgx.ErrNoRows,
		existingRow: repository.Report{
			ID:             pgtype.UUID{Bytes: existingID, Valid: true},
			ReporterUserID: pgtype.UUID{Bytes: reporterID, Valid: true},
			TargetType:     ReportTargetCat,
			TargetID:       pgtype.UUID{Bytes: catID, Valid: true},
			Reason:         "spam",
			Status:         "open",
		},
	})

	report, err := svc.Create(context.Background(), reporterID.String(), ReportTargetCat, catID.String(), "spam", nil)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if report.ID != existingID.String() {
		t.Errorf("expected the existing open report %s, got %s", existingID, report.ID)
	}
}
