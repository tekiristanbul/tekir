package service

import (
	"context"
	"sort"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/tekiristanbul/tekir/backend/internal/repository"
)

// recentContributionsLimit caps how many of an account's most recent
// contributions the profile screen shows (docs/product/community.md's
// "recent public contributions") — matches the approved prototype's own
// 8-item cap (prototype/app.js).
const recentContributionsLimit = 8

// ProfileStore is satisfied by repository.Store; kept as an interface so
// ProfileService stays testable without a real database connection,
// mirroring CatsStore's own shape.
type ProfileStore interface {
	GetUserByID(ctx context.Context, id pgtype.UUID) (repository.User, error)
	ListUserOrdinaryUpdatesForBadges(ctx context.Context, authorUserID pgtype.UUID) ([]repository.ListUserOrdinaryUpdatesForBadgesRow, error)
	ListUserNeedsHelpUpdatesForBadges(ctx context.Context, authorUserID pgtype.UUID) ([]repository.ListUserNeedsHelpUpdatesForBadgesRow, error)
	ListUserCreatedCatsForBadges(ctx context.Context, createdByUserID pgtype.UUID) ([]repository.ListUserCreatedCatsForBadgesRow, error)
	GetCatSummariesByIDs(ctx context.Context, ids []pgtype.UUID) ([]repository.GetCatSummariesByIDsRow, error)
}

// ProfileService derives the minimal authenticated profile surface (issue
// #80, docs/product/community.md/badges.md): display name, contribution
// totals, badge progress, and a capped recent-contributions list — all
// computed server-side from account-owned source data (updates, cats),
// never from a client-supplied counter.
type ProfileService struct {
	db ProfileStore
}

func NewProfileService(db ProfileStore) *ProfileService {
	return &ProfileService{db: db}
}

// ContributionTotals mirrors the approved prototype's contributionTotals()
// — plain counts over an account's own authored contributions.
type ContributionTotals struct {
	Updates      int
	Helps        int
	CatsAdded    int
	DistinctCats int
}

// RecentContribution is one entry of the profile's newest-first recent
// contributions list, mirroring the approved prototype's profile row
// (prototype/app.js's contribRowHTML) — statuses/needs-help fields are the
// same machine-readable shape GET /v1/cats/{cat_id}/updates already
// returns, so the client composes display copy the same way it already
// does for the cat-detail timeline, rather than the server inventing a
// second, pre-composed label string.
type RecentContribution struct {
	Type                   contributionKind
	CatID                  string
	CatName                string
	CatPrimaryPhoto        *string
	Statuses               []string
	NeedsHelpCategory      *string
	NeedsHelpCategoryLabel *string
	CreatedAt              time.Time
}

// Profile is the full GET /v1/me/profile representation.
type Profile struct {
	DisplayName         *string
	Totals              ContributionTotals
	Badges              []BadgeStatus
	RecentContributions []RecentContribution
}

// gatherContributions fetches an account's three contribution sources and
// merges them into one slice — not necessarily sorted; badgeProgress sorts
// its own copy, and GetProfile/GetBadges sort separately for their own
// newest-first vs. oldest-first needs.
func (s *ProfileService) gatherContributions(ctx context.Context, userID pgtype.UUID) ([]contributionEvent, error) {
	ordinary, err := s.db.ListUserOrdinaryUpdatesForBadges(ctx, userID)
	if err != nil {
		return nil, err
	}
	needsHelp, err := s.db.ListUserNeedsHelpUpdatesForBadges(ctx, userID)
	if err != nil {
		return nil, err
	}
	createdCats, err := s.db.ListUserCreatedCatsForBadges(ctx, userID)
	if err != nil {
		return nil, err
	}

	events := make([]contributionEvent, 0, len(ordinary)+len(needsHelp)+len(createdCats))
	for _, r := range ordinary {
		events = append(events, contributionEvent{
			Kind:      contributionOrdinary,
			CatID:     uuid.UUID(r.CatID.Bytes),
			CreatedAt: r.CreatedAt.Time,
			Seq:       r.Seq.Int64,
			Statuses:  r.Statuses,
		})
	}
	for _, r := range needsHelp {
		events = append(events, contributionEvent{
			Kind:              contributionNeedsHelp,
			CatID:             uuid.UUID(r.CatID.Bytes),
			CreatedAt:         r.CreatedAt.Time,
			Seq:               r.Seq.Int64,
			NeedsHelpCategory: r.NeedsHelpCategory.String,
		})
	}
	for _, r := range createdCats {
		events = append(events, contributionEvent{
			Kind:      contributionCatAdded,
			CatID:     uuid.UUID(r.CatID.Bytes),
			CreatedAt: r.CreatedAt.Time,
		})
	}
	return events, nil
}

