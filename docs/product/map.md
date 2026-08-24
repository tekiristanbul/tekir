# map

## goal

define the role of the map in helping people find and help Istanbul street cats.

## decisions

- the first screen when the app opens is the map, with cats shown on it.
- the map should start zoomed in close, around walking distance — about 2-3 streets.
- on launch, the map centers on the user's location when it's available and within the supported istanbul area. when location is denied, unavailable, invalid, or outside that area, the map opens on a fixed, hard-coded istanbul fallback viewport instead — zoomed out to a broad area rather than a single street, so it reads as "istanbul" rather than pointing at one place. the fallback is intentionally static for 0.4: no live cat-density calculation picks it (issue #235).
- the map should mainly show cat photos and the map itself. it is the application, not one destination among several: since 0.5 (issue #284) there is no bottom navigation bar, and the map runs full height under a top strip holding search, notifications and the account. every other screen is pushed over it.
- cat search, notifications and the account are reached from that strip; adding a cat and returning to the user's own position are the two actions anchored to the bottom of the map.
- the map should stay simple and avoid unnecessary detail. since 0.5 (issue #285) the ground is drawn in tekir's own colours — warm paper, sand roads, muted parks, grey-green water — so the cats sit on the map rather than on top of an unrelated one. businesses, transit and poi icons stay hidden; neighbourhood and road names stay legible.
- nearby cat markers are clustered. as the user zooms in, clusters separate into individual cats. cats recorded from the same doorway are closer together than the closest zoom can separate, so tapping their group offers a list to pick from instead of spending the last of the zoom on them (issue #285) — a cat is always reachable, and the list never moves a cat somewhere it is not just to make it tappable. since 0.5 (issue #285) the grouping and the bubble that stands for it are the product's own, drawn in tekir's palette and type — google's native cluster appearance is not configurable and was never tekir's.
- how much of a cat a marker shows follows the zoom, not the cat (issue #285): at street zoom it is the cat's own face, a few steps out a photoless silhouette, and across the city a dot. a cat drawn as a dot never triggers a photo request, and at most twelve faces are on screen at once — beyond that the overflow drops to a silhouette rather than disappearing.
- selecting a cat zooms in far enough for it to be drawn as its own face — never further out than the user already was — brings it to rest above the sheet describing it, marks it with a slow ring and a single pulse, and quiets every other marker. pulse is reserved for exactly two things — a cat needing help, and the selected cat — and nothing else in the product uses it.
- tapping a cat opens a detail page showing identifying information, help needs, media, and updates.
- map-level freshness information is compact and uses these mvp states:
  - `today`: the latest update is less than 24 hours old.
  - `this_week`: the latest update is at least 24 hours and less than 7 days old.
  - `this_month`: the latest update is at least 7 days and less than 30 days old.
  - `long_not_seen`: the latest update is at least 30 days old, or no update exists.
- exact timestamps live in the detail experience rather than crowding the map.
- the 12-month inactivity presentation in [[cats]] is a stronger detail-level message within the broader `long_not_seen` map state.
- the product should make a cat's need for help immediately understandable. in 0.1 (implemented) this is a fixed category vocabulary; in 0.2 (issue #100, [[alerts]]) it is a single needs-help state whose reason comes from the reporter's optional note.

## open questions

- none for mvp. final visual styling is resolved by the shipped implementation and implementation contract, not by changing these semantic thresholds.

## out of scope

- dense social or engagement information on the map.
- colony markers as a separate entity type.
- dynamic, cat-density-based selection of the fallback viewport (issue #235) — the fallback stays fixed and hand-tuned.
