import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:app/features/map/spike/map_projection.dart';

/// Issue #280, concept 1. The lens projects coordinates itself rather than
/// asking the sdk, so the projection has to be right on its own terms: a
/// scale error here would put every pin somewhere plausible and wrong, and
/// nothing on screen would say so.
void main() {
  const size = Size(390, 844);

  test('the camera target lands in the middle of the map', () {
    const projection = MapProjection(
      center: LatLng(41.0256, 28.9744),
      zoom: 17,
      size: size,
    );

    final point = projection.toScreen(const LatLng(41.0256, 28.9744));
    expect(point.dx, closeTo(195, 0.001));
    expect(point.dy, closeTo(422, 0.001));
  });

  test('east is right and north is up', () {
    const projection = MapProjection(
      center: LatLng(41.0256, 28.9744),
      zoom: 17,
      size: size,
    );

    expect(
      projection.toScreen(const LatLng(41.0256, 28.9754)).dx,
      greaterThan(195),
    );
    expect(
      projection.toScreen(const LatLng(41.0266, 28.9744)).dy,
      lessThan(422),
    );
  });

  test('one zoom level doubles the distance between two coordinates', () {
    const a = LatLng(41.0256, 28.9744);
    const b = LatLng(41.0266, 28.9754);
    const near = MapProjection(center: a, zoom: 16, size: size);
    const far = MapProjection(center: a, zoom: 17, size: size);

    final atSixteen = (near.toScreen(b) - near.toScreen(a)).distance;
    final atSeventeen = (far.toScreen(b) - far.toScreen(a)).distance;
    expect(atSeventeen, closeTo(atSixteen * 2, 0.001));
  });

  test('the seeded Galata group lands within a pin of itself at zoom 17', () {
    // The whole reason concept 1 exists, stated as a measurement: seven
    // cats forty metres apart are one pin's worth of screen at the zoom
    // the map opens on.
    const projection = MapProjection(
      center: LatLng(41.02561, 28.97440),
      zoom: 17,
      size: size,
    );

    final tekir = projection.toScreen(const LatLng(41.02561, 28.97440));
    final boncuk = projection.toScreen(const LatLng(41.02575, 28.97455));
    expect((boncuk - tekir).distance, lessThan(44));
  });

  test('scale matches google\'s own metres-per-pixel at this latitude', () {
    // At zoom 17 and 41° north a logical pixel is about 0.9 m
    // (156543.03 · cos(lat) / 2^zoom). Roughly a tenth of a degree of
    // tolerance is plenty to catch a wrong tile size or a missing
    // mercator term, which are the mistakes that matter.
    const projection = MapProjection(
      center: LatLng(41.0, 28.9744),
      zoom: 17,
      size: size,
    );
    final a = projection.toScreen(const LatLng(41.0, 28.9744));
    // 0.001° of longitude at 41° north is about 84 m.
    final b = projection.toScreen(const LatLng(41.0, 28.9754));
    final metresPerPixel = 84.0 / (b - a).distance;
    expect(metresPerPixel, closeTo(0.9, 0.1));
  });
}
