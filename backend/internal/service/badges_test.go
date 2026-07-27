package service

import (
	"testing"
	"time"

	"github.com/google/uuid"
)

func ordinaryEvent(cat uuid.UUID, at time.Time, seq int64, statuses ...string) contributionEvent {
	return contributionEvent{Kind: contributionOrdinary, CatID: cat, CreatedAt: at, Seq: seq, Statuses: statuses}
}

func badgeByID(statuses []BadgeStatus, id string) BadgeStatus {
	for _, s := range statuses {
		if s.Def.ID == id {
			return s
		}
	}
	panic("badge not found: " + id)
}

func TestBadgeProgress_FirstSighting(t *testing.T) {
	cat := uuid.New()
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

	notEarned := badgeProgress(nil)
	b := badgeByID(notEarned, "first_sighting")
	if b.Earned || b.Value != 0 {
		t.Fatalf("expected not earned with 0 contributions, got %+v", b)
	}

	events := []contributionEvent{ordinaryEvent(cat, base, 1, "seen")}
	earned := badgeByID(badgeProgress(events), "first_sighting")
	if !earned.Earned || earned.Value != 1 {
		t.Fatalf("expected earned after the first seen update, got %+v", earned)
	}
	if earned.EarnedAt == nil || !earned.EarnedAt.Equal(base) {
		t.Fatalf("expected earned_at %v, got %v", base, earned.EarnedAt)
	}
}

func TestBadgeProgress_Feeder_ExactThreshold(t *testing.T) {
	cat := uuid.New()
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

	// 4 fed updates: not yet earned.
	events := make([]contributionEvent, 0, 4)
	for i := 0; i < 4; i++ {
		events = append(events, ordinaryEvent(cat, base.Add(time.Duration(i)*time.Hour), int64(i), "fed"))
	}
	notYet := badgeByID(badgeProgress(events), "feeder")
	if notYet.Earned || notYet.Value != 4 {
		t.Fatalf("expected 4/5, not earned, got %+v", notYet)
	}

	// the 5th fed update crosses the threshold; earned_at pins to it.
	fifthAt := base.Add(4 * time.Hour)
	events = append(events, ordinaryEvent(cat, fifthAt, 4, "fed"))
	earned := badgeByID(badgeProgress(events), "feeder")
	if !earned.Earned || earned.Value != 5 {
		t.Fatalf("expected 5/5, earned, got %+v", earned)
	}
	if earned.EarnedAt == nil || !earned.EarnedAt.Equal(fifthAt) {
		t.Fatalf("expected earned_at pinned to the 5th fed update (%v), got %v", fifthAt, earned.EarnedAt)
	}
}

func TestBadgeProgress_WaterHelper_ExactThreshold(t *testing.T) {
	cat := uuid.New()
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

	events := make([]contributionEvent, 0, 5)
	for i := 0; i < 5; i++ {
		events = append(events, ordinaryEvent(cat, base.Add(time.Duration(i)*time.Hour), int64(i), "water_provided"))
	}
	earned := badgeByID(badgeProgress(events), "water_helper")
	if !earned.Earned || earned.Value != 5 {
		t.Fatalf("expected 5/5, earned, got %+v", earned)
	}
}

func TestBadgeProgress_NeighborhoodWatcher_DoesNotDoubleCountSameCat(t *testing.T) {
	cat := uuid.New()
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

	// 15 "seen" updates, but all on the same cat: neighborhood_watcher needs
	// 10 DISTINCT cats, so this must never earn it.
	events := make([]contributionEvent, 0, 15)
	for i := 0; i < 15; i++ {
		events = append(events, ordinaryEvent(cat, base.Add(time.Duration(i)*time.Hour), int64(i), "seen"))
	}
	notEarned := badgeByID(badgeProgress(events), "neighborhood_watcher")
	if notEarned.Earned || notEarned.Value != 1 {
		t.Fatalf("expected value 1 (one distinct cat), not earned, got %+v", notEarned)
	}

	// 10 distinct cats, one seen update each: now earned.
	events = events[:0]
	for i := 0; i < 10; i++ {
		events = append(events, ordinaryEvent(uuid.New(), base.Add(time.Duration(i)*time.Hour), int64(i), "seen"))
	}
	earned := badgeByID(badgeProgress(events), "neighborhood_watcher")
	if !earned.Earned || earned.Value != 10 {
		t.Fatalf("expected 10/10 distinct cats, earned, got %+v", earned)
	}
}

