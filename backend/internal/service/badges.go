package service

import (
	"sort"
	"time"

	"github.com/google/uuid"
)

// BadgeDefinition is one entry of the fixed mvp badge vocabulary
// (docs/product/badges.md, issue #80) — ported verbatim (id/name/icon/
// condition/descr strings and thresholds) from the approved prototype's
// BADGE_DEFS (prototype/data.js) so the flutter client's copy matches
// without re-deriving it. The vocabulary is closed for mvp: badges are
// never invented, added, or removed by a client, and a badge, once
// earned, is never revoked merely because this list changes later
// (docs/product/badges.md: "badge thresholds may change only for future
// earnings").
type BadgeDefinition struct {
	ID        string
	Name      string
	Icon      string
	Target    int
	Condition string
	Descr     string
}

// BadgeDefs is the fixed, ordered mvp badge vocabulary. Order matches the
// prototype and docs/product/badges.md, and is the order a client should
// render badges in (never alphabetical or by earned-first).
var BadgeDefs = []BadgeDefinition{
	{
		ID: "first_sighting", Name: "İlk Görüş", Icon: "eye", Target: 1,
		Condition: `İlk "Görüldü" güncellemeni paylaş.`,
		Descr:     "Bir kediyi görüp haber verdin. Her şey görmekle başlar.",
	},
	{
		ID: "feeder", Name: "Mamacı", Icon: "bowl", Target: 5,
		Condition: `5 kez "Mama verildi" güncellemesi paylaş.`,
		Descr:     "Mahallenin kedileri sayende aç kalmıyor.",
	},
	{
		ID: "water_helper", Name: "Sucu", Icon: "droplet", Target: 5,
		Condition: `5 kez "Su verildi" güncellemesi paylaş.`,
		Descr:     "Temiz su, en az mama kadar önemli. Kaseleri boş bırakmadın.",
	},
	{
		ID: "neighborhood_watcher", Name: "Mahalle Bekçisi", Icon: "pin", Target: 10,
		Condition: `10 farklı kedi için "Görüldü" güncellemesi paylaş.`,
		Descr:     "Mahallendeki kedilerin gözü kulağı oldun.",
	},
	{
		ID: "cats_of_istanbul", Name: "İstanbul'un Kedileri", Icon: "paw", Target: 25,
		Condition: "Güncelleme, fotoğraf veya yeni kedi ekleyerek 25 farklı kediye katkıda bulun.",
		Descr:     "Şehrin kedileri seni tanıyor. Bu rozet, İstanbul'a emeğin için.",
	},
}

// BadgeStatus is one badge's derived progress for a specific account,
// ready for the profile/badges endpoints to serialize directly.
type BadgeStatus struct {
	Def      BadgeDefinition
	Value    int
	Earned   bool
	EarnedAt *time.Time
}

// contributionKind discriminates the three event shapes badge derivation
// and the profile's recent-contributions list both walk — never persisted,
// only ever constructed in memory from the three ListUser*ForBadges queries.
type contributionKind string

const (
	contributionOrdinary  contributionKind = "update"
	contributionNeedsHelp contributionKind = "help"
	contributionCatAdded  contributionKind = "cat_added"
)

// contributionEvent is one authenticated contribution toward badge
// progress and the profile's recent-contributions list — the Go
// equivalent of the approved prototype's userContributions() entries
// (prototype/data.js), assembled in ProfileService.gatherContributions
// from three separate, simple queries rather than one large sql union.
type contributionEvent struct {
	Kind      contributionKind
	CatID     uuid.UUID
	CreatedAt time.Time
	Seq       int64 // tie-breaker among updates sharing a timestamp; 0 for cat_added
	// Statuses is only ever populated for Kind == contributionOrdinary.
	Statuses []string
	// NeedsHelpCategory is only ever populated for Kind == contributionNeedsHelp.
	NeedsHelpCategory string
}

