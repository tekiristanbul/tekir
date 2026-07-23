package repository_test

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

func upsertTestTrait(t *testing.T, ctx context.Context, store *repository.Store, key, displayName string, active bool, sortOrder int32) {
	t.Helper()
	if _, err := store.UpsertTrait(ctx, repository.UpsertTraitParams{
		Key:         key,
		DisplayName: displayName,
		Active:      active,
		SortOrder:   sortOrder,
	}); err != nil {
		t.Fatalf("upsert trait %s: %v", key, err)
	}
}

func TestStore_ListActiveTraits_ExcludesRetired(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	upsertTestTrait(t, ctx, store, "friendly", "Friendly", true, 0)
	upsertTestTrait(t, ctx, store, "playful", "Playful", true, 1)
	upsertTestTrait(t, ctx, store, "retired_trait", "Retired Trait", false, 2)

	rows, err := store.ListActiveTraits(ctx)
	if err != nil {
		t.Fatalf("list: %v", err)
	}

	seen := make(map[string]bool, len(rows))
	for _, r := range rows {
		seen[r.Key] = true
	}
	if !seen["friendly"] || !seen["playful"] {
		t.Errorf("expected active traits to include friendly and playful, got %v", rows)
	}
	if seen["retired_trait"] {
		t.Error("expected retired trait to be excluded from the active vocabulary")
	}
}

func TestStore_ListCatTraits_IncludesRetiredAssociations(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	upsertTestTrait(t, ctx, store, "vocal", "Vocal", true, 0)
	id := upsertTestCat(t, ctx, store, "trait bearer")

	if err := store.CreateCatTrait(ctx, repository.CreateCatTraitParams{CatID: id, TraitKey: "vocal"}); err != nil {
		t.Fatalf("assign trait: %v", err)
	}

	// retiring the trait must not erase the cat's existing association
	// (per the product clarification on issue #21).
	upsertTestTrait(t, ctx, store, "vocal", "Vocal", false, 0)

	rows, err := store.ListCatTraits(ctx, id)
	if err != nil {
		t.Fatalf("list cat traits: %v", err)
	}
	if len(rows) != 1 || rows[0].Key != "vocal" {
		t.Errorf("expected the cat to still carry the retired trait, got %v", rows)
	}
	if rows[0].DisplayName != "Vocal" {
		t.Errorf("expected display_name %q, got %q", "Vocal", rows[0].DisplayName)
	}
}

func TestStore_ListCatTraits_Empty(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	id := upsertTestCat(t, ctx, store, "no traits")

	rows, err := store.ListCatTraits(ctx, id)
	if err != nil {
		t.Fatalf("list cat traits: %v", err)
	}
	if len(rows) != 0 {
		t.Errorf("expected no traits, got %v", rows)
	}
}

func TestStore_ListActiveTraits_GroupThenTraitOrdering(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	if _, err := store.UpsertTraitGroup(ctx, repository.UpsertTraitGroupParams{Key: "group_b", DisplayName: "Group B", SortOrder: 1}); err != nil {
		t.Fatalf("upsert group_b: %v", err)
	}
	if _, err := store.UpsertTraitGroup(ctx, repository.UpsertTraitGroupParams{Key: "group_a", DisplayName: "Group A", SortOrder: 0}); err != nil {
		t.Fatalf("upsert group_a: %v", err)
	}

	upsertGroupedTrait(t, ctx, store, "b_second", "B Second", "group_b", 1)
	upsertGroupedTrait(t, ctx, store, "b_first", "B First", "group_b", 0)
	upsertGroupedTrait(t, ctx, store, "a_first", "A First", "group_a", 0)

	rows, err := store.ListActiveTraits(ctx)
	if err != nil {
		t.Fatalf("list: %v", err)
	}

	var keys []string
	for _, r := range rows {
		if r.Key == "a_first" || r.Key == "b_first" || r.Key == "b_second" {
			keys = append(keys, r.Key)
		}
	}
	want := []string{"a_first", "b_first", "b_second"}
	if len(keys) != len(want) {
		t.Fatalf("expected %v, got %v", want, keys)
	}
	for i := range want {
		if keys[i] != want[i] {
			t.Errorf("expected group-then-trait order %v, got %v", want, keys)
			break
		}
	}
}

func upsertGroupedTrait(t *testing.T, ctx context.Context, store *repository.Store, key, displayName, groupKey string, sortOrder int32) {
	t.Helper()
	if _, err := store.UpsertTrait(ctx, repository.UpsertTraitParams{
		Key:         key,
		DisplayName: displayName,
		GroupKey:    pgtype.Text{String: groupKey, Valid: true},
		Active:      true,
		SortOrder:   sortOrder,
	}); err != nil {
		t.Fatalf("upsert trait %s: %v", key, err)
	}
}