func TestBadgeProgress_CatsOfIstanbul_CountsAcrossContributionTypes(t *testing.T) {
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

	var events []contributionEvent
	// 10 ordinary-update cats, 10 needs-help cats, 5 created cats = 25 distinct.
	for i := 0; i < 10; i++ {
		events = append(events, ordinaryEvent(uuid.New(), base.Add(time.Duration(i)*time.Hour), int64(i), "seen"))
	}
	for i := 0; i < 10; i++ {
		events = append(events, contributionEvent{
			Kind: contributionNeedsHelp, CatID: uuid.New(),
			CreatedAt: base.Add(time.Duration(10+i) * time.Hour), Seq: int64(10 + i),
		})
	}
	for i := 0; i < 5; i++ {
		events = append(events, contributionEvent{
			Kind: contributionCatAdded, CatID: uuid.New(),
			CreatedAt: base.Add(time.Duration(20+i) * time.Hour),
		})
	}

	earned := badgeByID(badgeProgress(events), "cats_of_istanbul")
	if !earned.Earned || earned.Value != 25 {
		t.Fatalf("expected 25/25 distinct cats across all contribution types, earned, got %+v", earned)
	}
}

func TestBadgeProgress_SoftDeletedUpdatesMustBeExcludedByCaller(t *testing.T) {
	// badgeProgress itself has no notion of "deleted" — it trusts its input
	// entirely. This test documents that contract: the caller
	// (ProfileService.gatherContributions, backed by
	// ListUserOrdinaryUpdatesForBadges' "and u.deleted_at is null" filter)
	// is responsible for never handing a soft-deleted update to
	// badgeProgress at all. Four fed updates here (all live) must not earn
	// feeder; a 5th, soft-deleted one is simply never included.
	cat := uuid.New()
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	events := make([]contributionEvent, 0, 4)
	for i := 0; i < 4; i++ {
		events = append(events, ordinaryEvent(cat, base.Add(time.Duration(i)*time.Hour), int64(i), "fed"))
	}
	notEarned := badgeByID(badgeProgress(events), "feeder")
	if notEarned.Earned || notEarned.Value != 4 {
		t.Fatalf("expected 4/5 with the deleted 5th excluded from input, got %+v", notEarned)
	}
}

func TestBadgeProgress_MultiDeviceContributionsAccumulateTogether(t *testing.T) {
	// badge derivation is keyed on author_user_id only (see
	// ListUserOrdinaryUpdatesForBadges) — device identity never appears in
	// contributionEvent at all, so two devices under the same account
	// necessarily accumulate together. This test documents that the events
	// simply merge regardless of originating device.
	cat := uuid.New()
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	deviceAEvents := []contributionEvent{
		ordinaryEvent(cat, base, 0, "fed"),
		ordinaryEvent(cat, base.Add(time.Hour), 1, "fed"),
	}
	deviceBEvents := []contributionEvent{
		ordinaryEvent(cat, base.Add(2*time.Hour), 2, "fed"),
		ordinaryEvent(cat, base.Add(3*time.Hour), 3, "fed"),
		ordinaryEvent(cat, base.Add(4*time.Hour), 4, "fed"),
	}
	merged := append(append([]contributionEvent{}, deviceAEvents...), deviceBEvents...)

	earned := badgeByID(badgeProgress(merged), "feeder")
	if !earned.Earned || earned.Value != 5 {
		t.Fatalf("expected 5/5 combining both devices' contributions, got %+v", earned)
	}
}

func TestBadgeProgress_AllFiveBadgesAlwaysReturnedInOrder(t *testing.T) {
	statuses := badgeProgress(nil)
	if len(statuses) != 5 {
		t.Fatalf("expected all 5 fixed mvp badges returned even with no contributions, got %d", len(statuses))
	}
	wantOrder := []string{"first_sighting", "feeder", "water_helper", "neighborhood_watcher", "cats_of_istanbul"}
	for i, id := range wantOrder {
		if statuses[i].Def.ID != id {
			t.Errorf("expected badge %d to be %q, got %q", i, id, statuses[i].Def.ID)
		}
		if statuses[i].Earned {
			t.Errorf("expected badge %q not earned with no contributions", id)
		}
	}
}

func TestBadgeProgress_ValueNeverExceedsTarget(t *testing.T) {
	cat := uuid.New()
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	events := make([]contributionEvent, 0, 12)
	for i := 0; i < 12; i++ {
		events = append(events, ordinaryEvent(cat, base.Add(time.Duration(i)*time.Hour), int64(i), "fed"))
	}
	b := badgeByID(badgeProgress(events), "feeder")
	if b.Value != b.Def.Target {
		t.Fatalf("expected displayed value capped at target %d, got %d", b.Def.Target, b.Value)
	}
}
