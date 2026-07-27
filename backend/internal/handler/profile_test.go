package handler

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/tekiristanbul/tekir/backend/internal/service"
)

// fakeProfileProvider is an in-process stub for ProfileProvider, mirroring
// fakeNotificationInboxManager's shape.
type fakeProfileProvider struct {
	profile    service.Profile
	profileErr error

	badges    []service.BadgeStatus
	badgesErr error

	capturedProfileUser *string
	capturedBadgesUser  *string
}

func (f fakeProfileProvider) GetProfile(_ context.Context, userID string) (service.Profile, error) {
	if f.capturedProfileUser != nil {
		*f.capturedProfileUser = userID
	}
	return f.profile, f.profileErr
}

func (f fakeProfileProvider) GetBadges(_ context.Context, userID string) ([]service.BadgeStatus, error) {
	if f.capturedBadgesUser != nil {
		*f.capturedBadgesUser = userID
	}
	return f.badges, f.badgesErr
}

// allUnearnedBadgesForTest builds the all-5-badges, none-earned shape
// GetProfile/GetBadges return for an account with no contributions yet —
// built from the exported service.BadgeDefs rather than reaching into the
// unexported badgeProgress derivation, since handler tests only care that
// the response serializes the fixed vocabulary correctly.
func allUnearnedBadgesForTest() []service.BadgeStatus {
	statuses := make([]service.BadgeStatus, 0, len(service.BadgeDefs))
	for _, def := range service.BadgeDefs {
		statuses = append(statuses, service.BadgeStatus{Def: def})
	}
	return statuses
}

func routerForProfile(h *ProfileHandler, validator AccessTokenValidator) http.Handler {
	r := chi.NewRouter()
	r.With(RequireBearer(validator)).Get("/v1/me/profile", h.Profile)
	r.With(RequireBearer(validator)).Get("/v1/me/badges", h.Badges)
	return r
}

func TestProfileHandler_Profile_Success(t *testing.T) {
	userID := uuid.New().String()
	displayName := "Ada"
	var capturedUser string

	h := NewProfileHandler(fakeProfileProvider{
		capturedProfileUser: &capturedUser,
		profile: service.Profile{
			DisplayName: &displayName,
			Totals:      service.ContributionTotals{Updates: 3, Helps: 1, CatsAdded: 0, DistinctCats: 2},
			Badges:      allUnearnedBadgesForTest(),
		},
	})

	rec := httptest.NewRecorder()
	req := withBearerToken(httptest.NewRequest(http.MethodGet, "/v1/me/profile", nil))
	routerForProfile(h, fakeAccessValidator{userID: userID}).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if capturedUser != userID {
		t.Errorf("expected caller's own user id %s, got %s", userID, capturedUser)
	}

	var body profileResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.DisplayName == nil || *body.DisplayName != displayName {
		t.Errorf("unexpected display_name: %v", body.DisplayName)
	}
	if body.ContributionTotals.Updates != 3 || body.ContributionTotals.DistinctCats != 2 {
		t.Errorf("unexpected contribution_totals: %+v", body.ContributionTotals)
	}
	if len(body.Badges) != 5 {
		t.Errorf("expected all 5 fixed badges, got %d", len(body.Badges))
	}
}

func TestProfileHandler_Profile_NoDisplayNameIsNull(t *testing.T) {
	h := NewProfileHandler(fakeProfileProvider{profile: service.Profile{Badges: allUnearnedBadgesForTest()}})

	rec := httptest.NewRecorder()
	req := withBearerToken(httptest.NewRequest(http.MethodGet, "/v1/me/profile", nil))
	routerForProfile(h, fakeAccessValidator{userID: uuid.NewString()}).ServeHTTP(rec, req)

	var raw map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if string(raw["display_name"]) != "null" {
		t.Errorf("expected display_name null, got %s", raw["display_name"])
	}
}

// TestProfileHandler_Profile_NeverExposesPhoneOrInternalIDs is a privacy
// regression guard (docs/product/privacy.md): the raw response body must
// never contain a phone-shaped field or an internal account/device id key.
func TestProfileHandler_Profile_NeverExposesPhoneOrInternalIDs(t *testing.T) {
	h := NewProfileHandler(fakeProfileProvider{profile: service.Profile{Badges: allUnearnedBadgesForTest()}})

	rec := httptest.NewRecorder()
	req := withBearerToken(httptest.NewRequest(http.MethodGet, "/v1/me/profile", nil))
	routerForProfile(h, fakeAccessValidator{userID: uuid.NewString()}).ServeHTTP(rec, req)

	var raw map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	for _, forbidden := range []string{"phone", "user_id", "device_id", "device_token", "push_token"} {
		if _, ok := raw[forbidden]; ok {
			t.Errorf("expected profile response to never expose %q", forbidden)
		}
	}
}

func TestProfileHandler_Profile_RequiresBearer(t *testing.T) {
	h := NewProfileHandler(fakeProfileProvider{})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/me/profile", nil)
	routerForProfile(h, fakeAccessValidator{}).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestProfileHandler_Badges_Success(t *testing.T) {
	userID := uuid.New().String()
	earnedAt := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	var capturedUser string
	h := NewProfileHandler(fakeProfileProvider{
		capturedBadgesUser: &capturedUser,
		badges: []service.BadgeStatus{
			{Def: service.BadgeDefs[0], Value: 1, Earned: true, EarnedAt: &earnedAt},
		},
	})

	rec := httptest.NewRecorder()
	req := withBearerToken(httptest.NewRequest(http.MethodGet, "/v1/me/badges", nil))
	routerForProfile(h, fakeAccessValidator{userID: userID}).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if capturedUser != userID {
		t.Errorf("expected caller's own user id %s, got %s", userID, capturedUser)
	}

	var body badgesResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body.Items) != 1 || !body.Items[0].Earned || body.Items[0].ID != "first_sighting" {
		t.Fatalf("unexpected badges response: %+v", body.Items)
	}
}

func TestProfileHandler_Badges_RequiresBearer(t *testing.T) {
	h := NewProfileHandler(fakeProfileProvider{})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/me/badges", nil)
	routerForProfile(h, fakeAccessValidator{}).ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", rec.Code, rec.Body.String())
	}
}
