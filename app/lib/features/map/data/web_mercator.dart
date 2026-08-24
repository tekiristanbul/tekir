/// Web Mercator, the projection google maps itself draws in.
///
/// Two things in this feature need to know where a coordinate lands in
/// pixels: clustering, which buckets cats by the screen cell they fall in,
/// and the selected cat's halo, which is a flutter widget drawn over the
/// map at that cat's own position. Both could ask the sdk
/// (`getScreenCoordinate`), but that is an asynchronous platform call, and
/// the halo needs an answer on every frame of a camera movement. The same
/// arithmetic in dart costs nothing and gives both callers one definition
/// to agree on.
///
/// Valid for a flat, north-up camera only — a bearing or a tilt would need
/// the sdk's own perspective transform, which it does not expose. The map
/// disables both gestures for exactly this reason (map_screen.dart).
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart' show Offset, Size;
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Side of the world square, in pixels, at zoom 0. Google's own tile size.
const double worldTileSize = 256;

/// Mercator y is unbounded at the poles; google maps clamps the world to
/// this latitude so the projection stays a square.
const double _maxMercatorLatitude = 85.05112878;

/// [lat]/[lng] as a point on the world square at [zoom], in pixels.
Offset worldPixel(double lat, double lng, double zoom) {
  final scale = worldTileSize * math.pow(2, zoom);
  final clampedLat = lat.clamp(-_maxMercatorLatitude, _maxMercatorLatitude);
  final sinY = math.sin(clampedLat * math.pi / 180);
  final x = (lng + 180) / 360;
  // The standard mercator y, folded into 0..1 with the same constant google
  // uses, so a point projected here lands where the sdk drew it.
  final y = 0.5 - math.log((1 + sinY) / (1 - sinY)) / (4 * math.pi);
  return Offset(x * scale, y * scale);
}

/// Where a coordinate sits inside a viewport, in the map widget's own
/// logical pixels, with (0, 0) at the widget's top-left.
///
/// The camera's target is always the widget's own centre. The sdk's
/// `padding` would move it, but that setting is a no-op on the web target,
/// so this map never uses it — it shifts the camera itself instead, which
/// behaves the same everywhere (see [cameraTargetPlacing]).
///
/// Returns a point outside [size] for a coordinate off screen — callers
/// that care (the halo) check for themselves rather than being handed a
/// clamped answer that would silently pin a marker to an edge it is not at.
Offset screenOffsetOf(
  LatLng position, {
  required LatLng cameraTarget,
  required double zoom,
  required Size size,
}) {
  final point = worldPixel(position.latitude, position.longitude, zoom);
  final centre = worldPixel(
    cameraTarget.latitude,
    cameraTarget.longitude,
    zoom,
  );
  return Offset(
    size.width / 2 + (point.dx - centre.dx),
    size.height / 2 + (point.dy - centre.dy),
  );
}

/// The inverse of [worldPixel]: which coordinate a point on the world
/// square is.
LatLng latLngOfWorldPixel(Offset point, double zoom) {
  final scale = worldTileSize * math.pow(2, zoom);
  final lng = point.dx / scale * 360 - 180;
  // Undo the mercator fold. tanh is the closed form of the (e^k - 1) /
  // (e^k + 1) this would otherwise be written as.
  final k = (0.5 - point.dy / scale) * 4 * math.pi;
  final lat = math.asin(_tanh(k / 2)) * 180 / math.pi;
  return LatLng(lat, lng);
}

double _tanh(double x) {
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}

/// The camera target that puts [position] at [screenPoint] in a viewport of
/// [size], at [zoom].
///
/// This is how the map lifts a selected cat clear of the sheet about to
/// cover the bottom of the screen. `GoogleMap.padding` is the sdk's own
/// answer to the same question and reads better — but the web target
/// ignores it, so the marker stayed where it was while everything
/// projected against that padding moved. Shifting the camera is arithmetic
/// this side of the platform boundary, and behaves identically on all
/// three.
LatLng cameraTargetPlacing(
  LatLng position, {
  required Offset screenPoint,
  required double zoom,
  required Size size,
}) {
  final point = worldPixel(position.latitude, position.longitude, zoom);
  return latLngOfWorldPixel(
    Offset(
      point.dx + (size.width / 2 - screenPoint.dx),
      point.dy + (size.height / 2 - screenPoint.dy),
    ),
    zoom,
  );
}
