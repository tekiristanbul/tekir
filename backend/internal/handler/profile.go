package handler

import (
	"context"
	"net/http"
	"time"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// ProfileProvider is satisfied by service.ProfileService; kept as an
// interface so the handler is testable without a real database connection,
// mirroring NotificationInboxManager.
type ProfileProvider interface {
	GetProfile(ctx context.Context, userID string) (service.Profile, error)
	GetBadges(ctx context.Context, userID string) ([]service.BadgeStatus, error)
}

// ProfileHandler answers the minimal authenticated profile/badge surface
// (issue #80, docs/product/community.md/badges.md) — GET /v1/me/profile
// and GET /v1/me/badges, both Bearer-required and own-account-only this
// slice (no other account's profile is ever exposed).
type ProfileHandler struct {
	profile ProfileProvider
}

func NewProfileHandler(profile ProfileProvider) *ProfileHandler {
	return &ProfileHandler{profile: profile}
}

type contributionTotalsResponse struct {
	Updates      int `json:"updates"`
	Helps        int `json:"helps"`
	CatsAdded    int `json:"cats_added"`
	DistinctCats int `json:"distinct_cats"`
}

// badgeResponse is one badge's derived status — always all 5 fixed mvp
// badges (docs/product/badges.md), earned or not, never a filtered list:
// the client renders the full, non-competitive vocabulary either way.
type badgeResponse struct {
	ID        string     `json:"id"`
	Name      string     `json:"name"`
	Icon      string     `json:"icon"`
	Condition string     `json:"condition"`
	Descr     string     `json:"descr"`
	Value     int        `json:"value"`
	Target    int        `json:"target"`
	Earned    bool       `json:"earned"`
	EarnedAt  *time.Time `json:"earned_at"`
}

func toBadgeResponse(b service.BadgeStatus) badgeResponse {
	return badgeResponse{
		ID:        b.Def.ID,
		Name:      b.Def.Name,
		Icon:      b.Def.Icon,
		Condition: b.Def.Condition,
		Descr:     b.Def.Descr,
		Value:     b.Value,
		Target:    b.Def.Target,
		Earned:    b.Earned,
		EarnedAt:  b.EarnedAt,
	}
}

func toBadgeResponses(statuses []service.BadgeStatus) []badgeResponse {
	resp := make([]badgeResponse, 0, len(statuses))
	for _, s := range statuses {
		resp = append(resp, toBadgeResponse(s))
	}
	return resp
}

// recentContributionResponse is one entry of the profile's newest-first
// recent-contributions list. Statuses/needs-help fields mirror
// updateResponse's own shape (see cats.go) so the client composes display
// copy the same way it already does for the cat-detail timeline — the
// server never pre-composes a label string here.
type recentContributionResponse struct {
	Type                   string    `json:"type"`
	CatID                  string    `json:"cat_id"`
	CatName                string    `json:"cat_name"`
	CatPrimaryPhoto        *string   `json:"cat_primary_photo"`
	Statuses               []string  `json:"statuses,omitempty"`
	NeedsHelpCategory      *string   `json:"needs_help_category,omitempty"`
	NeedsHelpCategoryLabel *string   `json:"needs_help_category_label,omitempty"`
	CreatedAt              time.Time `json:"created_at"`
}

func toRecentContributionResponses(items []service.RecentContribution) []recentContributionResponse {
	resp := make([]recentContributionResponse, 0, len(items))
	for _, c := range items {
		resp = append(resp, recentContributionResponse{
			Type:                   string(c.Type),
			CatID:                  c.CatID,
			CatName:                c.CatName,
			CatPrimaryPhoto:        c.CatPrimaryPhoto,
			Statuses:               c.Statuses,
			NeedsHelpCategory:      c.NeedsHelpCategory,
			NeedsHelpCategoryLabel: c.NeedsHelpCategoryLabel,
			CreatedAt:              c.CreatedAt,
		})
	}
	return resp
}

type profileResponse struct {
	DisplayName         *string                      `json:"display_name"`
	ContributionTotals  contributionTotalsResponse   `json:"contribution_totals"`
	Badges              []badgeResponse              `json:"badges"`
	RecentContributions []recentContributionResponse `json:"recent_contributions"`
}

// Profile answers GET /v1/me/profile (Bearer required): the caller's own
// minimal profile surface, derived entirely from account-owned server
// data — never a client-supplied counter or id.
func (h *ProfileHandler) Profile(w http.ResponseWriter, r *http.Request) {
	user := UserFromContext(r.Context())
	profile, err := h.profile.GetProfile(r.Context(), user.UserID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, profileResponse{
		DisplayName: profile.DisplayName,
		ContributionTotals: contributionTotalsResponse{
			Updates:      profile.Totals.Updates,
			Helps:        profile.Totals.Helps,
			CatsAdded:    profile.Totals.CatsAdded,
			DistinctCats: profile.Totals.DistinctCats,
		},
		Badges:              toBadgeResponses(profile.Badges),
		RecentContributions: toRecentContributionResponses(profile.RecentContributions),
	})
}

type badgesResponse struct {
	Items []badgeResponse `json:"items"`
}

// Badges answers GET /v1/me/badges (Bearer required): the same derivation
// Profile uses, without the totals/recent-contributions work a caller
// asking only for badges doesn't need.
func (h *ProfileHandler) Badges(w http.ResponseWriter, r *http.Request) {
	user := UserFromContext(r.Context())
	statuses, err := h.profile.GetBadges(r.Context(), user.UserID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, badgesResponse{Items: toBadgeResponses(statuses)})
}
