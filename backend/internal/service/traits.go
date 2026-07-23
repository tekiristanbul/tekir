package service

import (
	"context"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// Trait is one entry of the controlled cat-trait vocabulary: a stable
// machine key plus its current, mutable display label. Per the product
// clarification on issue #21, this is deliberately not a closed enum —
// the vocabulary lives in data (the traits table), not in code.
type Trait struct {
	Key   string
	Label string
}

// TraitsLister is satisfied by repository.Store; kept as an interface here
// so TraitsService stays testable without a real database connection.
type TraitsLister interface {
	ListActiveTraits(ctx context.Context) ([]repository.ListActiveTraitsRow, error)
}

type TraitsService struct {
	db TraitsLister
}

func NewTraitsService(db TraitsLister) *TraitsService {
	return &TraitsService{db: db}
}

// ListActive returns the currently selectable trait vocabulary, ordered for
// display. Retired traits are excluded — they still render on any cat that
// already carries one (see CatsService.GetCatDetail), just not offered here.
func (s *TraitsService) ListActive(ctx context.Context) ([]Trait, error) {
	rows, err := s.db.ListActiveTraits(ctx)
	if err != nil {
		return nil, err
	}

	traits := make([]Trait, 0, len(rows))
	for _, r := range rows {
		traits = append(traits, Trait{Key: r.Key, Label: r.DisplayName})
	}
	return traits, nil
}
