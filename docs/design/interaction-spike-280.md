# interaction spike — issue #280

An experiment, not a design decision. Three map interaction concepts were
built far enough to be used and compared, on one branch, behind one flag.
Nothing here ships, and nothing here changes tekir's visual identity: the
palette, the type, the map-first model, the shipped component language, the
accessibility work and the motion tokens are all used as they are.

Read this with [visual-direction.md](visual-direction.md) and
[app-states.md](app-states.md), which stay authoritative. Where a concept
disagrees with them, the concept is wrong.

## How to run it

Everything the spike adds lives in `app/lib/features/map/spike/`. The map
screen reaches into it from a handful of points, each guarded by
`mapSpikeEnabled` — a `const` that is false unless the build was given the
define, so a normal build drops every branch behind it and tree-shakes the
imports.

```
cd app
flutter run --dart-define=MAP_SPIKE=lens    # concept 1
flutter run --dart-define=MAP_SPIKE=reach   # concept 2
flutter run --dart-define=MAP_SPIKE=carry   # concept 3
```

With the flag on at all, a strip along the bottom of the map switches
between the three and the shipped behaviour without a rebuild. It is not a
second navigation system: every option renders the same screen, at the same
route, with one interaction rule swapped.

Removing the experiment is deleting `app/lib/features/map/spike/`, its
tests, and the `if (mapSpikeEnabled)` blocks in `map_screen.dart`.
`spike_flag_test.dart` asserts that a build without the define cannot arm a
concept even if something writes to the provider.

## The problem all three start from

tekir's cats are recorded where people meet them: one doorway, one wall, one
café's back step. The seeded Galata group is seven cats inside forty metres,
and that is not seed data being lazy — it is what the map looks like.

At neighbourhood zoom those seven are one blue bubble reading `7`
([01](screenshots/spike-280-01-baseline-cluster.png)). Tapping it zooms in
two levels and produces two bubbles reading `3`
([02](screenshots/spike-280-02-baseline-zoomed.png)). Two more taps and the
cats are finally separate — overlapping each other in a diagonal string, at
a zoom where the neighbourhood the user was reading is gone
([11](screenshots/spike-280-11-overlap-at-street-zoom.png)).

So the shipped answer to "which cats are on this corner" is a number, then
a different number, then a pile.

---

## Concept 1 · the focus lens (`lens`, labelled `mercek`)

### From first touch to completion

There is no opening and no closing. The focus is wherever the pointer is,
every frame, and the map is locally magnified around it the way a glass
lens magnifies paper.

1. The glass is picked up from a control on the map, and put down again.
   Reading the pointer continuously means taking every pointer event
   before the map's own html element sees them, and a map whose panning
   has been re-implemented over a platform channel pans like a
   re-implementation — two earlier builds tried to keep both and both
   failed, one by branching on a device kind web does not report reliably,
   one by making the map crawl. With the glass down the layer intercepts
   nothing but its own pins and the map keeps its native pan, fling and
   pinch; with it up, the pointer is the lens.
2. Cats within about 140 px of the focus grow, most at the focus itself and
   progressively less further out, reaching their normal size exactly at the
   lens's edge. A cat outside it is untouched, to the pixel.
3. The same transform moves them: space stretches, so a magnified cat is
   also further from its neighbours. Scale and displacement come from one
   expression, which is what makes it read as glass over a map rather than
   as icons growing.
4. Cats recorded at one doorway need more than stretching — a few pixels
   times three is still a few pixels — so a crowded pin also steps outward
   along a bearing of its own, by as much as its overlap requires and no
   more, fading to nothing at the lens edge.
5. Every displaced pin keeps a hairline drawn back to its real coordinate,
   with an anchor dot on the coordinate itself, drawn over the pins so the
   true geography is legible exactly when the displacement is largest.
6. Moving the focus on releases what it leaves behind, continuously.
   Lifting the finger, or moving the cursor off the map, settles everything
   back onto its own coordinate.
7. Tapping a magnified cat opens the shipped preview sheet, unchanged.

Evidence: [03 · at rest](screenshots/spike-280-03-lens-rest.png) — the
seeded Galata seven at street zoom, one stack;
[04 · the lens over them](screenshots/spike-280-04-lens-open.png) — seven
faces, each identifiable, at the same zoom;
[04b · the lens moved](screenshots/spike-280-04b-lens-moved.png) — the same
group under a focus that has shifted, redistributed continuously. The frame
sequence [lens-frame-0](screenshots/spike-280-lens-frame-0.png) →
[1](screenshots/spike-280-lens-frame-1.png) →
[2](screenshots/spike-280-lens-frame-2.png) →
[3](screenshots/spike-280-lens-frame-3.png) →
[4](screenshots/spike-280-lens-frame-4.png) →
[5 · released](screenshots/spike-280-lens-frame-5.png) is a single drag
across the group, pumped frame by frame.

