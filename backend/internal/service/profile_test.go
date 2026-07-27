package service

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

type fakeProfileStore struct {
	user    repository.User
	userErr error

	ordinary    []repository.ListUserOrdinaryUpdatesForBadgesRow
	ordinaryErr error

	needsHelp    []repository.ListUserNeedsHelpUpdatesForBadgesRow
	needsHelpErr error

	createdCats    []repository.ListUserCreatedCatsForBadgesRow
	createdCatsErr error

	summaries    []repository.GetCatSummariesByIDsRow
	summariesErr error
}

func (f fakeProfileStore) GetUserByID(ctx context.Context, id pgtype.UUID) (repository.User, error) {
	return f.user, f.userErr
}

func (f fakeProfileStore) ListUserOrdinaryUpdatesForBadges(ctx context.Context, authorUserID pgtype.UUID) ([]repository.ListUserOrdinaryUpdatesForBadgesRow, error) {
	return f.ordinary, f.ordinaryErr
}

func (f fakeProfileStore) ListUserNeedsHelpUpdatesForBadges(ctx context.Context, authorUserID pgtype.UUID) ([]repository.ListUserNeedsHelpUpdatesForBadgesRow, error) {
	return f.needsHelp, f.needsHelpErr
}

func (f fakeProfileStore) ListUserCreatedCatsForBadges(ctx context.Context, createdByUserID pgtype.UUID) ([]repository.ListUserCreatedCatsForBadgesRow, error) {
	return f.createdCats, f.createdCatsErr
}

func (f fakeProfileStore) GetCatSummariesByIDs(ctx context.Context, ids []pgtype.UUID) ([]repository.GetCatSummariesByIDsRow, error) {
	return f.summaries, f.summariesErr
}

func TestContributionTotals_CountsEachKindAndDistinctCats(t *testing.T) {
	catA, catB := uuid.New(), uuid.New()
	base := time.Now()
	events := []contributionEvent{
		{Kind: contributionOrdinary, CatID: catA, CreatedAt: base, Statuses: []string{"seen"}},
		{Kind: contributionOrdinary, CatID: catA, CreatedAt: base.Add(time.Hour), Statuses: []string{"fed"}},
		{Kind: contributionNeedsHelp, CatID: catB, CreatedAt: base.Add(2 * time.Hour)},
		{Kind: contributionCatAdded, CatID: catB, CreatedAt: base.Add(3 * time.Hour)},
	}
	totals := contributionTotals(events)
	if totals.Updates != 2 {
		t.Errorf("expected 2 updates, got %d", totals.Updates)
	}
	if totals.Helps != 1 {
		t.Errorf("expected 1 help, got %d", totals.Helps)
	}
	if totals.CatsAdded != 1 {
		t.Errorf("expected 1 cat added, got %d", totals.CatsAdded)
	}
	if totals.DistinctCats != 2 {
		t.Errorf("expected 2 distinct cats, got %d", totals.DistinctCats)
	}
}

func TestRecentContributions_NewestFirstAndCapped(t *testing.T) {
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	var events []contributionEvent
	for i := 0; i < recentContributionsLimit+5; i++ {
		events = append(events, contributionEvent{
			Kind: contributionCatAdded, CatID: uuid.New(),
			CreatedAt: base.Add(time.Duration(i) * time.Hour),
		})
	}

	recent := recentContributions(events)
	if len(recent) != recentContributionsLimit {
		t.Fatalf("expected exactly %d items, got %d", recentContributionsLimit, len(recent))
	}
	// newest first: the last-created event must be first.
	want := base.Add(time.Duration(len(events)-1) * time.Hour)
	if !recent[0].CreatedAt.Equal(want) {
		t.Errorf("expected newest event first (%v), got %v", want, recent[0].CreatedAt)
	}
	for i := 1; i < len(recent); i++ {
		if recent[i].CreatedAt.After(recent[i-1].CreatedAt) {
			t.Fatalf("expected strictly newest-first order, got %v after %v", recent[i].CreatedAt, recent[i-1].CreatedAt)
		}
	}
}

