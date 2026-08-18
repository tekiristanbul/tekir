# application states (06–14)

## goal

adopt the approved loading, empty, error, offline, permission, and launch
states as a repository-owned contract (issue #98). the browser-viewable
pixel and copy reference is `docs/design/screens/app-states.html`; this
document carries the rules: what triggers each state, its exact turkish
copy, where its data comes from, which feature owns it, and which
implementation slice ships it. the numbering here (06–14, plus 12b) is
identical to the html reference. the reference renders the states; it does
not create decisions — this document does.

dark mode and a not-found state remain undesigned and out of scope.

## sources and typography mapping

- `docs/design/screens/app-states.html` — standalone: no build step, no
  script, and no network request of any kind; typography renders through
  local fallbacks (georgia / system-ui) when the design families are not
  installed. metrics, copy, and colors are binding.
- the design files render with lora (display) and nunito (body). the app's
  tokens are fraunces (display) and work sans (body), bundled locally per
  `docs/design/implementation-contract.md`. the family maps through
  `app/lib/core/theme/app_theme.dart` (`_fontDisplay`, `_fontBody`); sizes,
  weights, and spacing from the reference are binding as-is.
- behavior and data rules still come from the product docs ([[alerts]],
  [[notifications]], [[privacy]], `docs/architecture/flutter.md`); this
  contract governs state presentation and sequencing.

## global rules

- one sentence: the title says what happened, the sub-line says why. there
  is no third sentence.
- one action: every state has exactly one primary button. an optional
  secondary action stays visually quiet. there is never a third.
- no blame: never "hata oluştu". state what did not happen, using the
  user's own words where they exist ("boncuk haritaya eklenemedi").
- data is never lost: on a failed submission the form stays filled. raw
  transport errors, ids, coordinates, and stack traces are never
  user-visible.
- empty ≠ error: an empty state is an invitation, not a failure. it never
  uses the help palette — sand-colored card, brick primary button.
- offline: the last loaded content is kept at 55% opacity (photos at
  grayscale 0.35) under a persistent dark banner. writing is not locked.
- every action target is at least 44 logical px. no state overflows at
  large system text scale.

## timing contract

| window | rule |
| --- | --- |
| 0–400 ms | show nothing. applies to **initial reads only** — most requests finish here and a flashing skeleton is noise. |
| 400 ms+ | skeleton (14) or breathing cached pins (13). |
| 1.6 s+ | one status line appears: "yakındaki kediler getiriliyor". no neighborhood name — reverse geocoding is an extra service call. |
| 6 s+ | the wait ends: switch to the error or offline state. applies to **bounded reads only** — it never cancels or visually fails an in-flight photo upload or write. |

user-triggered mutations get feedback in the same frame as the tap — the
400 ms delay never applies to them. waiting is never shown as a bare
spinner screen: the screen's future layout stands in as a skeleton, and
small spinners appear only inside buttons and inline rows.

## states

### 06 · konum yok — istanbul merkezi

- screen: map (`app/lib/features/map/`) and keşfet's two location-aware
  tabs (`app/lib/features/discover/`). shown whenever a location never
  resolves to a usable in-area position: permission denied, location
  services off, a resolve timeout, or a position outside istanbul.
- copy: one line, "konum yok — istanbul merkezi gösteriliyor"; action
  "konum iznini aç".
- visuals: a single elevated row over the working screen
  (`core/states/fallback_location_note.dart`), shared by both surfaces.
- **no location condition blocks a screen or renders as an error.** the map
  opens on greater istanbul at the fallback zoom with its cats loaded, and
  keşfet lists cats anchored on the same point. the one thing given up is
  the distance column, which is suppressed while the fallback is in effect
  — a figure measured from the istanbul center reads as "distance from you"
  and would be wrong. ordering is unaffected.
- **history (0.4.3):** this replaced a full-screen block that rendered
  instead of the map on a denied permission, and a retry-labelled error
  card on keşfet. app store review 0.4.2 hit both and rejected the build
  under guideline 2.1(a) as "the app displayed an error". the issue #121
  scope notes about a privacy sub-line and a "haritada elle mahalle seç"
  secondary action lapse with the state they described.
- slice 1.

### 07 · civarda kayıt yok

- screen: map. the map works, location is known, and the search radius
  contains no cats — an inviting empty state, not an error.
- copy: search placeholder "bu civarda ara"; card title "bu 300 metrede
  henüz kayıtlı kedi yok" — **300 m comes from the real search radius**,
  never hardcoded; card sub "gördüğün ilk kediyi eklersen mahalledeki
  herkes onu takip edebilir."; primary "ilk kediyi ekle"; secondary "alanı
  genişlet".
- visuals: sand card over the live map, dashed radius ring and sonar pulse
  on the user dot. no help palette.
- slice 1.

### 08 · takip listesi boş

- screen: discover (`app/lib/features/discover/`), "takip" filter
  selected, user follows no cats.
- copy: title "henüz kimseyi takip etmiyorsun"; sub "bir kedinin
  sayfasındaki kalbe dokun; ona yardım gerektiğinde haberin olsun.";
  quiet action "yakındakilere göz at".
- rule: the filter row stays visible and tappable — the user must read the
  emptiness as a filter result, not an empty app.
- slice 3.

### 09 · sakin gün

- screen: notifications (`app/lib/features/notifications/`), no active
  help call among followed cats. emptiness is good news: olive palette,
  never the help palette.
- copy: banner title "aktif yardım çağrısı yok"; banner sub "takip ettiğin
  4 kedi de son 3 günde görüldü."; section label "takip ettiklerin"; row
  freshness "bugün görüldü" / "dün görüldü" / "2 gün önce".
- data: the count and the freshness window come from real data —
  `GET /v1/me/follows` returns each followed cat with `last_update_at`
  (verified; see gap 9). if the source is unavailable the sub-line is
  dropped entirely, never approximated.
- slice 2.

### 10 · bağlantı yok

- screen: discover (and any list surface reusing the pattern) while the
  device is offline.
- copy: banner "çevrimdışısın" / "liste 14 dk önceki hali" — **14 dk comes
  from the timestamped response cache**; banner action "yenile"; info note
  "çevrimdışıyken güncelleme ekleyebilirsin; bağlantı gelince kendiliğinden
  gönderilir."
- rules: last loaded content is retained at 55% opacity and stays
  readable; writing is not locked; the dark banner persists until
  connectivity returns.
- **deferred — not in 0.2.** issue #99 excludes offline/cache/queue from
  the committed 0.2 scope: connectivity awareness, the timestamped
  retained-response cache, and the queued-draft promise in the info note
  all sit outside it. this section is kept as the approved design
  reference for that future work (referenced as "dilim 6" by the html);
  scheduling it requires its own contract revision and architecture
  approval first.

### 11 · gönderilemedi

- screen: add cat (`app/lib/features/add_cat/`), submission failed —
  form stays filled, entered values retained.
- copy: photo badge "yüklenemedi"; sheet title "boncuk haritaya
  eklenemedi" — the title uses the name the user typed; sheet sub
  "fotoğraf yüklenirken bağlantı koptu. yazdıkların telefonunda duruyor.";
  primary "tekrar dene"; quiet "taslak olarak sakla"; footer "bağlantı
  gelince kendiliğinden denenir"; field labels "isim", "tanıyalım diye".
- rules: the error text never references the transport layer. retry reuses
  the flow's existing idempotency-key contract
  (`docs/architecture/flutter.md`).
- slice 5 covers in-session preservation only: the form keeps its values
  and "tekrar dene" works while the app lives. "taslak olarak sakla" and
  the footer's automatic-retry promise depend on the durable draft queue,
  which issue #99 keeps **out of 0.2** — those two elements are deferred
  with it and are not rendered until that future work is approved and
  shipped. slice 5 is complete and testable without them.

### 12 · splash

- app-wide launch overlay (`app/lib/core/splash/splash_gate.dart`). the
  sequence: pin falls, paw pads settle above it, the wordmark writes,
  then the cream sheet lifts to reveal the already-mounted map.
- copy: wordmark "tekir"; tagline "kim görüldü, kim beslendi"; late status
  line "yakındaki kediler getiriliyor…".
- timing: the product target is ~820 ms; the reference page stretches the
  sequence to 3.4 s and plays it once so the sheet lift is visible. the
  gate behavior is unchanged: session-bound, cut the moment session
  restore settles, capped, 200 ms fade, **no artificial minimum display
  time**. the status line appears only when launch exceeds 1.6 s. every
  intermediate frame must be presentable on its own, because a fast launch
  cuts the sequence mid-way.
- brand status: the paw/pin lockup is an **app-state illustration only**,
  not a lasting brand change (gap 7). issue #24's independent logo process
  and its exclusions stand; the splash is revisited when #24 delivers.
- slice 4.

### 12b · splash · settled frame

- the binding, motionless form of the brand lockup.
- measurements: mark 112 × 123; wordmark 46 px display 600; tagline 13 px;
  gaps 26 and 12 px; the block sits 70 px above vertical center. ground is
  the cream radial `#fdf8f0 → #f2e2cd`; the pin is brick `#b5452f`.
- this composition deliberately supersedes issue #85's full-terracotta
  ground + lettermark tile splash (recorded in
  `docs/design/implementation-contract.md`).
- asset pipeline (gap 11): the 12b lockup is the source of truth. slice 4
  replaces `assets/splash/source/splash-mark.svg` and
  `splash-screen.svg` with the lockup and regenerates exports through
  `assets/scripts/generate.py`; `app/web/index.html`'s static splash and
  `splash_gate.dart`'s composition follow. `assets/brand/temporary/`
  remains for non-splash uses until issue #24 delivers the final logo.
- slice 4.

### 13 · harita yükleniyor

- screen: map, initial read in flight. the map ground is already visible
  at 75% opacity — no spinner screen.
- **hard limit:** the breathing placeholder circles are drawn only for
  cats with a **real cached position**. no cache → the map opens with no
  pins. an invented placeholder position claims a cat exists where none
  is known (gap 3).
- status band "yakındaki kediler getiriliyor" appears only after 1.6 s.
  search bar shows a shimmer skeleton. sonar pulse on the user dot.
- slice 1.

### 14 · liste iskeleti

- screen: discover, initial read in flight.
- the skeleton row has the real card's exact geometry — 52 px photo,
  14 px corner radius, same badge row — so nothing jumps when data
  arrives. rows fade in decreasing opacity with staggered shimmer.
- never visible before 400 ms.
- slice 3.

## mutation affordances

- **button · submitting**: the button stays in place, its label changes
  ("haritaya ekleniyor"), its color darkens one tone, its width is fixed,
  and a small spinner joins the label. this is a mutation: feedback starts
  in the same frame as the tap.
- **inline · optimistic row**: "su verdin · kaydediliyor" — the entry
  drops into the list immediately and submits in the background. on
  failure the row turns to the help palette; it never disappears.
- **photo upload**: the only place a percentage is shown ("%62"). no
  other progress bar exists anywhere. the 6 s fallback never cancels the
  upload.

these are shared, app-wide components with their own issue (slice 7) —
they are not owned by any single feature slice.

## reduced motion

normative, not a nicety. when `MediaQuery.disableAnimations` or
`accessibleNavigation` is active: no staggered entrance, no shimmer, no
breathing, no spin. every state jumps straight to its settled frame — the
splash renders 12b's composition with the map already revealed beneath.
nothing is hidden or removed. every slice that animates anything must ship
this behavior and its test.

## contract gap resolutions

1. **400 ms delay** — applies to initial reads only. user-triggered
   mutations get same-frame feedback. adopted above.
2. **6 s fallback** — bounded reads only; never cancels or visually fails
   an in-flight photo upload or write. adopted above.
3. **map placeholders** — only cats with a real cached position may render
   a placeholder pin; the app never invents a location. adopted in 13.
4. **location copy** — "konumun sadece yakınındaki kedileri göstermek için
   kullanılır, kaydedilmez" is **partially verified, not final**. verified
   at the application layer: coordinates travel only as query parameters
   of nearby/map/discover reads (`GET /v1/cats?bbox=`,
   `/v1/cats/discover?lat=&lng=`, `/v1/cats/nearby`); no table stores a
   user location; the backend's `requestLogger` logs `r.URL.Path` only —
   query strings never enter its logs; the repository's caddy config has
   no access log; analytics events carry no coordinates ([[privacy]]).
   **unverified: edge and hosting access logs** (cloudflare and the
   droplet's infrastructure may record full request urls including query
   strings). until that is checked and any url logging is disabled or
   redacted, the sentence stays provisional, state 06 may not ship it,
   and [[privacy]] is deliberately left untouched.
5. **durable draft storage** — no existing repository mechanism qualifies:
   the only persistence dependency is `flutter_secure_storage`, a
   credential store, and the draft store must be non-credential and
   web-compatible. resolution: **removed from this design pass** — issue
   #99 excludes offline/cache/queue from 0.2. the queue's storage
   decision belongs to the future contract revision that reopens it.
6. **queue vs offline-first** — the distinction stands as design intent:
   the referenced queue holds one pending draft, created explicitly by
   the user, delivered on reconnect — not offline-first synchronization.
   but no architecture change is made now: the queue is out of 0.2 per
   issue #99, `docs/architecture/flutter.md` is unchanged, and reopening
   this work requires explicit product-owner and architecture approval.
7. **splash vs issue #24** — the paw/pin lockup is an app-state
   illustration only. #24's brief and exclusions are unaffected; no
   lasting brand change is made. adopted in 12.
8. **connectivity and staleness** — state 10 requires connectivity
   awareness and a timestamped retained-response cache; neither exists
   today, and both likely need a dependency (connectivity) and a defined
   web story (cache storage). both are **deferred with state 10** — out
   of 0.2 per issue #99; the future issue that reopens them must make
   the dependency and web-support implications explicit.
9. **notifications empty-state count** — verified: `GET /v1/me/follows`
   (`ListFollowedCats`) returns each followed cat with `last_update_at`,
   so the count and the freshness window derive from real data. if the
   source is unavailable, the sub-line drops — count-free banner, no
   derived or invented value.
10. **reduced motion** — normative for every animated state; adopted
    above.
11. **splash asset pipeline** — the 12b lockup is the source asset; slice
    4 owns replacing `assets/splash/source/` and regenerating through
    `assets/scripts/generate.py`, plus `app/web/index.html` and
    `splash_gate.dart`. adopted in 12b.

## implementation slices

each slice is a separately testable issue. slice numbering matches the
references in the html feet ("dilim n"). dependencies are stated
explicitly per slice — slices 1–4 and 7 are mutually independent; slice
5 consumes slice 7's shared components, so slice 7 lands first.
reduced-motion behavior and its tests ship inside every slice that
animates.

1. **map states** — 06, 07, 13: fallback-location note, in-radius empty
   state, cached-pin loading with the timing contract. 06 was reshaped in
   0.4.3 from a blocking permission screen into a note over a working
   map — see its entry above.
2. **notifications quiet day** — 09: olive banner and followed list from
   `GET /v1/me/follows`, count-drop rule included.
3. **discover skeleton and empty follow** — 08, 14: skeleton geometry,
   400 ms rule, filter-row persistence.
4. **splash** — 12, 12b: gate composition, asset pipeline regeneration,
   1.6 s status line, reduced-motion settled frame.
5. **failed submission, in-session** — 11 without its durable elements:
   retained form, failure sheet, retry with the existing idempotency-key
   contract. uses slice 7's button and inline affordances.
6. **deferred — out of 0.2 (issue #99)**: connectivity awareness,
   timestamped response cache, and the single-pending-draft queue —
   state 10 plus 11's "taslak olarak sakla" and automatic-retry footer.
   the number is reserved so the html's "dilim 6" references stay
   coherent; this is not a schedulable 0.2 issue and reopening it
   requires a contract revision and architecture approval.
7. **shared mutation affordances** — its own issue with app-wide
   ownership, not buried in any feature slice: the in-place submitting
   button, the optimistic inline row, and the photo-upload percentage,
   as shared components multiple features consume.

## issue relationships

- issue #85's splash composition is deliberately superseded by 12b
  (recorded in `docs/design/implementation-contract.md`).
- issue #24's logo process and exclusions are unaffected; the splash
  lockup is an illustration, revisited when #24 delivers.
- issue #99 excludes offline/cache/queue from the committed 0.2 scope;
  this contract honors that — state 10 and the durable draft elements
  are design reference only, deferred behind a future contract revision.
  `docs/architecture/flutter.md` is unchanged by this adoption.
- issue #98 adopts this contract; slices 1–5 and 7 are its follow-up 0.2
  implementation issues.

## open questions

both resolved by the issue #121 approval (2026-08-06), and both lapsed in
0.4.3 with the blocking screen they belonged to. kept below for history —
either can be reopened as its own issue if still wanted, now against the
fallback note rather than a full-screen state.

- state 06's secondary action "haritada elle mahalle seç" has no current
  or planned implementation owner.
- gap 4's remaining verification: whether cloudflare and the hosting
  droplet's infrastructure record full request urls (query strings
  containing coordinates), and if so, disabling or redacting that.
