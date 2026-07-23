package handler

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
	"github.com/tekiristanbul/tekir/backend/internal/service"
)

type fakeCatsLister struct {
	rows []repository.ListCatsInBoundsRow

	catRow repository.GetCatByIDRow
	catErr error

	exists    bool
	existsErr error

	updateRows []repository.ListCatUpdatesRow
	updatesErr error

	traitRows []repository.ListCatTraitsRow
	traitsErr error
}

func (f fakeCatsLister) ListCatsInBounds(ctx context.Context, arg repository.ListCatsInBoundsParams) ([]repository.ListCatsInBoundsRow, error) {
	return f.rows, nil
}

func (f fakeCatsLister) GetCatByID(ctx context.Context, id pgtype.UUID) (repository.GetCatByIDRow, error) {
	return f.catRow, f.catErr
}

func (f fakeCatsLister) CatExists(ctx context.Context, id pgtype.UUID) (bool, error) {
	return f.exists, f.existsErr
}

func (f fakeCatsLister) ListCatUpdates(ctx context.Context, arg repository.ListCatUpdatesParams) ([]repository.ListCatUpdatesRow, error) {
	return f.updateRows, f.updatesErr
}

func (f fakeCatsLister) ListCatTraits(ctx context.Context, catID pgtype.UUID) ([]repository.ListCatTraitsRow, error) {
	return f.traitRows, f.traitsErr
}

// routerFor wires h behind a real chi router so chi.URLParam (used by
// Detail/UpdateHistory) is populated the same way it is in production.
func routerFor(h *CatsHandler) http.Handler {
	r := chi.NewRouter()
	r.Get("/v1/cats/{cat_id}", h.Detail)
	r.Get("/v1/cats/{cat_id}/updates", h.UpdateHistory)
	return r
}

func TestCatsHandler_Nearby(t *testing.T) {
	id := pgtype.UUID{Bytes: uuid.New(), Valid: true}
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{rows: []repository.ListCatsInBoundsRow{
		{
			ID:        id,
			Name:      pgtype.Text{String: "tekir", Valid: true},
			PhotoUrl:  pgtype.Text{String: "https://placecats.com/millie/300/200", Valid: true},
			Lng:       28.9744,
			Lat:       41.0256,
			AreaLabel: pgtype.Text{String: "Galata Kulesi çevresi, Beyoğlu", Valid: true},
			NeedsHelp: pgtype.Bool{Bool: false, Valid: true},
		},
	}}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats?bbox=28,41,29,42", nil)
	h.Nearby(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var body []catMarkerResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body) != 1 {
		t.Fatalf("expected 1 marker, got %d", len(body))
	}
	if body[0].PrimaryPhoto != "https://placecats.com/millie/300/200" {
		t.Errorf("unexpected primary_photo: %q", body[0].PrimaryPhoto)
	}
	if body[0].Name != "tekir" {
		t.Errorf("unexpected name: %q", body[0].Name)
	}
	if body[0].AreaLabel == nil || *body[0].AreaLabel != "Galata Kulesi çevresi, Beyoğlu" {
		t.Errorf("unexpected area_label: %v", body[0].AreaLabel)
	}
}

func TestCatsHandler_Nearby_MissingBbox(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats", nil)
	h.Nearby(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestCatsHandler_Nearby_MalformedBbox(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats?bbox=not,a,valid,bbox", nil)
	h.Nearby(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestCatsHandler_Nearby_InvalidBoundsOrder(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats?bbox=29,41,28,42", nil)
	h.Nearby(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestCatsHandler_Nearby_NanAndInfiniteBounds(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}))

	cases := []string{"NaN,41,29,42", "28,41,29,Inf", "-Inf,41,29,42"}
	for _, bbox := range cases {
		t.Run(bbox, func(t *testing.T) {
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodGet, "/v1/cats?bbox="+bbox, nil)
			h.Nearby(rec, req)

			if rec.Code != http.StatusBadRequest {
				t.Fatalf("expected 400, got %d", rec.Code)
			}
		})
	}
}

func TestCatsHandler_Detail(t *testing.T) {
	id := uuid.New()
	created := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		catRow: repository.GetCatByIDRow{
			ID:        pgtype.UUID{Bytes: id, Valid: true},
			Name:      pgtype.Text{String: "tekir", Valid: true},
			Lng:       28.9744,
			Lat:       41.0256,
			AreaLabel: pgtype.Text{String: "Galata Kulesi çevresi, Beyoğlu", Valid: true},
			PhotoUrl:  pgtype.Text{String: "https://placecats.com/millie/300/200", Valid: true},
			CreatedAt: pgtype.Timestamptz{Time: created, Valid: true},
		},
		traitRows: []repository.ListCatTraitsRow{{Key: "friendly", DisplayName: "Friendly"}},
	}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+id.String(), nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var body catDetailResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.Name != "tekir" {
		t.Errorf("unexpected name: %q", body.Name)
	}
	if body.PrimaryPhoto == nil || *body.PrimaryPhoto != "https://placecats.com/millie/300/200" {
		t.Errorf("unexpected primary_photo: %v", body.PrimaryPhoto)
	}
	if len(body.Traits) != 1 || body.Traits[0].Key != "friendly" || body.Traits[0].Label != "Friendly" {
		t.Errorf("unexpected traits: %v", body.Traits)
	}
	if body.AreaLabel == nil || *body.AreaLabel != "Galata Kulesi çevresi, Beyoğlu" {
		t.Errorf("unexpected area_label: %v", body.AreaLabel)
	}
}

func TestCatsHandler_Detail_NotFound(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{catErr: pgx.ErrNoRows}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String(), nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_Detail_InvalidID(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/not-a-uuid", nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestCatsHandler_Detail_RepositoryFailure(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{catErr: errors.New("connection refused")}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String(), nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_UpdateHistory(t *testing.T) {
	id := uuid.New()
	created := time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC)
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{
		exists: true,
		updateRows: []repository.ListCatUpdatesRow{
			{
				ID:        pgtype.UUID{Bytes: uuid.New(), Valid: true},
				CreatedAt: pgtype.Timestamptz{Time: created, Valid: true},
				Seq:       pgtype.Int8{Int64: 1, Valid: true},
				Statuses:  []string{"seen", "fed"},
			},
		},
	}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+id.String()+"/updates", nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var body updateHistoryResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body.Items) != 1 {
		t.Fatalf("expected 1 item, got %d", len(body.Items))
	}
	if body.NextCursor != nil {
		t.Errorf("expected nil next_cursor, got %v", *body.NextCursor)
	}
	if len(body.Items[0].Statuses) != 2 {
		t.Errorf("unexpected statuses: %v", body.Items[0].Statuses)
	}
	if body.Items[0].Comment != nil {
		t.Errorf("expected nil comment, got %v", *body.Items[0].Comment)
	}
}

func TestCatsHandler_UpdateHistory_NotFound(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: false}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String()+"/updates", nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_UpdateHistory_InvalidLimit(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String()+"/updates?limit=not-a-number", nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_UpdateHistory_LimitOutOfRange(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String()+"/updates?limit=1000", nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCatsHandler_UpdateHistory_RepositoryFailure(t *testing.T) {
	h := NewCatsHandler(service.NewCatsService(fakeCatsLister{exists: true, updatesErr: errors.New("connection refused")}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/cats/"+uuid.New().String()+"/updates", nil)
	routerFor(h).ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d: %s", rec.Code, rec.Body.String())
	}
}
