# tekir — mvp prototype

Built for issue #47: a complete, interactive prototype covering every mvp screen, flow and state,
for the founders to review together and approve as the implementation reference. Not Figma — no
build step or framework, opens directly as `index.html` or runs from a simple static server.

Note: the in-app product copy (button labels, cat statuses, screen text) is intentionally in Turkish —
Turkish street-cat helpers are the primary audience for the real product. This README, the design
system's own labels, and everything else in the repo (code, comments, commits) are in English.

## running it

```
cd prototype
python3 -m http.server 8000
```

then open `http://localhost:8000`. double-clicking `index.html` to open it via `file://` also works;
the map needs an internet connection — without one it falls back to a static patterned background,
with the cat markers still visible. use the "çevrimdışı durumu göster" toggle in settings to demo
the offline state without actually disconnecting.

demo login: phone `555 111 22 33` signs in as a seeded account (Deniz) with contribution history,
follows and near-complete badge progress — the feeder badge is deliberately one update away from
earning, so a live "fed" submission during the review demonstrates the badge-celebration toast. any
other number signs in as a brand-new, empty account. any verification code is accepted.

## files

- `index.html` — app shell: 15 screens + 3 device-level overlays (auth sheet, notification
  permission modal, offline banner)
- `styles.css` — design tokens (color, typography, spacing, radius, elevation) + reusable component classes
- `icons.js` — shared svg icon set, used by both the app and design-system.html
- `data.js` — mock clock, seed cats/updates, badge definitions and every pure derivation helper
  (freshness, active alert, water/food lines, badge progress). no dom access — app.js and map.js
  read from it.
- `map.js` — leaflet map, markers, clusters, the add-cat location picker map, and the static
  no-internet fallback
- `app.js` — screen rendering, state, navigation, auth gating, event delegation
- `design-system.html` — screen-independent component/token catalog, uses the same `styles.css`

## screens

splash · location permission · map (with cluster, marker, and cat-preview sheet) · cat detail ·
full update history · add update · needs-help report · add-cat location picker (with duplicate-cat
candidate modal) · add-cat details · discover (nearby / needs-help / following tabs) · profile ·
badges list · badge detail · settings/permissions · sign-in (phone + code).

the "authentication requirement" state is the reusable auth-sheet overlay (`requireLogin()` in
app.js) — it opens over whichever screen the user is on and offers "giriş yap", which pushes to the
full sign-in screen. every write action (post an update, report needs-help, add a cat, follow a cat)
gates here before any form is shown, never after.

## data model

everything shown about a cat — freshness tier, active alert, last-seen text, water/food lines, badge
progress — is derived from its `updates` array in `data.js`, never stored as a separate field. an
update is `{ kind:'update'|'help', statuses:[...], helpReason, comment, photo, createdAt, authorId,
authorName }`. this keeps the seed data and live demo contributions (typed during the review)
consistent by construction — there's no separate "session contribution counter" to fall out of sync.

## map

leaflet + openstreetmap, via cdn (`unpkg.com/leaflet`). centered on kadıköy/moda, street-level zoom.
if the leaflet cdn fails to load, or tile requests fail, the app automatically falls back to rendering
the same cat markers as absolutely-positioned elements over a static grid background — the map never
goes empty. this fallback is exercised by both the synchronous init-failure path and leaflet's async
`tileerror` event, through one shared `activateMapFallback()` function.

## cat photos

All real, CC-licensed street cat photographs sourced from wikimedia commons:

