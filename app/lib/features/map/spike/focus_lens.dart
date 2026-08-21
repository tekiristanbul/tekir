import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Concept 1's geometry: a fisheye lens that follows the pointer across the
/// map.
///
/// Not a menu, not a expansion, not a thing that opens and closes on a tap.
/// The focus is wherever the finger or cursor is, every frame, and the map
/// under it is locally magnified the way a glass lens magnifies paper: the
/// space itself stretches, so a cat near the focus is both larger *and*
/// further from its neighbours, and a cat outside the lens is untouched —
/// same size, same place, to the pixel.
///
/// The radial transform is Sarkar and Brown's graphical fisheye:
///
///     r' = R · x(d+1)/(dx+1),  x = r/R
///
/// Two properties make it the right one here. It fixes the boundary — at
/// r = R the transform is the identity, so the lens has a real edge and the
/// rest of the map is never disturbed. And its magnification, r'/r =
/// (d+1)/(dx+1), decays smoothly from d+1 at the focus to 1 at that edge,
/// which gives the pin's *scale* for free from the same expression that
/// gives its position. Scale and displacement being one transform is what
/// makes it read as a lens over the map rather than as icons growing.
///
/// A pure fisheye is not enough on its own for tekir's actual data. Seven
/// cats recorded at one doorway sit within a few pixels of each other, and
/// stretching a few pixels by three still leaves them stacked. So a second
/// pass pushes overlapping pins apart, by the distance their own current
/// sizes require and no more, faded out by the same falloff so it is gone
/// at the lens edge. That is the "small radial displacement" that makes
/// identities readable; the leader lines the layer draws are what keep the
/// real position recoverable while it happens.
///
/// Pure geometry in logical pixels: no map, no widget, no controller.
class LensPlacement {
  const LensPlacement({
    required this.id,
    required this.origin,
    required this.position,
    required this.scale,
  });

  final String id;

  /// The cat's true screen position for the current camera.
  final Offset origin;

  /// Where it is drawn this frame.
  final Offset position;

  /// Diameter multiplier, 1 outside the lens.
  final double scale;

  double get displacement => (position - origin).distance;
}

/// The lens's reach in logical pixels. About a fingertip and a half —
/// large enough to hold a doorway's worth of cats, small enough that the
/// surrounding streets stay where the reader left them.
const double lensRadius = 150;

/// Sarkar-Brown's `d`. Magnification at the focus is `d + 1`.
const double lensDistortion = 2.6;

/// How large a pin may actually get, whatever the magnification says. The
/// position keeps the full expansion — that is what separates a crowd —
/// while the drawn pin stops growing, so the focus never turns into one
/// face covering the street it is on.
const double lensMaxScale = 1.9;

/// How much two pins under the lens may overlap and still read as two.
/// Below one, deliberately: demanding full clearance for seven magnified
/// pins would need a ring wider than the lens itself, and a little overlap
/// costs nothing once each face is separately visible and separately
/// tappable.
const double lensPinClearance = 0.8;

/// How far a pin steps out per overlapping neighbour, as a fraction of the
/// pin's own resting diameter.
const double spreadStep = 0.9;

/// How much of each polish pass's correction is applied.
const double lensDecrowdDamping = 0.3;

/// The furthest a pin may be pushed off its magnified position to escape a
/// crowd, as a multiple of its resting diameter. A ceiling on the spread
/// alone — never on the magnification, which is the map's own geometry and
/// must not be clipped.
const double lensMaxSpread = 2.4;

/// Pin diameter at rest, in logical pixels.
const double lensBasePin = 40;

