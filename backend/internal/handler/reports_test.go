package handler

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// fakeReportsCreator is an in-process stub for ReportsCreator.
type fakeReportsCreator struct {
	report service.Report
	err    error

	capturedReporterUserID *string
	capturedTargetType     *string
	capturedTargetID       *string
	capturedReason         *string
	capturedNote           **string
}

func (f fakeReportsCreator) Create(_ context.Context, reporterUserID, targetType, targetID, reason string, note *string) (service.Report, error) {
	if f.capturedReporterUserID != nil {
		*f.capturedReporterUserID = reporterUserID
	}
	if f.capturedTargetType != nil {
		*f.capturedTargetType = targetType
	}
	if f.capturedTargetID != nil {
		*f.capturedTargetID = targetID
	}
	if f.capturedReason != nil {
		*f.capturedReason = reason
	}
	if f.capturedNote != nil {
		*f.capturedNote = note
	}
	return f.report, f.err
}

func routerForReports(h *ReportsHandler, validator AccessTokenValidator) http.Handler {
	r := chi.NewRouter()
	r.With(RequireBearer(validator)).Post("/v1/reports", h.Create)
	return r
}

func postReportJSON(body string) *http.Request {
	return withBearerToken(httptest.NewRequest(http.MethodPost, "/v1/reports", bytes.NewBufferString(body)))
}

func TestReportsHandler_Create_Success(t *testing.T) {
	userID := uuid.New().String()
	catID := uuid.New().String()
	reportID := uuid.New().String()
	createdAt := time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC)

	var capturedReporter, capturedType, capturedTarget, capturedReason string
	h := NewReportsHandler(fakeReportsCreator{
		capturedReporterUserID: &capturedReporter,
		capturedTargetType:     &capturedType,
		capturedTargetID:       &capturedTarget,
		capturedReason:         &capturedReason,
		report: service.Report{
			ID:         reportID,
			TargetType: "cat",
			TargetID:   catID,
			Reason:     "spam",
			Status:     "open",
			CreatedAt:  createdAt,
		},
	})

	rec := httptest.NewRecorder()
	req := postReportJSON(`{"target_type":"cat","target_id":"` + catID + `","reason":"spam"}`)
	routerForReports(h, fakeAccessValidator{userID: userID}).ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	if capturedReporter != userID {
		t.Errorf("expected reporter %s, got %s", userID, capturedReporter)
	}
	if capturedType != "cat" || capturedTarget != catID || capturedReason != "spam" {
		t.Errorf("unexpected captured args: type=%s target=%s reason=%s", capturedType, capturedTarget, capturedReason)
	}

	var body createReportResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.ID != reportID || body.Status != "open" || body.Note != nil {
		t.Fatalf("unexpected body: %+v", body)
	}
}

func TestReportsHandler_Create_PassesOptionalNote(t *testing.T) {
	var capturedNote *string
	h := NewReportsHandler(fakeReportsCreator{capturedNote: &capturedNote})

	rec := httptest.NewRecorder()
	req := postReportJSON(`{"target_type":"cat","target_id":"` + uuid.New().String() + `","reason":"other","note":"plaka görünüyor"}`)
	routerForReports(h, fakeAccessValidator{userID: uuid.New().String()}).ServeHTTP(rec, req)

	if capturedNote == nil || *capturedNote != "plaka görünüyor" {
		t.Fatalf("expected note to be passed through, got %v", capturedNote)
	}
}

func TestReportsHandler_Create_InvalidBody(t *testing.T) {
	h := NewReportsHandler(fakeReportsCreator{})
	rec := httptest.NewRecorder()
	req := postReportJSON(`{"target_type":"cat","target_id":"x","reason":"spam","unexpected":"field"}`)
	routerForReports(h, fakeAccessValidator{userID: uuid.New().String()}).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for unknown field, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestReportsHandler_Create_RequiresBearer(t *testing.T) {
	h := NewReportsHandler(fakeReportsCreator{})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/reports", bytes.NewBufferString(`{"target_type":"cat","target_id":"`+uuid.New().String()+`","reason":"spam"}`))
	routerForReports(h, fakeAccessValidator{userID: uuid.New().String()}).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestReportsHandler_Create_ServiceErrors(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want int
	}{
		{"invalid target type", service.ErrInvalidReportTargetType, http.StatusBadRequest},
		{"invalid target id", service.ErrInvalidReportTargetID, http.StatusBadRequest},
		{"target not found", service.ErrReportTargetNotFound, http.StatusNotFound},
		{"invalid reason", service.ErrInvalidReportReason, http.StatusBadRequest},
		{"note required", service.ErrReportNoteRequired, http.StatusBadRequest},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := NewReportsHandler(fakeReportsCreator{err: tc.err})
			rec := httptest.NewRecorder()
			req := postReportJSON(`{"target_type":"cat","target_id":"` + uuid.New().String() + `","reason":"spam"}`)
			routerForReports(h, fakeAccessValidator{userID: uuid.New().String()}).ServeHTTP(rec, req)

			if rec.Code != tc.want {
				t.Fatalf("expected %d, got %d: %s", tc.want, rec.Code, rec.Body.String())
			}
		})
	}
}