| used for | file | photographer | license |
|---|---|---|---|
| Portakal (photo 1) | [Cat near Kabataş in Istanbul](https://commons.wikimedia.org/wiki/File:Cat_near_Kabata%C5%9F_in_Istanbul,_20260605_1734_1298.jpg) | Jakub Hałun | CC BY 4.0 |
| Zeytin, Sultan (photo 2) | [Cats, Kadikoey, Istanbul](https://commons.wikimedia.org/wiki/File:Cats,_Kadikoey,_Istanbul_(P1100168).jpg) | Matti Blume | CC BY-SA |
| Sultan (photo 1), Minnoş | [Istanbul - cat of Sultanahmet](https://commons.wikimedia.org/wiki/File:Istanbul_-_cat_of_Sultanahmet.jpg) | Jorge Franganillo | CC BY 4.0 |
| balat-beyaz (unnamed) | [Old Istanbul Cat](https://commons.wikimedia.org/wiki/File:Old_Istanbul_Cat.jpg) | Amak-i Hayal | CC BY-SA 4.0 |
| Duman | [Cat, Istanbul (P1180136)](https://commons.wikimedia.org/wiki/File:Cat,_Istanbul_(P1180136).jpg) | Matti Blume | CC BY-SA |
| Kaplan, Pamuk | [Turkey (Istanbul) Street cat](https://commons.wikimedia.org/wiki/File:Turkey_(Istanbul)_Street_cat_(21956691179).jpg) | Flickr / f_snarfel | CC BY 2.0 |
| Sarman | [Cat on Turkish Carpets, Grand Bazaar Istanbul](https://commons.wikimedia.org/wiki/File:Cat_on_Turkish_Carpets_Grand_Bazaar_Istanbul_2026.jpg) | *unverified — confirm photographer/license on commons before shipping* | *TBD* |
| Boncuk | [Cat sleeping on utility box, Şişhane Istanbul](https://commons.wikimedia.org/wiki/File:Cat_sleeping_on_utility_box_Sishane_Istanbul_2024.jpg) | *unverified* | *TBD* |
| Fıstık, demo user avatar | [Curious street cat in Istanbul, Türkiye 2023](https://commons.wikimedia.org/wiki/File:Curious_street_cat_in_Istanbul_-_T%C3%BCrkiye,_2023.jpg) | *unverified* | *TBD* |
| Sultan (photo 3), Gölge | [Street cat in Istanbul, Türkiye 2023](https://commons.wikimedia.org/wiki/File:Street_cat_in_Istanbul_-_T%C3%BCrkiye,_2023.jpg) | *unverified* | *TBD* |

the four rows marked *unverified* were added to widen the seed set beyond the original six; their
wikimedia file page is linked but the photographer/license cell wasn't invented here — confirm both
directly on commons before this prototype's photo set is treated as final/shippable.

if an image fails to load (`onerror`), every `<img>` falls back to a paw-icon placeholder in the brand
color — no empty gray placeholders.

## scoped-out / adapted decisions

- per `docs/product/trust.md` (as of the "require authentication for contributions" product
  decision): posting **any** update — including a plain text-only "seen" — and following a cat both
  require a phone-verified authenticated account. there is no anonymous contribution path in this
  prototype; every write action (update, needs-help report, add cat, follow) opens the auth-sheet
  overlay at the moment of intent, before any form is shown.
- per `docs/product/updates.md`: `seen` is a one-tap action from cat detail (no form, no comment, no
  photo) — separate from the multi-select "durum güncellemesi ekle" flow, which lets `seen`, `fed`
  and `water_provided` be combined in one submission.
- per `docs/product/alerts.md`: needs-help is a single-select reason picker, its own screen and flow,
  not a variant of the structured-update form — it carries one reason from a fixed vocabulary, expires
  automatically 72h after creation, and has no resolve action.
- per `docs/product/badges.md`: the five mvp badges (first_sighting, feeder, water_helper,
  neighborhood_watcher, cats_of_istanbul) are fully derived from update/cat-creation history, with no
  points, streaks or leaderboard anywhere in the prototype.
- per `docs/product/notifications.md`: there's no notification inbox/tab — the only notification
  surface is the permission prompt shown once, after a user's first successful follow.
- per `docs/product/cats.md` / `trust.md`: the add-cat duplicate-candidate modal never blocks
  creation — "hayır, farklı bir kedi" always continues, matching "duplicate detection must not block
  contribution."
- the first submission of any kind (update, needs-help, add-cat) in a session is deliberately
  simulated to fail once, to demonstrate the error + "tekrar dene" state; subsequent attempts succeed
  normally. the settings screen's "çevrimdışı durumu göster" toggle forces every submission to fail
  for as long as it's on, for demoing the offline state on demand.
- the "add cat: location" screen starts centered near an existing cat (Portakal) on purpose, so the
  duplicate-candidate modal is reachable on the very first try.
- per `docs/product/cats.md`: permanent personality traits are not collected on add-cat and not shown
  on cat detail; behavioral notes only ever live in an update's free-text comment.
- an unnamed cat's display name shows a plain "İsimsiz kedi" placeholder — `docs/product/cats.md`'s
  "friendly random name" assignment idea is a separate, later product decision, not invented here.
