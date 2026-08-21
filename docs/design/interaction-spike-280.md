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
flutter run --dart-define=MAP_SPIKE=fan     # concept 1
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

## Concept 1 · proximity fisheye (`fan`, labelled `odak`)

### From first touch to completion

1. The user taps a cluster bubble, or long-presses anywhere on the map. The
   hand is acknowledged immediately with `TekirHaptics.acknowledge` — before
   anything is drawn, because the drawing takes a frame.
2. Over 320 ms the cats in that group move outward from the focus. Each one
   keeps its own bearing: the cat genuinely north-east of the doorway stays
   north-east of it. Only the distance is stretched, most at the focus and
   decaying with the square of distance, so a cat that was already readable
   barely moves at all.
3. A one-pixel leader stays drawn from each moved pin back to its real
   position, with a small anchor on the position itself. This is the part
   that makes the concept honest rather than a map showing cats where they
   are not.
4. Each separated pin is a real Flutter widget, tappable and labelled.
   Tapping one opens the shipped preview sheet, unchanged.
5. The focus ends on a tap anywhere else, on a selection, or on any camera
   movement — the seats were measured against one camera, so a moved camera
   makes them wrong, not merely stale. The collapse runs in 200 ms, one step
   faster than the separation, per the motion system.

Evidence: [03 · focus open](screenshots/spike-280-03-fan-open.png),
[04 · selecting one](screenshots/spike-280-04-fan-selected.png), and the
frame sequence [fan-frame-0](screenshots/spike-280-fan-frame-0.png) →
[1](screenshots/spike-280-fan-frame-1.png) →
[2](screenshots/spike-280-fan-frame-2.png) →
[3](screenshots/spike-280-fan-frame-3.png).

### Why it belongs to tekir

The overlap is not a rendering problem to be smoothed over; it is what the
data means. Cats share doorways. A product whose question is "who is on this
corner, and when was each of them last seen" cannot answer with a count, and
cannot make the user destroy their own framing of the neighbourhood to find
out. The arrangement is the map's own geometry magnified, held only while
the user asks for it, and written back nowhere.

### Flutter + Google Maps feasibility

Works, and deliberately does not touch clustering. `ClusterManager`'s
`onClusterTap` hands over `cluster.markerIds`, so the native clusterer stays
the grouping engine and only the answer to a tap changes.

SDK limits found:

- **The cluster bubble cannot be hidden or restyled.** It is drawn by the
  native sdk in Google's blue, and it sits in the middle of the open
  arrangement as the only non-palette element on screen (visible in
  [03](screenshots/spike-280-03-fan-open.png)). Changing it means replacing
  clustering, which this spike is explicitly not doing.
- **`getScreenCoordinate` is one async platform call per marker.** Seven is
  free. A forty-cat cluster is forty round trips before the layer can open,
  and nothing in the sdk offers a batch projection.
- **Markers have no semantics.** A Google Maps pin is a bitmap inside a
  platform view; TalkBack and VoiceOver cannot see it. The separated pins
  are Flutter widgets, so this concept is the first time these cats are
  reachable by a screen reader at all — which is a finding about the shipped
  map, not only about this concept.
- On web the layer needs `PointerInterceptor`, so the map is not pannable
  while a focus is open. On the phones this is free.
- Projection units differ by platform: device pixels on iOS/Android, css
  pixels on web. Handled; getting it wrong would put every seat a third of
  the way to the corner on a 3× phone.

### Ratings

- **Complexity: medium.** The geometry is 120 lines of pure maths with its
  own tests; the layer is a `Stack` and a `CustomPaint`; the map screen
  gains one branch in the cluster-tap handler.
- **Gimmick risk: low.** The motion is the answer to a question the user
  asked, it ends when they stop asking, and removing it would remove the
  information rather than the decoration.

### Reduced motion

No travel. The seats are taken in the same frame and the leaders are drawn
immediately. The separation is information, not decoration, so it stays —
consistent with [app-states.md](app-states.md)'s rule that reduced motion
removes movement, not meaning.

### What a real device has to answer

- Latency on a cluster of forty-plus cats, where the projection round trips
  dominate.
- Seats are not clamped to the viewport in this prototype. A focus taken
  near the top edge can seat a pin off-screen.
- Tap accuracy of 56 pt pins with a thumb, at the edges of the arrangement.
- Whether a long press on the map conflicts with anything the Android or iOS
  Maps sdk already does with that gesture.
- Screen-reader order across the separated pins, and — the open question —
  how a screen-reader user opens a focus at all, given the cluster bubble
  underneath has no semantics to tap.

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

| | 1 · fisheye | 2 · reach tiers | 3 · carry |
|---|---|---|---|
| usability | solves the real defect: cats on one corner become choosable in place | changes nothing the user does | every marker tap reads as one movement instead of two screens |
| map readability | improved while open; pins are displaced, mitigated by leaders | improved where it renders at all, which is rarely | unchanged |
| tekir identity | strong — the doorway problem is tekir's own | moderate — "reach" is the right idea, wrongly expressed as size | strong — the cat as one continuous record |
| motion clarity | causal, user-initiated, ends on release | none; a re-render | causal; the object moves because it is the same object |
| accessibility | net gain: the only path that makes clustered cats reachable at all. Open gap: no accessible way to *open* a focus | neutral | at risk: replaces a platform sheet with a hand-built one |
| complexity | medium | medium, then large | medium, then long tail |
| gimmick risk | low | medium | low |

## Recommendation

**Concept 1, the proximity fisheye.** It is the only one of the three that
answers a question the product actually fails to answer today, it is purely
additive — no new route, no navigation change, no platform surface replaced
— and its accessibility effect is positive rather than risky. It also leaves
clustering exactly where it is, which keeps the map's scaling behaviour
untouched.

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

1. **Seats are not clamped to the viewport.** A focus opened near an edge
   can place a pin off-screen, so a cat becomes less reachable than it was
   before the focus opened.
2. **No accessible entry point.** The cluster bubble that opens a focus is a
   native bitmap with no semantics, so a screen-reader user cannot reach the
   interaction that exists for them. This needs a product answer, not a
   patch.
3. **Unbounded projection cost.** One async platform call per cat before the
   layer can open; a large cluster needs either a cap or a different
   projection strategy.
4. **The native cluster bubble sits inside the arrangement in Google's
   blue**, and cannot be restyled without replacing clustering. Whether that
   is acceptable is a product call.

Until those are answered, #280 stays open. All three experiments stay behind
the flag, off by default; the two rejected ones are kept disabled rather than
deleted so the evidence and the hero-flight test survive with them.