### Why it belongs to tekir

The overlap is not a rendering problem to be smoothed over; it is what the
data means. Cats share doorways, because that is where people meet them. A
product whose question is "who is on this corner, and when was each of them
last seen" cannot answer with a count, and cannot make the reader destroy
their own framing of the neighbourhood to find out. The lens answers it
where the reader is looking, costs one movement, and leaves nothing behind.

### Flutter + Google Maps feasibility

A `google_maps_flutter` marker cannot carry this. It is a bitmap the
platform draws, addressed by coordinate: changing its size means encoding a
new png and pushing a new marker set over the platform channel, and changing
its position means moving the cat. Neither can happen per frame. So while
this concept is active the cats are drawn by Flutter over the map, and the
basemap stays exactly the map it was.

Two consequences and two limits found:

- **Projection is done in Dart.** `getScreenCoordinate` is one asynchronous
  platform call per coordinate, which a lens following a finger cannot use.
  Web Mercator is closed-form and the camera hands over everything it
  needs, so `spike/map_projection.dart` computes it directly — verified
  against Google's own metres-per-pixel in
  `map_projection_test.dart`. It is only valid for a flat, north-up
  camera, so this concept turns the rotate and tilt gestures off.
- **Reading the pointer and keeping the map's gestures are mutually
  exclusive**, and the map's gestures are worth more. Intercepting every
  pointer event is the only way to see hover over a platform view on web,
  and forwarding the resulting drags back to the camera produced a map that
  panned visibly worse than the map does. So the lens is armed and
  disarmed from a control instead: down, the layer takes nothing; up, it
  takes everything and hands only the wheel back. That is a mode, which is
  the honest cost of this concept on this sdk.
- **Clustering is bypassed, not used.** With the cats drawn in Flutter, the
  clusterer has nothing to group — which is also why this interaction puts
  no count anywhere on screen. It is left registered and untouched, and
  returns the moment the concept is off. But a viewport holding hundreds of
  cats would draw hundreds of Flutter pins with nothing thinning them.
- **Each pin holds a decoded photo** at one size, deliberately, so the lens
  does not cost a decode per pin per frame. That trades memory for frame
  time, and the trade has only been measured on web.

### Ratings

- **Complexity: medium.** The geometry is one file of pure maths with its
  own tests, the projection another, and the layer is a `Stack` and two
  `CustomPaint`s. What is *not* medium is what replacing the marker layer
  drags in: gesture forwarding, clustering, and photo memory.
- **Gimmick risk: low.** The magnification is the reading mechanism; remove
  it and the information goes with it. It never runs on its own, and it
  stops the instant the reader stops asking.

### Reduced motion

The lens stays; only the ramp goes. Engaging and releasing the focus become
immediate scale and displacement changes in the same frame, rather than a
200 ms arrival and a 120 ms return. The movement that follows the pointer
was never an animation — it tracks the finger with no smoothing at all,
because a lens that lags the finger stops being a lens. Covered by tests in
`focus_lens_layer_test.dart`.

### What a real device has to answer

- Frame time with a screenful of cats: the layer re-projects and re-lays out
  every pin on every pointer frame.
- Touch panning, which this prototype gives up while the lens is the active
  concept.
- Whether a 40 pt resting pin is legible outdoors, and whether the magnified
  rosette covers too much of the street it is describing.
- Screen-reader behaviour: the pins are real widgets with labels, which the
  shipped map's markers are not, but a lens driven by a pointer has no
  meaning to a screen-reader user and needs its own answer.
- Memory with a few hundred decoded photos held at pin size.

---

## Concept 2 · reach tiers (`reach`, labelled `erişim`)

### From first touch to completion

There is no touch. Pins resolve to one of three tiers as the camera settles:
identity (the shipped 66 pt photo), presence (a 40 pt photo with a thinner
ring), and trace (a 14 pt dot). Zoom decides first; the user's own distance
decides at street zoom, where a cat more than about ten minutes' walk away
holds at presence. A cat with an active help mark never falls to a dot and
is forced back to identity above district zoom.

Evidence: the same city-wide viewport with the concept
[off](screenshots/spike-280-05-reach-off-city.png) and
[on](screenshots/spike-280-06-reach-on-city.png) — the Kadıköy cat's 66 pt
photo becomes a dot.

