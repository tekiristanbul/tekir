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

// TraitVocabEntry is one entry of the active, selectable trait vocabulary —
// Trait plus the group metadata (issue #23: product-owner decision that the
// future picker groups traits, e.g. personality / interaction with people /
// interaction with animals / physical characteristics) needed to render a
// grouped picker. GroupKey/GroupLabel are nil for a trait with no group.
type TraitVocabEntry struct {
	Key        string
	Label      string
	GroupKey   *string
	GroupLabel *string
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

// ListActive returns the currently selectable trait vocabulary, grouped-
// then-trait ordered for display. Retired traits are excluded — they still
// render on any cat that already carries one (see CatsService.GetCatDetail),
// just not offered here.
func (s *TraitsService) ListActive(ctx context.Context) ([]TraitVocabEntry, error) {
	rows, err := s.db.ListActiveTraits(ctx)
	if err != nil {
		return nil, err
	}

	traits := make([]TraitVocabEntry, 0, len(rows))
	for _, r := range rows {
		entry := TraitVocabEntry{Key: r.Key, Label: r.DisplayName}
		if r.GroupKey.Valid {
			groupKey := r.GroupKey.String
			groupLabel := r.GroupDisplayName.String
			entry.GroupKey = &groupKey
			entry.GroupLabel = &groupLabel
		}
		traits = append(traits, entry)
	}
	return traits, nil
}
