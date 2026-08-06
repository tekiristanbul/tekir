# issue #121 visual parity audit — 0.2 follow-up

first deliverable of issue #121's "visual parity — delivery scope" checklist:
capture + compare + document material differences before implementation. no
code changes in this pass.

## method

source-level diff against the binding references (docs/design/
implementation-contract.md):

- `docs/design/screens/cat-profile.html` — the approved 0.2 baseline for the
  cat-profile surface (supersedes `prototype/` there).
- `docs/design/screens/app-states.html` / `docs/design/app-states.md` — the
  loading/empty/error/permission state contract, binding on every surface.
- `prototype/` (`app.js`, `styles.css`) — the visual-hierarchy and
  interaction baseline for every other implemented surface.

This is a code-vs-design-markup diff, not device screenshots — real-device
screenshots and product-owner review are separate, later items on issue
#121's own checklist and are not claimed as done here.

Screens read in full for this pass: cat-detail, map (+ marker preview
sheet), discover, profile, account. Not yet audited: badges/badge-detail,
add-cat, login, notifications — flagged below as follow-up scope, not
silently skipped.

## cat-profile — gaps vs `docs/design/screens/cat-profile.html`

The screen already gets its single-primary-action structure right
(`+ update` as the only fixed action; "gördüm" lives inside the update
sheet, not as a competing button — `cat_detail_screen.dart`'s own comments
cite the binding design correctly for this part). Confirmed gaps:

1. **Three-stat header strip missing.** The design's frame A/B show three
   tiles under the cover photo — last "görüldü", last "mama", last "su" —
   each with its own timestamp; the water tile flips to the help tint when
   stale (staleness, not a help category). The current screen has only a
   single generic `_LastUpdateRow` pill and an alert banner that only
   appears when there's an active alert. This is the "counters" the issue
   text names as still outstanding.
2. **No media tab / archive.** The design's segmented control
   ("geçmiş 38 / medya 9") switches between the update timeline and a 3-col
   photo/video grid archive with per-item "ana" (cover) badges and a
   filter row (tümü/fotoğraf/video). Nothing in `cat_detail_screen.dart`
   implements a media tab — this is the "media area" the issue names.
3. **No photo counter on the cover.** The design marks the cover as
   tappable-for-more via a bottom-right pill (camera icon + count). The
   Flutter `_HeroPhoto` code comment explicitly says no counter is
   rendered "since the design leaves its source field unverified" — still
   an open gap against the binding reference, just a previously-recorded
   one.
4. **Timeline rows carry no photo/video thumbnail.** The design's timeline
   entries show an inline `.med` thumbnail (with a play badge for video)
   under the note when the update has media. `_TimelineItem` in the
   current screen renders status chips, author-less text, and comment —
   no image/video widget at all, even when `update.photo` data exists.
5. **No author avatar in the timeline.** The design's rail shows a colored
   circular avatar with the author's initial per row. The current
   implementation shows no avatar — just plain text via `_TimelineItem`.
6. **Action-chip colors are not differentiated by type.** The design
   color-codes each action independently (fed = tan, seen = green,
   water = blue, help = deep red — see `--fedBg/--seenBg/--watBg/
   --helpDeep` in the reference). `_StatusTag` in
   `cat_detail_screen.dart` renders every status (`seen`/`fed`/
   `water_provided`) in the same single terracotta-soft pill.
7. **Name/location placement differs.** The design puts the cat's name in
   large serif type *below* the cover photo on the paper background,
   together with a "N komşu bakıyor" (followers) line. The current screen
   overlays the name + area caption directly on the photo (white text +
   shadow, bottom-left of the hero), and has no follower-count line at
   all (follower/watcher count is separately unimplemented, not just
   mis-placed).
8. **Follow control placement differs.** The design's follow (heart) icon
   sits top-right on the cover photo, glass-style, next to the back
   button. The current `FollowButton` renders as a left-aligned button in
   the body content below the photo, not on the photo itself.

Not a gap: the help-note/help-chip category-free copy, the single
`+ update` action, and the deliberate absence of trait chips are already
correct per the binding design and its own recorded open questions
(follower/"38 updates" real-totals wiring and the caretaker mark are
explicitly still-open in the reference itself, not this app's bug).

## map — gaps vs `prototype/app.js`'s `renderMap`/`renderPerm` and the
app-states permission contract

1. **Search field is entirely absent.** The prototype's map topbar has a
   `Mahalle veya sokak ara` search input pinned above the map. Issue #121
   names this explicitly ("approved search surface") — confirmed missing:
   `map_screen.dart`'s only top-positioned chrome is the notifications
   button; there is no search field, no search state, no search results
   handling anywhere in `MapScreen`.
2. **"yardım gerekiyor" filter chip is absent.** The prototype's map chip
   row toggles a needs-help-only filter over the visible markers. Nothing
   in `map_screen.dart` implements this filter or its chip.
3. **No dedicated location-permission screen.** The prototype has its own
   `perm` screen (icon, title, copy, "Konuma izin ver"/"Şimdi değil"
   actions) shown once before the map, per `app-states.html`'s permission
   contract. The current app resolves location silently via
   `initialLocationProvider` and only ever shows a small "konum alınamadı"
   fallback banner after the fact — there is no equivalent up-front
   consent screen. This matches issue #121's own checklist, which lists
   "implement the approved location-permission state" as not yet done.

## discover / profile / account

No material structural gaps found against the prototype's equivalent
screens (segmented tabs, stat tiles, empty/guest states, contribution
rows all follow the prototype's component shapes and the app's own
`AppColors`/`AppSpacing` tokens). Two prototype deviations exist here but
are already-recorded, approved departures rather than parity bugs:

- profile shows no avatar (curated-avatar selection deferred past this
  mvp slice, per `docs/product/badges.md`).
- account never displays the phone number itself (`GET /v1/me` doesn't
  return it — a documented API-driven deviation, not a visual miss).

These two screens still warrant a runtime/real-device look before
sign-off, since this pass is a source-level diff, not a rendered
comparison — but no code-level structural gap was found.

## not yet audited this pass

`badges_screen.dart`, `badge_detail_screen.dart`, `add_cat_screen.dart`,
`login_screen.dart`, `notification_optin_sheet.dart`, and
`notifications_screen.dart` were not read against the prototype in this
pass. Flagging explicitly rather than silently omitting them — they need
the same source-level diff before their own visual-parity PRs.

## prototype / design residue — quick note (non-blocking, tracked only)

`prototype/` is not residue — `docs/design/implementation-contract.md`
names it as the current binding visual/interaction baseline for every
surface except cat-profile, and this audit relied on it directly.
`docs/design/screenshots/` (past PRs' evidence screenshots) sits next to
`docs/design/screens/` (the actual authoritative reference markup,
`app-states.html` + `cat-profile.html`) — the similar naming is an easy
mix-up for a new contributor and is worth a short repo-guidance note in
the prototype-cleanup follow-up work, but doesn't block anything here.

## suggested next PRs (per issue #121's "split into reviewable PRs")

1. map: search field + needs-help filter chip + location-permission
   screen.
2. cat-profile: three-stat header strip, media tab/archive, per-update
   thumbnails, timeline avatars, per-type chip colors, cover photo
   counter, name/follow placement.
3. source-level audit + fixes for badges/add-cat/login/notifications.
4. prototype/design-residue inventory and repo-guidance update.

Each visual PR needs its own before/after screenshots and the specific
reference file used, per issue #121's constraints.