// contributionTotals mirrors the approved prototype's contributionTotals():
// plain counts, no badge logic involved.
func contributionTotals(events []contributionEvent) ContributionTotals {
	var t ContributionTotals
	distinct := map[uuid.UUID]bool{}
	for _, e := range events {
		distinct[e.CatID] = true
		switch e.Kind {
		case contributionOrdinary:
			t.Updates++
		case contributionNeedsHelp:
			t.Helps++
		case contributionCatAdded:
			t.CatsAdded++
		}
	}
	t.DistinctCats = len(distinct)
	return t
}

// recentContributions returns the newest-first, capped slice of events the
// profile screen renders — display fields (cat name/photo) are resolved
// separately (see GetProfile) for only these capped events, never the
// account's full history.
func recentContributions(events []contributionEvent) []contributionEvent {
	sorted := append([]contributionEvent(nil), events...)
	sort.SliceStable(sorted, func(i, j int) bool {
		if !sorted[i].CreatedAt.Equal(sorted[j].CreatedAt) {
			return sorted[i].CreatedAt.After(sorted[j].CreatedAt)
		}
		return sorted[i].Seq > sorted[j].Seq
	})
	if len(sorted) > recentContributionsLimit {
		sorted = sorted[:recentContributionsLimit]
	}
	return sorted
}

// GetProfile answers GET /v1/me/profile for userID (the caller's own
// account, resolved from Authorization: Bearer — this slice never exposes
// another account's profile). display_name/badges/totals/recent
// contributions are all derived from account-owned server data; nothing
// here is ever accepted from the client.
func (s *ProfileService) GetProfile(ctx context.Context, userID string) (Profile, error) {
	userUUID, err := uuid.Parse(userID)
	if err != nil {
		return Profile{}, err
	}
	pgUserID := pgtype.UUID{Bytes: userUUID, Valid: true}

	// userID always comes from a valid, already-validated bearer session
	// (RequireBearer resolves it before this is ever called), so
	// pgx.ErrNoRows here is not a real "profile not found" case to map to
	// a dedicated sentinel — it's just propagated as-is; the handler
	// answers any error here with a generic 500.
	user, err := s.db.GetUserByID(ctx, pgUserID)
	if err != nil {
		return Profile{}, err
	}

	events, err := s.gatherContributions(ctx, pgUserID)
	if err != nil {
		return Profile{}, err
	}

	recent := recentContributions(events)
	catIDs := make([]pgtype.UUID, 0, len(recent))
	seen := map[uuid.UUID]bool{}
	for _, e := range recent {
		if !seen[e.CatID] {
			seen[e.CatID] = true
			catIDs = append(catIDs, pgtype.UUID{Bytes: e.CatID, Valid: true})
		}
	}
	summaries := map[uuid.UUID]repository.GetCatSummariesByIDsRow{}
	if len(catIDs) > 0 {
		rows, err := s.db.GetCatSummariesByIDs(ctx, catIDs)
		if err != nil {
			return Profile{}, err
		}
		for _, r := range rows {
			summaries[uuid.UUID(r.ID.Bytes)] = r
		}
	}

	recentOut := make([]RecentContribution, 0, len(recent))
	for _, e := range recent {
		rc := RecentContribution{
			Type:      e.Kind,
			CatID:     e.CatID.String(),
			CreatedAt: e.CreatedAt,
		}
		if e.Kind == contributionOrdinary {
			rc.Statuses = e.Statuses
		}
		if e.Kind == contributionNeedsHelp {
			category := e.NeedsHelpCategory
			label := needsHelpCategoryLabels[category]
			rc.NeedsHelpCategory = &category
			rc.NeedsHelpCategoryLabel = &label
		}
		if summary, ok := summaries[e.CatID]; ok {
			rc.CatName = summary.Name.String
			if summary.PhotoUrl != "" {
				photo := summary.PhotoUrl
				rc.CatPrimaryPhoto = &photo
			}
		}
		recentOut = append(recentOut, rc)
	}

	return Profile{
		DisplayName:         textPtr(user.DisplayName),
		Totals:              contributionTotals(events),
		Badges:              badgeProgress(events),
		RecentContributions: recentOut,
	}, nil
}

// GetBadges answers GET /v1/me/badges: the same derivation GetProfile uses,
// without the totals/recent-contributions display work a client asking
// only for badges doesn't need.
func (s *ProfileService) GetBadges(ctx context.Context, userID string) ([]BadgeStatus, error) {
	userUUID, err := uuid.Parse(userID)
	if err != nil {
		return nil, err
	}
	pgUserID := pgtype.UUID{Bytes: userUUID, Valid: true}
	events, err := s.gatherContributions(ctx, pgUserID)
	if err != nil {
		return nil, err
	}
	return badgeProgress(events), nil
}
