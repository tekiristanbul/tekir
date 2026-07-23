package service

import (
	"context"
	"errors"
	"testing"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

type fakeTraitsLister struct {
	rows []repository.ListActiveTraitsRow
	err  error
}

func (f fakeTraitsLister) ListActiveTraits(ctx context.Context) ([]repository.ListActiveTraitsRow, error) {
	return f.rows, f.err
}

func TestTraitsService_ListActive(t *testing.T) {
	svc := NewTraitsService(fakeTraitsLister{rows: []repository.ListActiveTraitsRow{
		{Key: "friendly", DisplayName: "Friendly"},
		{Key: "playful", DisplayName: "Playful"},
	}})

	traits, err := svc.ListActive(context.Background())
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(traits) != 2 {
		t.Fatalf("expected 2 traits, got %d", len(traits))
	}
	if traits[0].Key != "friendly" || traits[0].Label != "Friendly" {
		t.Errorf("unexpected first trait: %+v", traits[0])
	}
}

func TestTraitsService_ListActive_RepositoryFailure(t *testing.T) {
	svc := NewTraitsService(fakeTraitsLister{err: errors.New("connection refused")})

	if _, err := svc.ListActive(context.Background()); err == nil {
		t.Fatal("expected an error, got nil")
	}
}