### Why it belongs to tekir

The app is about going outside. What is within reach is the app's real
subject, and a map that renders a cat you could check on in five minutes
exactly like one across the Bosphorus is throwing that away.

### Flutter + Google Maps feasibility

The rendering works and is cheap — bitmaps are cached per cat, tier and
selection, and the rebuild runs on camera idle only, never per frame.

The concept is blocked by two things it cannot reach past:

- **Native clustering swallows exactly the cats the tiers exist for.** Below
  street zoom the Galata group is one bubble, so the reduced tiers only ever
  render for the few cats that happen not to be grouped
  ([07](screenshots/spike-280-07-reach-clustered-limit.png)). Making the
  concept visible means changing or dropping clustering — the one thing the
  issue rules out.
- **Its distinguishing rule is inert without a location.** No permission, a
  disabled service, or a timeout all resolve to the fixed Istanbul centre,
  which is a hard-coded point and not a position; distance is then unknown
  and zoom decides alone. That fallback is a supported, common state — every
  screenshot in this document was taken in it.

### Ratings

- **Complexity: medium.** Small on its own; large once it has to be made
  visible, because that means owning clustering.
- **Gimmick risk: medium.** With the motion invisible — a tier change is a
  re-render, not a movement — what is left is a size ramp, and size on a map
  reads as importance before it reads as distance. The help override makes
  that worse, not better: a big pin now means *either* "near you" or
  "urgent".

### Reduced motion

Nothing to reduce, which is itself the finding: this is a rendering rule,
not an interaction.

### What a real device has to answer

- Bitmap churn while crossing a tier boundary during a pinch.
- Memory at city zoom with a few hundred cats in view.
- Whether the tiers are legible at all under Istanbul daylight on a phone,
  at 14 pt.

---

## Concept 3 · cat carry (`carry`, labelled `süreklilik`)

### The defect it starts from

The app already tags the preview sheet's photo and the cat detail's avatar
with the same hero tag, and `map_screen.dart` keeps the sheet on the stack
for 500 ms after pushing the detail so "the shared photo's flight has a
source to leave from".

That flight has never happened. Flutter's `HeroController` starts a flight
only when both routes are `PageRoute`s, and `showModalBottomSheet` pushes a
`ModalBottomSheetRoute`, which extends `PopupRoute`. The sheet retreats and
an unrelated screen arrives, exactly as it did before the tags were added.
This is proved, not asserted, in
`app/test/features/map/spike/cat_carry_test.dart`.

### From first touch to completion

1. The user taps a pin. Haptic acknowledgment, as today.
2. That cat's native marker is replaced in place by the same pin drawn in
   Flutter, and the preview is pushed as a non-opaque `PageRoute`.
3. The pin lifts off the map and travels on an arc into the preview's photo
   slot, rounding from circle to the sheet's rounded square on the way,
   while the surface rises underneath it — 320 ms, `TekirMotion.enter`.
4. `Detaya git` pushes the detail, and the same photo continues into the
   detail's 132 pt avatar, where the detail's own existing shuttle rounds it
   back to a circle. Two legs, one object.
5. Back reverses each leg. When the preview is dismissed the photo flies
   back down to the map and the real marker returns — after the flight
   lands, so there is never a frame with the cat missing.

The camera nudge that currently slides a tapped pin clear of the sheet is
not needed here, and is skipped: the pin *is* the sheet's photo.

Evidence: [08 · the pin](screenshots/spike-280-08-carry-pin.png),
[09 · landed in the preview](screenshots/spike-280-09-carry-preview.png),
[10 · the detail](screenshots/spike-280-10-carry-detail.png), and the frame
sequence [carry-frame-0](screenshots/spike-280-carry-frame-0.png) →
[1](screenshots/spike-280-carry-frame-1.png) →
[2](screenshots/spike-280-carry-frame-2.png) →
[3](screenshots/spike-280-carry-frame-3.png) →
[4](screenshots/spike-280-carry-frame-4.png).

### Why it belongs to tekir

The product's claim is that a cat is one continuous record that many people
add to. The pin, the preview and the detail are three renderings of the same
cat, and making them look like three screens is the app disagreeing with
itself.

### Flutter + Google Maps feasibility

Works, using the app's existing hero tags, shuttle and motion tokens. The
preview widget itself is reused unmodified — the concept changes how the
surface arrives, never what it says.

