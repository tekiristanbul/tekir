import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Concept 1's geometry: a lens the reader moves over the map.
///
/// A cat under the glass is drawn larger. It is not drawn anywhere else.
/// An earlier pass also pushed crowded pins apart so a stack would open
/// into a rosette, and that was wrong twice over: it read as a badge rather
/// than as magnification, and it meant the map was showing cats where they
/// are not. Position is now never touched. The only thing the lens changes
/// is size, and every pin on screen can be trusted.
///
/// What resolves a stack instead is the sweep. The cat nearest the focus is
/// the largest and is drawn over its neighbours, so moving the glass across
/// a doorway reads its cats one after another, the way moving a real
/// magnifier over overlapping photographs does. Cats recorded at
/// *identical* coordinates cannot be separated this way at all — an honest
/// limit of scale-only magnification, not an oversight.
///
/// The profile is a spherical cap:
///
///     scale(x) = 1 + (M − 1)·√(1 − x²),  x = r/R
///
/// chosen for its edge. It reaches full magnification at the focus and
/// falls to exactly 1 at the rim, but it arrives there vertically, so the
/// boundary is a place on the map rather than a gradual fade. That edge is
/// the difference between a piece of glass lying on the map and icons
/// quietly growing.
class LensPlacement {
  const LensPlacement({
    required this.id,
    required this.position,
    required this.scale,
    required this.distanceToFocus,
  });

  final String id;

  /// The cat's true screen position for the current camera. The lens never
  /// moves it.
  final Offset position;

  /// Diameter multiplier: 1 outside the glass.
  final double scale;

  /// Distance from the focus in logical pixels, [double.infinity] when
  /// there is no focus.
  final double distanceToFocus;
}

/// The glass's radius in logical pixels. Around a fingertip and a half:
/// large enough to hold a doorway, small enough that the reader can still
/// see the street it sits on.
const double lensRadius = 110;

/// Magnification at the focus. Deliberately modest — the glass has to make
/// a cat readable, not cover the road it lives on.
const double lensMagnification = 1.8;

/// Pin diameter at rest, in logical pixels. Smaller than the shipped 66 pt
/// marker, because this layer draws every cat in view at once and the lens,
/// not the resting size, is what makes one readable.
const double lensBasePin = 36;

/// Placements for [cats] under a lens centred on [focus].
///
/// [strength] ramps the whole effect between the untouched map (0) and full
/// magnification (1), so picking the glass up and putting it down is one
/// continuous change. With [focus] null, or [strength] 0, every cat comes
/// back at its own size.
///
/// The returned list is ordered back to front: the cat nearest the focus is
/// last, so a caller that draws in order gets the right stacking for free.
List<LensPlacement> lensPlacements({
  required Offset? focus,
  required double strength,
  required List<({String id, Offset point})> cats,
  double radius = lensRadius,
  double magnification = lensMagnification,
}) {
  if (cats.isEmpty) return const [];
  // Sorted by id first so cats at the same distance from the focus —
  // including cats on the same coordinate — keep a stable order between
  // frames instead of trading places on floating-point noise.
  final ordered = [...cats]..sort((a, b) => a.id.compareTo(b.id));

  final placements = <LensPlacement>[];
  for (final cat in ordered) {
    if (focus == null || strength <= 0) {
      placements.add(
        LensPlacement(
          id: cat.id,
          position: cat.point,
          scale: 1,
          distanceToFocus: double.infinity,
        ),
      );
      continue;
    }
    final distance = (cat.point - focus).distance;
    if (distance >= radius) {
      placements.add(
        LensPlacement(
          id: cat.id,
          position: cat.point,
          scale: 1,
          distanceToFocus: distance,
        ),
      );
      continue;
    }
    final x = distance / radius;
    placements.add(
      LensPlacement(
        id: cat.id,
        position: cat.point,
        scale: 1 + (magnification - 1) * math.sqrt(1 - x * x) * strength,
        distanceToFocus: distance,
      ),
    );
  }

  placements.sort((a, b) => b.distanceToFocus.compareTo(a.distanceToFocus));
  return placements;
}