/// Placements for [cats] under a lens centred on [focus].
///
/// [strength] ramps the whole effect between the untouched map (0) and the
/// full lens (1), so engaging and releasing the focus is one continuous
/// change rather than a jump. With [focus] null, or [strength] 0, every cat
/// is returned exactly where it is at scale 1.
///
/// Deterministic and order-independent: the cats are sorted by id before
/// the de-crowding pass, so the same frame always resolves the same way.
List<LensPlacement> lensPlacements({
  required Offset? focus,
  required double strength,
  required List<({String id, Offset point})> cats,
  double radius = lensRadius,
  double distortion = lensDistortion,
  double maxScale = lensMaxScale,
  double basePin = lensBasePin,
  double clearance = lensPinClearance,
  double damping = lensDecrowdDamping,
  int decrowdPasses = 6,
}) {
  if (cats.isEmpty) return const [];
  final ordered = [...cats]..sort((a, b) => a.id.compareTo(b.id));

  if (focus == null || strength <= 0) {
    return [
      for (final cat in ordered)
        LensPlacement(
          id: cat.id,
          origin: cat.point,
          position: cat.point,
          scale: 1,
        ),
    ];
  }

  final magnified = <Offset>[];
  final positions = <Offset>[];
  final scales = <double>[];
  final weights = <double>[];

  for (final cat in ordered) {
    final vector = cat.point - focus;
    final distance = vector.distance;
    if (distance >= radius) {
      // Outside the glass. Untouched, exactly — this is the property that
      // keeps the rest of the map trustworthy while the lens is open.
      magnified.add(cat.point);
      positions.add(cat.point);
      scales.add(1);
      weights.add(0);
      continue;
    }
    final x = distance / radius;
    final magnification = (distortion + 1) / (distortion * x + 1);
    // Ramped by strength so engaging the lens is continuous rather than a
    // step, and so releasing it walks every pin home along the same path.
    final applied = 1 + (magnification - 1) * strength;
    magnified.add(
      distance < 0.01
          // Dead centre: the direction is undefined, and the de-crowding
          // pass below is what will give a stack of coincident cats their
          // bearings.
          ? focus
          : focus + (vector / distance) * (distance * applied),
    );
    positions.add(magnified.last);
    scales.add(math.min(applied, 1 + (maxScale - 1) * strength));
    // 1 at the focus, 0 at the edge — the same shape as the magnification,
    // normalised, so the de-crowding fades out exactly where the lens does.
    weights.add((magnification - 1) / distortion * strength);
  }

  // Spreading the crowd.
  //
  // tekir's crowds are not scattered blobs: cats get recorded walking down
  // one street, so a group is usually a line. Pairwise repulsion along the
  // line between two pins cannot leave that line, so a stack of seven would
  // relax into a chain four hundred pixels long instead of a readable
  // rosette. And a purely iterative solver, however many passes it runs,
  // amplifies a one-pixel move of the focus into a visible jump — which
  // reads as jitter, and is the difference between glass and a slot
  // machine.
  //
  // So the spread is computed rather than solved. Each pin measures how
  // crowded it is — a continuous sum of how far inside each neighbour it
  // sits — and steps that far along a bearing derived from its own id.
  // Its own, so the arrangement does not change when a neighbour enters or
  // leaves the lens; continuous in every input, so the whole layout is a
  // smooth function of where the finger is.
  final crowding = List<double>.filled(ordered.length, 0);
  for (var i = 0; i < ordered.length; i++) {
    if (weights[i] <= 0) continue;
    for (var j = 0; j < ordered.length; j++) {
      if (i == j || weights[j] <= 0) continue;
      final needed =
          (basePin * scales[i] + basePin * scales[j]) / 2 * clearance;
      final gap = (positions[i] - positions[j]).distance;
      if (gap >= needed) continue;
      crowding[i] += 1 - gap / needed;
    }
  }

  for (var i = 0; i < ordered.length; i++) {
    if (weights[i] <= 0) continue;
    // Bearings are dealt out evenly over the whole set the layer is
    // drawing, in id order, so a crowd resolves into a rosette instead of
    // a clump — and so a pin's bearing does not change while the focus
    // moves, which a bearing derived from the crowd's own membership
    // would. The set only changes when the viewport refetches, and that
    // rebuilds everything anyway.
    final bearing = 2 * math.pi * i / ordered.length;
    // Softly capped: past about three overlapping neighbours the pin is
    // as far out as it needs to be, and a hard ceiling there would put a
    // corner in the layout that a moving focus would find. tanh bends
    // rather than clips.
    final spread =
        3 * _tanh(crowding[i] / 3) * basePin * spreadStep * weights[i];
    positions[i] += Offset(math.cos(bearing), math.sin(bearing)) * spread;
  }

  // A short, heavily damped polish. Enough to open the pairs the computed
  // spread happened to leave touching; too little to reintroduce the
  // sensitivity it was written to avoid.
  for (var pass = 0; pass < decrowdPasses; pass++) {
    for (var i = 0; i < ordered.length; i++) {
      for (var j = i + 1; j < ordered.length; j++) {
        final weight = math.max(weights[i], weights[j]);
        if (weight <= 0) continue;
        final needed =
            (basePin * scales[i] + basePin * scales[j]) /
            2 *
            clearance *
            weight;
        final delta = positions[j] - positions[i];
        final gap = delta.distance;
        if (gap >= needed || gap < 0.001) continue;
        // Both move, half each: neither cat is privileged, and the pair's
        // midpoint — which is roughly where they really are — stays put.
        final push = (delta / gap) * ((needed - gap) / 2 * damping);
        positions[i] -= push;
        positions[j] += push;
      }
    }
  }

  return [
    for (var i = 0; i < ordered.length; i++)
      LensPlacement(
        id: ordered[i].id,
        origin: ordered[i].point,
        // The spread is bounded, the magnification is not: a pin may be
        // stepped a fixed distance off where the lens put it to escape its
        // neighbours, and no further. Bounding the position instead — a
        // ceiling measured from the focus — would clip the magnification
        // too, and would do it discontinuously right where the lens edge
        // crosses a cat.
        position:
            magnified[i] +
            _capped(positions[i] - magnified[i], basePin * lensMaxSpread),
        scale: scales[i],
      ),
  ];
}

/// Hyperbolic tangent, which `dart:math` does not ship.
double _tanh(double x) {
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}

Offset _capped(Offset delta, double limit) {
  final length = delta.distance;
  if (length <= limit) return delta;
  return delta / length * limit;
}
