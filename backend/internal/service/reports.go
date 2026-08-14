package service

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// ErrInvalidReportTargetType means POST /v1/reports' target_type wasn't one
// of the closed vocabulary this endpoint accepts (issue #233): cat,
// update, media.
var ErrInvalidReportTargetType = errors.New("invalid report target type")

// ErrInvalidReportTargetID means target_id wasn't a well-formed uuid.
var ErrInvalidReportTargetID = errors.New("invalid report target id")

// ErrReportTargetNotFound means target_type/target_id were well-formed but
// no such row exists — including a cat/update that's been soft-deleted,
// which is already excluded from every other read surface (see
// CatExists/UpdateExists).
var ErrReportTargetNotFound = errors.New("report target not found")

// ErrInvalidReportReason means reason wasn't one of the fixed mvp
// vocabulary (docs/architecture/api.md, docs/architecture/db.md).
var ErrInvalidReportReason = errors.New("invalid report reason")

// ErrReportNoteRequired means reason was "other", which requires a
// non-empty note (product-owner decision on issue #233) — every other
// reason leaves the note optional.
var ErrReportNoteRequired = errors.New("report note required")

// the closed target-type vocabulary POST /v1/reports accepts (issue #233).
const (
	ReportTargetCat    = "cat"
	ReportTargetUpdate = "update"
	ReportTargetMedia  = "media"
)

var reportTargetTypes = map[string]bool{
	ReportTargetCat:    true,
	ReportTargetUpdate: true,
	ReportTargetMedia:  true,
}

const reportReasonOther = "other"

// reportReasons is the fixed, closed mvp report-reason vocabulary
// (product-owner decision on issue #233) — mirrored by the database's own
// reports_reason_check constraint, not a data-driven vocabulary like
// traits: adding a reason is a schema change. The turkish display labels
// this vocabulary maps to live in the flutter client, not here — this map
// is validation-only.
var reportReasons = map[string]bool{
	"inappropriate":   true,
	"not_a_cat":       true,
	"wrong_info":      true,
	"spam":            true,
	"privacy":         true,
	reportReasonOther: true,
}

// ReportsStore is satisfied by repository.Store; kept as an interface here
// so ReportsService can be tested against a fake, mirroring every other
// service in this package.
type ReportsStore interface {
	CreateReport(ctx context.Context, arg repository.CreateReportParams) (repository.Report, error)
	GetOpenReportByReporterAndTarget(ctx context.Context, arg repository.GetOpenReportByReporterAndTargetParams) (repository.Report, error)
	CatExists(ctx context.Context, id pgtype.UUID) (bool, error)
	UpdateExists(ctx context.Context, id pgtype.UUID) (bool, error)
	GetMediaByID(ctx context.Context, id pgtype.UUID) (repository.Medium, error)
}

// Report is the service-layer shape of a submitted report.
type Report struct {
	ID         string
	TargetType string
	TargetID   string
	Reason     string
	Note       *string
	Status     string
	CreatedAt  time.Time
}

type ReportsService struct {
	db ReportsStore
}

func NewReportsService(db ReportsStore) *ReportsService {
	return &ReportsService{db: db}
}

// Create validates and records a report of targetType/targetID by
// reporterUserID — always resolved from the authenticated bearer session
// (see RequireBearer), never client-supplied. A retried/duplicate report
// from the same account against the same target, while an earlier report
// from that account against it is still open, is idempotent: the existing
// open report is returned rather than a second one being created (issue
// #233 acceptance). Reporting never mutates the target itself — no cat,
// update, or media row is touched by this method, only a new reports row
// is written.
func (s *ReportsService) Create(ctx context.Context, reporterUserID, targetType, targetID, reason string, note *string) (Report, error) {
	if !reportTargetTypes[targetType] {
		return Report{}, ErrInvalidReportTargetType
	}
	targetUUID, err := uuid.Parse(targetID)
	if err != nil {
		return Report{}, ErrInvalidReportTargetID
	}
	if !reportReasons[reason] {
		return Report{}, ErrInvalidReportReason
	}

	trimmedNote := ""
	if note != nil {
		trimmedNote = strings.TrimSpace(*note)
	}
	if reason == reportReasonOther && trimmedNote == "" {
		return Report{}, ErrReportNoteRequired
	}

	targetPg := pgtype.UUID{Bytes: targetUUID, Valid: true}
	exists, err := s.targetExists(ctx, targetType, targetPg)
	if err != nil {
		return Report{}, err
	}
	if !exists {
		return Report{}, ErrReportTargetNotFound
	}

	// reporterUserID comes from the authenticated bearer context
	// RequireBearer placed on the request — always a well-formed uuid,
	// never client-supplied input to re-validate against a sentinel error
	// here (mirrors CatsService.DeleteCat's own callerUserID handling).
	reporterUUID, err := uuid.Parse(reporterUserID)
	if err != nil {
		return Report{}, err
	}
	reporterPg := pgtype.UUID{Bytes: reporterUUID, Valid: true}

	var notePg pgtype.Text
	if trimmedNote != "" {
		notePg = pgtype.Text{String: trimmedNote, Valid: true}
	}

	row, err := s.db.CreateReport(ctx, repository.CreateReportParams{
		ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
		ReporterUserID: reporterPg,
		TargetType:     targetType,
		TargetID:       targetPg,
		Reason:         reason,
		Note:           notePg,
	})
	if err == nil {
		return toReport(row), nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return Report{}, err
	}

	// CreateReport's own on-conflict-do-nothing hit the partial unique
	// index: an open report from this account against this target already
	// exists. Return it rather than erroring — a retried/duplicate
	// submission is a success, not a failure (issue #233 acceptance).
	existing, err := s.db.GetOpenReportByReporterAndTarget(ctx, repository.GetOpenReportByReporterAndTargetParams{
		ReporterUserID: reporterPg,
		TargetType:     targetType,
		TargetID:       targetPg,
	})
	if err != nil {
		return Report{}, err
	}
	return toReport(existing), nil
}

func (s *ReportsService) targetExists(ctx context.Context, targetType string, targetID pgtype.UUID) (bool, error) {
	switch targetType {
	case ReportTargetCat:
		return s.db.CatExists(ctx, targetID)
	case ReportTargetUpdate:
		return s.db.UpdateExists(ctx, targetID)
	case ReportTargetMedia:
		if _, err := s.db.GetMediaByID(ctx, targetID); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return false, nil
			}
			return false, err
		}
		return true, nil
	default:
		return false, ErrInvalidReportTargetType
	}
}

func toReport(row repository.Report) Report {
	var note *string
	if row.Note.Valid {
		note = &row.Note.String
	}
	return Report{
		ID:         uuid.UUID(row.ID.Bytes).String(),
		TargetType: row.TargetType,
		TargetID:   uuid.UUID(row.TargetID.Bytes).String(),
		Reason:     row.Reason,
		Note:       note,
		Status:     row.Status,
		CreatedAt:  row.CreatedAt.Time,
	}
}
