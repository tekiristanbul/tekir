import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'cat_marker.dart';

/// The selected pin always draws above every other one, so tapping a cat
/// brings it to the front instead of leaving it behind a neighbour. Above
/// the largest value [latitudeZIndex] can produce (the south pole, 1.8e6),
/// not merely above the values Istanbul happens to yield.
const int selectedMarkerZIndex = 2000000;

/// How far apart coincident pins are fanned, in degrees of latitude —
/// roughly six metres, small enough that a pin still reads as "here" and
/// large enough that each one is its own tap target at street zoom.
const double fanOutRadiusDegrees = 0.00005;

/// Cats within this distance of each other are treated as one spot. About a
/// metre: two cats recorded from the same doorway, not two cats on the same
/// street.
const double coincidenceEpsilonDegrees = 0.00001;

/// A stable draw order for pins that overlap: southern pins over northern
/// ones, the convention a map reader already expects. Latitude is mapped
/// onto the int range Google Maps orders by; ties (the same latitude) fall
/// back to whatever order the sdk chooses, which the fan-out above has
/// already made visually irrelevant.
int latitudeZIndex(double lat) => ((90 - lat) * 10000).round();

/// Spreads cats that share a coordinate onto a small circle around it, so
/// each one can be tapped. Returns positions only for the cats that actually
/// collide; everything else keeps its own coordinate and is absent from the
/// map. Display only — nothing is persisted, and the angle each cat gets is
/// derived from its id so the arrangement is identical on every rebuild.
Map<String, LatLng> fanOutCoincident(List<CatMarker> cats) {
  final groups = <String, List<CatMarker>>{};
  for (final cat in cats) {
    // Rounding to the epsilon is what makes "the same spot" a bucket rather
    // than an exact-equality test, so two cats a few centimetres apart still
    // count as one spot.
    final key =
        '${(cat.lat / coincidenceEpsilonDegrees).round()}:'
        '${(cat.lng / coincidenceEpsilonDegrees).round()}';
    groups.putIfAbsent(key, () => <CatMarker>[]).add(cat);
  }

  final fanned = <String, LatLng>{};
  for (final group in groups.values) {
    if (group.length < 2) continue;
    // Sorted by id so the arrangement does not depend on the order the api
    // happened to return the cats in.
    final ordered = [...group]..sort((a, b) => a.id.compareTo(b.id));
    for (var i = 0; i < ordered.length; i++) {
      final angle = 2 * math.pi * i / ordered.length;
      final cat = ordered[i];
      fanned[cat.id] = LatLng(
        cat.lat + fanOutRadiusDegrees * math.sin(angle),
        // Longitude degrees shrink with latitude; at Istanbul's latitude a
        // degree of longitude is about three quarters of a degree of
        // latitude, so without this correction the circle would read as an
        // ellipse.
        cat.lng +
            fanOutRadiusDegrees *
                math.cos(angle) /
                math.cos(cat.lat * math.pi / 180),
      );
    }
  }
  return fanned;
}
