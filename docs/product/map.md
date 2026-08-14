# map

## goal

define the role of the map in helping people find and help Istanbul street cats.

## decisions

- the first screen when the app opens is the map, with cats shown on it.
- the map should start zoomed in close, around walking distance — about 2-3 streets.
- on launch, the map centers on the user's location when it's available and within the supported istanbul area. when location is denied, unavailable, invalid, or outside that area, the map opens on a fixed, hard-coded istanbul fallback viewport instead — zoomed out to a broad area rather than a single street, so it reads as "istanbul" rather than pointing at one place. the fallback is intentionally static for 0.4: no live cat-density calculation picks it (issue #235).
- the map should mainly show cat photos and the map itself. a bottom menu can hold navigation.
- the map should stay simple and avoid unnecessary detail.
- nearby cat markers are clustered. as the user zooms in, clusters separate into individual cats.
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
