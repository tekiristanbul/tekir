package handler

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// issue #101: POST /v1/cats/{cat_id}/updates carries the combined help
// flag; PATCH may only ever clear it.

func TestCatsHandler_CreateUpdate_WithNeedsHelp(t *testing.T) {
	catID := uuid.New()
	deviceID := uuid.New()
	userID := uuid.New()
	created := time.Date(2026, 8, 1, 10, 0, 0, 0, time.UTC)
	returnedID := uuid.New()
	var captured repository.CreateOrdinaryUpdateParams
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		exists:    true,
		createRow: repository.CreateUpdateRow{ID: pgtype.UUID{Bytes: returnedID, Valid: true}},
		captured:  &captured,
	}, service.WithClock(func() time.Time { return created })), testMaxUploadBytes)

	r := routerForWithResolver(h,
		fakeDeviceResolver{identity: service.DeviceIdentity{DeviceID: deviceID.String()}},
		fakeAccessValidator{userID: userID.String()},
	)
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(catID.String(), `{"statuses":["water_provided"],"needs_help":true,"comment":"kabı bomboştu"}`)
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	var body updateResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if !body.NeedsHelp {
		t.Error("expected needs_help true in the response")
	}
	if body.Kind != "needs_help" {
		t.Errorf("expected wire kind needs_help, got %q", body.Kind)
	}
	if body.NeedsHelpCategory == nil || *body.NeedsHelpCategory != "unspecified" {
		t.Errorf("expected compat category unspecified, got %v", body.NeedsHelpCategory)
	}
	if body.NeedsHelpExpiresAt == nil || !body.NeedsHelpExpiresAt.Equal(created.Add(72*time.Hour)) {
		t.Errorf("expected server-computed 72h expiry, got %v", body.NeedsHelpExpiresAt)
	}
	if !captured.NeedsHelp || captured.NeedsHelpCategory.Valid {
		t.Errorf("expected a category-less flag write, got %+v", captured)
	}
}

func TestCatsHandler_CreateUpdate_NeedsHelpAloneIsValid(t *testing.T) {
	returnedID := uuid.New()
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		exists:    true,
		createRow: repository.CreateUpdateRow{ID: pgtype.UUID{Bytes: returnedID, Valid: true}},
	}, service.WithClock(time.Now)), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{"needs_help":true}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201 for a help-only update, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CorrectUpdate_NeedsHelpTrueRejected(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := newCorrectUpdateRequest(uuid.New().String(), uuid.New().String(), `{"statuses":["seen"],"needs_help":true}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for needs_help:true on a correction, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_CorrectUpdate_ClearNeedsHelp(t *testing.T) {
	catID := uuid.New()
	updateID := uuid.New()
	createdAt := time.Date(2026, 8, 1, 8, 0, 0, 0, time.UTC)
	fixedNow := createdAt.Add(2 * time.Minute)
	var captured repository.CorrectOwnUpdateParams
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		correctRow: repository.CorrectOrdinaryUpdateRow{
			ID:        pgtype.UUID{Bytes: updateID, Valid: true},
			CreatedAt: pgtype.Timestamptz{Time: createdAt, Valid: true},
			UpdatedAt: pgtype.Timestamptz{Time: fixedNow, Valid: true},
			NeedsHelp: false,
		},
		capturedCorrect: &captured,
	}, service.WithClock(func() time.Time { return fixedNow })), testMaxUploadBytes)

	rec := httptest.NewRecorder()
	req := newCorrectUpdateRequest(catID.String(), updateID.String(), `{"statuses":["seen"],"needs_help":false}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if !captured.ClearNeedsHelp {
		t.Error("expected the clear flag to reach the repository params")
	}
	var body updateResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.NeedsHelp || body.Kind != "ordinary" {
		t.Errorf("expected a cleared response, got needs_help=%v kind=%q", body.NeedsHelp, body.Kind)
	}
}

func TestCatsHandler_CreateUpdate_NoteTooLong(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true}), testMaxUploadBytes)

	long := make([]byte, 0, 501)
	for range 501 {
		long = append(long, 'a')
	}
	rec := httptest.NewRecorder()
	req := newCreateUpdateRequest(uuid.New().String(), `{"needs_help":true,"comment":"`+string(long)+`"}`)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for an over-cap note, got %d: %s", rec.Code, rec.Body.String())
	}
}
