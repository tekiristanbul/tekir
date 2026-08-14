package handler

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// ReportsCreator is satisfied by service.ReportsService; kept as an
// interface so the handler is testable without a real database connection.
type ReportsCreator interface {
	Create(ctx context.Context, reporterUserID, targetType, targetID, reason string, note *string) (service.Report, error)
}

// ReportsHandler exposes user-generated-content reporting (issue #233).
// Every method requires RequireBearer — report ownership is always the
// authenticated caller, never a client-supplied account id.
type ReportsHandler struct {
	reports ReportsCreator
}

func NewReportsHandler(reports ReportsCreator) *ReportsHandler {
	return &ReportsHandler{reports: reports}
}

// createReportRequest is the body of POST /v1/reports. DisallowUnknownFields
// rejects any client-supplied field beyond these three — in particular,
// there is no reporter/account id field: ownership is derived from the
// bearer session alone.
type createReportRequest struct {
	TargetType string  `json:"target_type"`
	TargetID   string  `json:"target_id"`
	Reason     string  `json:"reason"`
	Note       *string `json:"note"`
}

type createReportResponse struct {
	ID         string    `json:"id"`
	TargetType string    `json:"target_type"`
	TargetID   string    `json:"target_id"`
	Reason     string    `json:"reason"`
	Note       *string   `json:"note"`
	Status     string    `json:"status"`
	CreatedAt  time.Time `json:"created_at"`
}

func toCreateReportResponse(r service.Report) createReportResponse {
	return createReportResponse{
		ID:         r.ID,
		TargetType: r.TargetType,
		TargetID:   r.TargetID,
		Reason:     r.Reason,
		Note:       r.Note,
		Status:     r.Status,
		CreatedAt:  r.CreatedAt,
	}
}

// Create answers POST /v1/reports (Bearer required): the authenticated
// caller reports a cat, update, or media item for a fixed reason, with an
// optional note (required when reason is "other" — docs/architecture/api.md).
// A retried/duplicate submission against the same target, while an earlier
// report from this account against it is still open, answers 201 with the
// existing report rather than creating a second one or erroring.
func (h *ReportsHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req createReportRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	user := UserFromContext(r.Context())
	report, err := h.reports.Create(r.Context(), user.UserID, req.TargetType, req.TargetID, req.Reason, req.Note)
	if err != nil {
		writeReportsServiceError(w, err)
		return
	}

	writeJSON(w, http.StatusCreated, toCreateReportResponse(report))
}

func writeReportsServiceError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, service.ErrInvalidReportTargetType):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid target type"})
	case errors.Is(err, service.ErrInvalidReportTargetID):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid target id"})
	case errors.Is(err, service.ErrReportTargetNotFound):
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "report target not found"})
	case errors.Is(err, service.ErrInvalidReportReason):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid report reason"})
	case errors.Is(err, service.ErrReportNoteRequired):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "report note required"})
	default:
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
	}
}
