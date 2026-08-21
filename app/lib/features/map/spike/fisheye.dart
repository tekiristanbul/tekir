import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Concept 1's geometry: where the cats around a focus point sit while the
/// focus is held.
///
/// The problem this solves is the one the map actually has. Cats are
/// recorded where people meet them — one doorway, one wall, one café's
/// back step — so at street zoom a Galata group of seven collapses into
/// one pin's worth of screen space. Native clustering answers that with a
/// bubble reading `7`, and a tap that zooms in; two taps later the group
/// splits, the neighbourhood the user was reading is gone, and the answer
/// to "which cats are on this corner" was a number the whole time.
///
/// This answers it in place. Every cat keeps its own bearing from the
/// focus — the cat that is genuinely north-east of the doorway stays
/// north-east of it — and only the distance is stretched, most for the
/// ones sitting on top of the focus and least for the ones already far
/// enough to read. That is a fisheye, not a fan: the arrangement is the
/// map's own geometry magnified, so it can be trusted while it is open and
/// costs nothing to undo when the focus ends.
///
/// Pure geometry in logical pixels, deliberately: no map controller, no
/// widget, no animation. The whole rule is testable without a map.
class FisheyeSeat {
  const FisheyeSeat({
    required this.id,
    required this.origin,
    required this.seat,
  });

  final String id;

  /// Where the cat really is on screen. The seat is only ever a temporary
  /// reading position, so the origin stays available — the layer draws a
  /// leader back to it rather than letting a displaced pin pass for a
  /// location.
  final Offset origin;

  /// Where the cat is drawn while the focus is open.
  final Offset seat;

  /// How far this cat was moved to become readable. Zero for a cat that
  /// was already clear of its neighbours.
  double get displacement => (seat - origin).distance;
}

/// Distance between adjacent pin centres, in logical pixels. The spike's
/// fisheye pin is 56 pt across, so this leaves a 6 pt gap — enough that
/// two pins read as two, and tight enough that a group of seven stays
/// inside a thumb's reach.
const double fisheyeMinSpacing = 62;

/// Cats further than this from the focus are left almost exactly where
/// they are: the magnification falls off with the square of distance, so
/// at this radius it has already decayed to a fifth of its peak.
const double fisheyeFalloffRadius = 90;

/// Peak magnification, applied at the focus itself.
const double fisheyeMagnification = 3.4;

/// The furthest a cat is pushed by magnification alone. A cat that has to
/// go beyond this to be separated still does — legibility wins over
/// tidiness — but nothing is thrown to the screen edge merely because the
/// magnification says so.
const double fisheyeMaxRadius = 156;

/// Seats for [cats] around [focus].
///
/// Deterministic: the result depends on the cats' ids and positions, never
/// on the order they arrive in or on when it was called, so the same group
/// tapped twice separates the same way. Cats sitting exactly on the focus
/// (the coincident case `fanOutCoincident` already handles for the shipped
/// map) get a seed bearing from their sorted position, which is the only
/// case where the arrangement is invented rather than measured.
List<FisheyeSeat> fisheyeSeats({
  required Offset focus,
  required List<({String id, Offset point})> cats,
  double minSpacing = fisheyeMinSpacing,
  double falloffRadius = fisheyeFalloffRadius,
  double magnification = fisheyeMagnification,
  double maxRadius = fisheyeMaxRadius,
  int passes = 240,
}) {
  if (cats.isEmpty) return const [];
  if (cats.length == 1) {
    final only = cats.single;
    return [FisheyeSeat(id: only.id, origin: only.point, seat: only.point)];
  }

  final ordered = [...cats]..sort((a, b) => a.id.compareTo(b.id));
  final count = ordered.length;

  // The radius at which `count` pins spaced evenly are exactly [minSpacing]
  // apart. Used as the floor for every pin's radius, which is what
  // guarantees the angular spreading below can always succeed: at or above
  // this radius the required gaps sum to at most a full turn.
  final ringRadius = minSpacing / (2 * math.sin(math.pi / count));

  final angles = <double>[];
  final radii = <double>[];
  for (var i = 0; i < count; i++) {
    final vector = ordered[i].point - focus;
    final distance = vector.distance;
    // Below half a pixel the bearing is noise, not a measurement; seeding
    // from the sorted index keeps coincident cats stable across rebuilds
    // for the same reason marker_layout.dart's fan-out does.
    final angle = distance < 0.5
        ? 2 * math.pi * i / count
        : math.atan2(vector.dy, vector.dx);
    final magnified =
        distance *
        (1 + (magnification - 1) / (1 + math.pow(distance / falloffRadius, 2)));
    angles.add(angle);
    // Magnification only ever pushes outward. Clamping to [maxRadius]
    // without this would drag a cat that is genuinely far from the focus
    // *towards* it, which is the one thing a map may not do — the ceiling
    // caps how far magnification throws a pin, not where a pin may be.
    final capped = math.min(magnified, math.max(maxRadius, distance));
    radii.add(math.max(capped, ringRadius));
  }

  /// The smallest angle between two seats that leaves them [minSpacing]
  /// apart, given the radius each one sits at. Two cats far apart radially
  /// need no angular separation at all — the law of cosines says so, and
  /// using the closer one's radius for both (the obvious shortcut) would
  /// swing a distant cat halfway across the map to make room for a
  /// neighbour it was never near.
  double requiredGap(int i, int j) {
    final a = radii[i];
    final b = radii[j];
    final cosine = (a * a + b * b - minSpacing * minSpacing) / (2 * a * b);
    if (cosine >= 1) return 0;
    if (cosine <= -1) return math.pi;
    return math.acos(cosine);
  }

  final order = List<int>.generate(count, (i) => i)
    ..sort((a, b) => angles[a].compareTo(angles[b]));

  // Spread the bearings apart until neighbours clear [minSpacing], moving
  // each pin as little as possible and never past its neighbour: the
  // cyclic order around the focus is the geography, and reordering it
  // would make the arrangement a lie rather than a magnification.
  for (var pass = 0; pass < passes; pass++) {
    var settled = true;
    for (var k = 0; k < count; k++) {
      final i = order[k];
      final j = order[(k + 1) % count];
      // Exactly one pair crosses the seam — the last back to the first.
      // Wrapping any other negative gap would read an overlap as most of
      // a full turn and leave two cats sitting on each other.
      final gap = k == count - 1
          ? angles[j] + 2 * math.pi - angles[i]
          : angles[j] - angles[i];
      final needed = requiredGap(i, j);
      if (gap + 1e-9 >= needed) continue;
      final push = (needed - gap) / 2;
      angles[i] -= push;
      angles[j] += push;
      settled = false;
    }
    if (settled) break;
  }

  final seats = <FisheyeSeat>[];
  for (var i = 0; i < count; i++) {
    seats.add(
      FisheyeSeat(
        id: ordered[i].id,
        origin: ordered[i].point,
        seat:
            focus + Offset(math.cos(angles[i]), math.sin(angles[i])) * radii[i],
      ),
    );
  }
  return seats;
}