The cost is structural and is the concept's real open question: a
`PageRoute` is not a bottom sheet. `ModalBottomSheetRoute`'s drag-to-dismiss
is gone and is reimplemented here in about thirty lines, which is enough to
evaluate and nowhere near platform parity. iOS's sheet presentation, its
dismissal affordances and its accessibility behaviour would all have to be
re-established by hand — and "do not break ios/android platform behaviour"
is the constraint most at risk from this concept, not least.

### Ratings

- **Complexity: medium** to build, with a long productionisation tail:
  drag-dismiss parity, barrier semantics, screen-reader dismissal.
- **Gimmick risk: low.** It is the one motion the app already tried to
  perform.

### Reduced motion

`HeroMode` is disabled and the route's duration collapses to zero, so the
preview simply appears with its photo already in place — the shipped
behaviour. Travel is removed; the destination is not. Covered by a test.

### What a real device has to answer

- iOS edge-swipe back and Android predictive back against a custom
  `PageRoute` presented as a sheet.
- Whether the ghost pin lands exactly on the native marker's position on a
  3× device.
- VoiceOver focus order and the dismiss action when the preview is a page
  rather than a sheet.

---

## Comparison

| | 1 · focus lens | 2 · reach tiers | 3 · carry |
|---|---|---|---|
| usability | solves the real defect: seven cats on one corner become identifiable and tappable without zooming | changes nothing the user does | every marker tap reads as one movement instead of two screens |
| map readability | the magnified rosette covers the street it describes; outside the lens the map is untouched to the pixel | improved where it renders at all, which is rarely | unchanged |
| tekir identity | strong — the doorway problem is tekir's own | moderate — "reach" is the right idea, wrongly expressed as size | strong — the cat as one continuous record |
| motion clarity | causal and continuous: nothing moves that the pointer is not moving | none; a re-render | causal; the object moves because it is the same object |
| accessibility | pins become real labelled widgets, which markers are not — but a pointer-driven lens has no screen-reader equivalent | neutral | at risk: replaces a platform sheet with a hand-built one |
| complexity | medium, plus everything replacing the marker layer drags in | medium, then large | medium, then long tail |
| gimmick risk | low | medium | low |

## Recommendation

**Concept 1, the focus lens.** It is the only one of the three that answers
a question the product actually fails to answer today: seven cats recorded
at one doorway become seven identifiable cats, in place, without spending
the neighbourhood on two zoom steps. It introduces no route, no navigation
change and no count, and the motion is entirely under the reader's hand.

It is also the most invasive of the three, and that has to be said plainly:
it replaces the marker layer while it is on. That is not a detail to be
tidied later — it is what makes the continuous transform possible at all,
and it is where the remaining work is.

**Concept 2 is rejected.** Its distinguishing rule cannot render while
native clustering owns the zoom levels it targets, and cannot be computed at
all in the app's documented no-location state. What survives is a size ramp
that reads as importance. Making it work means owning clustering, which is a
much larger decision than this concept earns.

**Concept 3 is rejected as a concept, and its finding is kept.** The
continuity it demonstrates is real and the app is already written for it,
but reaching it by replacing a platform bottom sheet with a hand-built page
route trades a platform behaviour for an animation. The valuable part is the
defect: the shipped hero flight does not run. That belongs in its own issue,
fixed on its own terms, not as a motion concept.

## Not ready for 0.5

Concept 1 is recommended but is not yet safe to integrate. The remaining
blockers, in order:

1. **The lens is a mode, not an always-on behaviour.** It has to be, on
   this sdk: a layer cannot read the pointer continuously and leave the
   map's own gestures alone at the same time. Whether a map-reading tool
   the reader has to pick up is acceptable is a product decision, and it
   is the first one to make about this concept.
2. **Nothing thins a dense viewport.** Bypassing the clusterer is what
   removes the count from the interaction, and also what removes the only
   thing keeping a few hundred cats from becoming a few hundred Flutter
   pins, each holding a decoded photo.
3. **No screen-reader equivalent.** The pins gain real labels, which the
   shipped markers never had, but the interaction that reveals them is a
   pointer position. A reader who cannot point needs a different way to the
   same information, and that is a product decision.
4. **Rotate and tilt are disabled** while the concept is on, because the
   Dart-side projection is only valid for a flat, north-up camera. Whether
   that is acceptable, or whether the projection has to grow a bearing
   term, is a product call.

Until those are answered, #280 stays open. All three experiments stay behind
the flag, off by default; the two rejected ones are kept disabled rather than
deleted so the evidence and the hero-flight test survive with them.