func TestProfileService_GetProfile_ResolvesDisplayNameTotalsBadgesAndRecent(t *testing.T) {
	userID := uuid.New()
	catID := uuid.New()
	createdAt := time.Date(2026, 1, 1, 9, 0, 0, 0, time.UTC)

	store := fakeProfileStore{
		user: repository.User{
			ID:          pgtype.UUID{Bytes: userID, Valid: true},
			DisplayName: pgtype.Text{String: "Ada", Valid: true},
		},
		ordinary: []repository.ListUserOrdinaryUpdatesForBadgesRow{
			{
				CatID:     pgtype.UUID{Bytes: catID, Valid: true},
				CreatedAt: pgtype.Timestamptz{Time: createdAt, Valid: true},
				Statuses:  []string{"seen"},
			},
		},
		summaries: []repository.GetCatSummariesByIDsRow{
			{ID: pgtype.UUID{Bytes: catID, Valid: true}, Name: pgtype.Text{String: "Tekir", Valid: true}, PhotoUrl: "https://example.test/tekir.jpg"},
		},
	}
	svc := NewProfileService(store)

	profile, err := svc.GetProfile(context.Background(), userID.String())
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if profile.DisplayName == nil || *profile.DisplayName != "Ada" {
		t.Errorf("expected display name Ada, got %v", profile.DisplayName)
	}
	if profile.Totals.Updates != 1 || profile.Totals.DistinctCats != 1 {
		t.Errorf("unexpected totals: %+v", profile.Totals)
	}
	firstSighting := badgeByID(profile.Badges, "first_sighting")
	if !firstSighting.Earned {
		t.Errorf("expected first_sighting earned, got %+v", firstSighting)
	}
	if len(profile.RecentContributions) != 1 {
		t.Fatalf("expected 1 recent contribution, got %d", len(profile.RecentContributions))
	}
	rc := profile.RecentContributions[0]
	if rc.CatName != "Tekir" || rc.CatPrimaryPhoto == nil || *rc.CatPrimaryPhoto != "https://example.test/tekir.jpg" {
		t.Errorf("expected resolved cat display fields, got %+v", rc)
	}
}

func TestProfileService_GetProfile_NoDisplayNameIsNil(t *testing.T) {
	userID := uuid.New()
	store := fakeProfileStore{
		user: repository.User{ID: pgtype.UUID{Bytes: userID, Valid: true}},
	}
	svc := NewProfileService(store)

	profile, err := svc.GetProfile(context.Background(), userID.String())
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if profile.DisplayName != nil {
		t.Errorf("expected nil display name, got %v", *profile.DisplayName)
	}
	if len(profile.Badges) != 5 {
		t.Errorf("expected all 5 badges returned even with no contributions, got %d", len(profile.Badges))
	}
}

func TestProfileService_GetBadges_MatchesProfileDerivation(t *testing.T) {
	userID := uuid.New()
	catID := uuid.New()
	store := fakeProfileStore{
		user: repository.User{ID: pgtype.UUID{Bytes: userID, Valid: true}},
		ordinary: []repository.ListUserOrdinaryUpdatesForBadgesRow{
			{
				CatID:     pgtype.UUID{Bytes: catID, Valid: true},
				CreatedAt: pgtype.Timestamptz{Time: time.Now(), Valid: true},
				Statuses:  []string{"seen"},
			},
		},
	}
	svc := NewProfileService(store)

	badges, err := svc.GetBadges(context.Background(), userID.String())
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if !badgeByID(badges, "first_sighting").Earned {
		t.Errorf("expected first_sighting earned via GetBadges too")
	}
}

func TestProfileService_GetProfile_InvalidUserID(t *testing.T) {
	svc := NewProfileService(fakeProfileStore{})
	if _, err := svc.GetProfile(context.Background(), "not-a-uuid"); err == nil {
		t.Fatal("expected an error for a malformed user id")
	}
}
