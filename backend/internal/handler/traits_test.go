package handler

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
	"github.com/tekiristanbul/tekir/backend/internal/service"
)

type fakeTraitsLister struct {
	rows []repository.ListActiveTraitsRow
	err  error
}

func (f fakeTraitsLister) ListActiveTraits(ctx context.Context) ([]repository.ListActiveTraitsRow, error) {
	return f.rows, f.err
}

func TestTraitsHandler_List(t *testing.T) {
	h := NewTraitsHandler(service.NewTraitsService(fakeTraitsLister{rows: []repository.ListActiveTraitsRow{
		{Key: "friendly", DisplayName: "Friendly"},
		{Key: "playful", DisplayName: "Playful"},
	}}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/traits", nil)
	h.List(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var body []traitResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body) != 2 || body[0].Key != "friendly" || body[0].Label != "Friendly" {
		t.Errorf("unexpected body: %v", body)
	}
}

func TestTraitsHandler_List_GroupMetadata(t *testing.T) {
	h := NewTraitsHandler(service.NewTraitsService(fakeTraitsLister{rows: []repository.ListActiveTraitsRow{
		{
			Key:              "playful",
			DisplayName:      "Oyuncu",
			GroupKey:         pgtype.Text{String: "personality", Valid: true},
			GroupDisplayName: pgtype.Text{String: "Kişilik", Valid: true},
		},
	}}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/traits", nil)
	h.List(rec, req)

	var body []traitVocabResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body) != 1 {
		t.Fatalf("expected 1 trait, got %d", len(body))
	}
	if body[0].GroupKey == nil || *body[0].GroupKey != "personality" {
		t.Errorf("unexpected group_key: %v", body[0].GroupKey)
	}
	if body[0].GroupLabel == nil || *body[0].GroupLabel != "Kişilik" {
		t.Errorf("unexpected group_label: %v", body[0].GroupLabel)
	}
}

func TestTraitsHandler_List_RepositoryFailure(t *testing.T) {
	h := NewTraitsHandler(service.NewTraitsService(fakeTraitsLister{err: errors.New("connection refused")}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/traits", nil)
	h.List(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d: %s", rec.Code, rec.Body.String())
	}
}
