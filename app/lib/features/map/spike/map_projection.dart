import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Where a coordinate lands on screen, computed in Dart rather than asked
/// of the map.
///
/// The sdk can answer this — `GoogleMapController.getScreenCoordinate` —
/// but only one coordinate per asynchronous platform call. A lens that
/// follows a finger has to know where every visible cat is *this frame*,
/// which makes a round trip per cat per frame, and that is not a thing the
/// plugin can do. Web Mercator is a closed form and the camera hands over
/// everything it needs, so the projection is done here instead: no channel,
/// no latency, no ordering problem.
///
/// Only valid while the camera is flat and north-up. The lens concept turns
/// the tilt and rotate gestures off for exactly that reason; a bearing
/// would need a rotation about the centre here, and a tilt would need the
/// full perspective transform the sdk keeps to itself.
class MapProjection {
  const MapProjection({
    required this.center,
    required this.zoom,
    required this.size,
  });

  /// The camera's target — the coordinate at the middle of [size].
  final LatLng center;

  final double zoom;

  /// The map widget's own size in logical pixels, not the window's.
  final Size size;

  /// Google's tile size. The world is this many pixels across at zoom 0 and
  /// doubles per zoom level.
  static const double tileSize = 256;

  double get worldSize => tileSize * math.pow(2, zoom);

  Offset _world(LatLng point) {
    final world = worldSize;
    final x = (point.longitude + 180) / 360 * world;
    // Clamped short of the poles, where the mercator projection runs to
    // infinity. Istanbul is nowhere near this, but a NaN here would take
    // out the whole overlay rather than one pin.
    final sinLat = math
        .sin(point.latitude * math.pi / 180)
        .clamp(-0.9999, 0.9999);
    final y =
        (0.5 - math.log((1 + sinLat) / (1 - sinLat)) / (4 * math.pi)) * world;
    return Offset(x, y);
  }

  /// [point] in the map widget's own logical pixels.
  Offset toScreen(LatLng point) {
    final origin = _world(center);
    final target = _world(point);
    return Offset(
      target.dx - origin.dx + size.width / 2,
      target.dy - origin.dy + size.height / 2,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MapProjection &&
      other.center.latitude == center.latitude &&
      other.center.longitude == center.longitude &&
      other.zoom == zoom &&
      other.size == size;

  @override
  int get hashCode =>
      Object.hash(center.latitude, center.longitude, zoom, size);
}