// badgeProgress derives each badge's current progress for one account from
// its full contribution history, mirroring the approved prototype's
// badgeProgress() (prototype/data.js) exactly: events are walked
// oldest-to-newest so "earned at" lands on the specific contribution that
// crossed each threshold. Pure and deterministic — the same events always
// produce the same result, calling it twice is a no-op, and it has no
// wall-clock or external-state dependency (badge thresholds are counts,
// never time-windowed). events need not be pre-sorted; this function sorts
// its own copy.
//
// Known mvp limitation (accepted, docs/architecture/db.md/badges.md
// document this explicitly): badges are derived at read time, not cached,
// so deleting the exact ordinary update that crossed a threshold — only
// possible within its own 10-minute correction window, see
// CatsService.DeleteOwnUpdate — can make a badge appear transiently
// un-earned again on next view, in tension with badges.md's "permanent
// once earned". This is accepted rather than adding a `user_badges`
// earned-pin table for this mvp slice.
func badgeProgress(events []contributionEvent) []BadgeStatus {
	sorted := append([]contributionEvent(nil), events...)
	sort.SliceStable(sorted, func(i, j int) bool {
		if !sorted[i].CreatedAt.Equal(sorted[j].CreatedAt) {
			return sorted[i].CreatedAt.Before(sorted[j].CreatedAt)
		}
		return sorted[i].Seq < sorted[j].Seq
	})

	counts := map[string]int{}
	seenCats := map[uuid.UUID]bool{}
	allCats := map[uuid.UUID]bool{}
	var firstSeenAt *time.Time
	thresholdAt := map[string]time.Time{}

	for _, e := range sorted {
		at := e.CreatedAt
		allCats[e.CatID] = true

		if e.Kind == contributionOrdinary {
			for _, s := range e.Statuses {
				counts[s]++
				if s == "seen" {
					if firstSeenAt == nil {
						t := at
						firstSeenAt = &t
					}
					seenCats[e.CatID] = true
					if len(seenCats) == BadgeDefs[3].Target { // neighborhood_watcher
						if _, ok := thresholdAt["neighborhood_watcher"]; !ok {
							thresholdAt["neighborhood_watcher"] = at
						}
					}
				}
				if s == "fed" && counts["fed"] == BadgeDefs[1].Target { // feeder
					if _, ok := thresholdAt["feeder"]; !ok {
						thresholdAt["feeder"] = at
					}
				}
				if s == "water_provided" && counts["water_provided"] == BadgeDefs[2].Target { // water_helper
					if _, ok := thresholdAt["water_helper"]; !ok {
						thresholdAt["water_helper"] = at
					}
				}
			}
		}

		if len(allCats) == BadgeDefs[4].Target { // cats_of_istanbul
			if _, ok := thresholdAt["cats_of_istanbul"]; !ok {
				thresholdAt["cats_of_istanbul"] = at
			}
		}
	}

	firstSightingValue := 0
	if firstSeenAt != nil {
		firstSightingValue = 1
	}
	rawValue := map[string]int{
		"first_sighting":       firstSightingValue,
		"feeder":               counts["fed"],
		"water_helper":         counts["water_provided"],
		"neighborhood_watcher": len(seenCats),
		"cats_of_istanbul":     len(allCats),
	}
	rawEarnedAt := map[string]*time.Time{
		"first_sighting": firstSeenAt,
	}
	for _, id := range []string{"feeder", "water_helper", "neighborhood_watcher", "cats_of_istanbul"} {
		if t, ok := thresholdAt[id]; ok {
			tt := t
			rawEarnedAt[id] = &tt
		}
	}

	statuses := make([]BadgeStatus, 0, len(BadgeDefs))
	for _, def := range BadgeDefs {
		value := rawValue[def.ID]
		earned := value >= def.Target
		display := value
		if display > def.Target {
			display = def.Target
		}
		status := BadgeStatus{Def: def, Value: display, Earned: earned}
		if earned {
			status.EarnedAt = rawEarnedAt[def.ID]
		}
		statuses = append(statuses, status)
	}
	return statuses
}
