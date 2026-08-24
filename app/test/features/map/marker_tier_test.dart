import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:app/core/geo/istanbul_bounds.dart';
import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/map/data/map_style.dart';
import 'package:app/features/map/data/marker_tier.dart';
import 'package:app/features/map/data/web_mercator.dart';

final _alert = ActiveAlert(
  createdAt: DateTime.utc(2026, 3, 1),
  expiresAt: DateTime.utc(2027, 3, 1),
);

CatMarker _cat(
  String id, {
  double lat = 41.02,
  double lng = 28.97,
  bool needsHelp = false,
}) => CatMarker(
  id: id,
  name: id,
  primaryPhoto: '',
  lat: lat,
  lng: lng,
  activeAlert: needsHelp ? _alert : null,
);

void main() {
  group('basemap style', _mapStyleTests);

  group('tierForZoom', () {
    test('follows the approved design thresholds', () {
      expect(tierForZoom(20), MarkerTier.avatar);
      expect(tierForZoom(17), MarkerTier.avatar);
      expect(tierForZoom(16.99), MarkerTier.silhouette);
      expect(tierForZoom(14), MarkerTier.silhouette);
      expect(tierForZoom(13.99), MarkerTier.dot);
      expect(tierForZoom(istanbulMinZoom), MarkerTier.dot);
    });
  });

  group('resolveTiers', () {
    test('draws every cat at the zoom tier below the avatar band', () {
      final tiers = resolveTiers(
        cats: [for (var i = 0; i < 30; i++) _cat('$i')],
        zoom: 12,
        cameraLat: 41.02,
        cameraLng: 28.97,
      );

      expect(tiers.values.every((t) => t == MarkerTier.dot), isTrue);
    });

    test('keeps the selected cat legible below the avatar band', () {
      final tiers = resolveTiers(
        cats: [_cat('a'), _cat('b')],
        zoom: 12,
        cameraLat: 41.02,
        cameraLng: 28.97,
        selectedId: 'a',
      );

      expect(tiers['a'], MarkerTier.avatar);
      expect(tiers['b'], MarkerTier.dot);
    });

    test('gives every cat an avatar while inside the budget', () {
      final tiers = resolveTiers(
        cats: [for (var i = 0; i < maxAvatarMarkers; i++) _cat('$i')],
        zoom: 18,
        cameraLat: 41.02,
        cameraLng: 28.97,
      );

      expect(tiers.values.every((t) => t == MarkerTier.avatar), isTrue);
    });

    test('drops the overflow to a silhouette rather than hiding it', () {
      final cats = [for (var i = 0; i < maxAvatarMarkers + 5; i++) _cat('$i')];

      final tiers = resolveTiers(
        cats: cats,
        zoom: 18,
        cameraLat: 41.02,
        cameraLng: 28.97,
      );

      expect(tiers.length, cats.length);
      expect(
        tiers.values.where((t) => t == MarkerTier.avatar).length,
        maxAvatarMarkers,
      );
      expect(tiers.values.where((t) => t == MarkerTier.silhouette).length, 5);
    });

    test('a cat that needs help keeps its face over one that does not', () {
      // Every ordinary cat sits at the camera; the one needing help is far
      // away, so only the help rule can put it inside the budget.
      final cats = [
        for (var i = 0; i < maxAvatarMarkers; i++) _cat('near-$i'),
        _cat('helped', lat: 41.30, lng: 29.40, needsHelp: true),
      ];

      final tiers = resolveTiers(
        cats: cats,
        zoom: 18,
        cameraLat: 41.02,
        cameraLng: 28.97,
      );

      expect(tiers['helped'], MarkerTier.avatar);
    });

    test('otherwise prefers what the camera is looking at', () {
      final cats = [
        for (var i = 0; i < maxAvatarMarkers; i++)
          _cat('far-$i', lat: 41.30, lng: 29.40),
        _cat('centred', lat: 41.02, lng: 28.97),
      ];

      final tiers = resolveTiers(
        cats: cats,
        zoom: 18,
        cameraLat: 41.02,
        cameraLng: 28.97,
      );

      expect(tiers['centred'], MarkerTier.avatar);
    });

    test('resolves the same way twice for the same inputs', () {
      final cats = [
        for (var i = 0; i < maxAvatarMarkers + 4; i++)
          _cat('$i', lat: 41.02, lng: 28.97),
      ];

      final first = resolveTiers(
        cats: cats,
        zoom: 18,
        cameraLat: 41.02,
        cameraLng: 28.97,
      );
      final second = resolveTiers(
        cats: cats.reversed.toList(),
        zoom: 18,
        cameraLat: 41.02,
        cameraLng: 28.97,
      );

      expect(second, first);
    });
  });

  group('clusterCats', () {
    test('groups cats sharing a screen cell and leaves the rest alone', () {
      // Two cats a few metres apart, and one several streets away.
      final grouped = clusterCats(
        cats: [
          _cat('a', lat: 41.0250, lng: 28.9740),
          _cat('b', lat: 41.02502, lng: 28.97402),
          _cat('far', lat: 41.0400, lng: 28.9900),
        ],
        zoom: 15,
      );

      expect(grouped.clusters.length, 1);
      expect(grouped.clusters.single.count, 2);
      expect(grouped.loose.map((c) => c.id), ['far']);
    });

    test('splits a group as the zoom pulls the cats apart', () {
      final cats = [
        _cat('a', lat: 41.0250, lng: 28.9740),
        _cat('b', lat: 41.0253, lng: 28.9744),
      ];

      expect(clusterCats(cats: cats, zoom: 13).clusters, hasLength(1));
      expect(clusterCats(cats: cats, zoom: 20).clusters, isEmpty);
    });

    test('a cluster reports whether anything inside it needs help', () {
      final grouped = clusterCats(
        cats: [
          _cat('a', lat: 41.0250, lng: 28.9740),
          _cat('b', lat: 41.02502, lng: 28.97402, needsHelp: true),
        ],
        zoom: 15,
      );

      expect(grouped.clusters.single.containsHelp, isTrue);
    });

    test('the selected cat is never folded into a group', () {
      final grouped = clusterCats(
        cats: [
          _cat('a', lat: 41.0250, lng: 28.9740),
          _cat('b', lat: 41.02502, lng: 28.97402),
          _cat('c', lat: 41.02503, lng: 28.97403),
        ],
        zoom: 15,
        selectedId: 'b',
      );

      expect(grouped.loose.map((c) => c.id), contains('b'));
      expect(
        grouped.clusters.single.cats.map((c) => c.id),
        isNot(contains('b')),
      );
    });

    test('every cat is accounted for exactly once', () {
      final cats = [
        for (var i = 0; i < 40; i++)
          _cat('$i', lat: 41.02 + i * 0.0004, lng: 28.97 + i * 0.0004),
      ];

      final grouped = clusterCats(cats: cats, zoom: 16);

      final seen = <String>{
        ...grouped.loose.map((c) => c.id),
        ...grouped.clusters.expand((c) => c.cats).map((c) => c.id),
      };
      expect(seen.length, cats.length);
    });

    test('the same cats produce the same cluster ids and order', () {
      final cats = [
        _cat('b', lat: 41.0250, lng: 28.9740),
        _cat('a', lat: 41.02502, lng: 28.97402),
      ];

      final first = clusterCats(cats: cats, zoom: 15);
      final second = clusterCats(cats: cats.reversed.toList(), zoom: 15);

      expect(second.clusters.map((c) => c.id), first.clusters.map((c) => c.id));
      expect(
        second.clusters.single.cats.map((c) => c.id),
        first.clusters.single.cats.map((c) => c.id),
      );
    });
  });

  group('zoomAfterClusterTap', () {
    test('always moves forward, and never past the ceiling', () {
      expect(zoomAfterClusterTap(14, istanbulMaxZoom), greaterThan(14));
      expect(zoomAfterClusterTap(19.5, istanbulMaxZoom), istanbulMaxZoom);
    });
  });

  group('web mercator', () {
    test('the camera target lands at the centre of the viewport', () {
      const target = LatLng(41.02, 28.97);

      final offset = screenOffsetOf(
        target,
        cameraTarget: target,
        zoom: 16,
        size: const Size(400, 800),
      );

      expect(offset.dx, closeTo(200, 0.001));
      expect(offset.dy, closeTo(400, 0.001));
    });

    test('north is up and east is right', () {
      const target = LatLng(41.02, 28.97);
      const size = Size(400, 800);

      final north = screenOffsetOf(
        const LatLng(41.03, 28.97),
        cameraTarget: target,
        zoom: 16,
        size: size,
      );
      final east = screenOffsetOf(
        const LatLng(41.02, 28.98),
        cameraTarget: target,
        zoom: 16,
        size: size,
      );

      expect(north.dy, lessThan(400));
      expect(east.dx, greaterThan(200));
    });

    test('one zoom step doubles the distance from the centre', () {
      const target = LatLng(41.02, 28.97);
      const other = LatLng(41.03, 28.98);
      const size = Size(400, 800);

      final near = screenOffsetOf(
        other,
        cameraTarget: target,
        zoom: 15,
        size: size,
      );
      final far = screenOffsetOf(
        other,
        cameraTarget: target,
        zoom: 16,
        size: size,
      );

      expect(far.dx - 200, closeTo((near.dx - 200) * 2, 0.001));
      expect(far.dy - 400, closeTo((near.dy - 400) * 2, 0.001));
    });
  });
}

// issue #285: the map's own ground. A malformed style string is accepted
// silently by the sdk and simply does nothing, so the one thing worth
// asserting here is that it is a well-formed document carrying the design's
// colours rather than google's defaults.
void _mapStyleTests() {
  test('is valid json', () {
    expect(() => jsonDecode(catsOfIstanbulMapStyle), returnsNormally);
    expect(jsonDecode(catsOfIstanbulMapStyle), isA<List<dynamic>>());
  });

  /// Relative luminance, the thing a value ramp is actually made of.
  double luminance(String hex) {
    final h = hex.replaceFirst('#', '');
    double channel(int i) {
      final c = int.parse(h.substring(i, i + 2), radix: 16) / 255;
      return c <= 0.03928
          ? c / 12.92
          : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * channel(0) + 0.7152 * channel(2) + 0.0722 * channel(4);
  }

  /// The colour a feature's geometry is painted, from the style itself —
  /// so this reads what the map will actually draw rather than a list of
  /// hexes copied beside it.
  String geometryColour(String feature) {
    final rules = (jsonDecode(catsOfIstanbulMapStyle) as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final rule = rules.lastWhere(
      (r) => r['featureType'] == feature && r['elementType'] == 'geometry',
      orElse: () => throw StateError('no geometry rule for $feature'),
    );
    final styler = (rule['stylers'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere((s) => s['color'] != null);
    return styler['color'] as String;
  }

  /// The ground: the one rule with no featureType at all.
  String groundColour() {
    final rules = (jsonDecode(catsOfIstanbulMapStyle) as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final rule = rules.firstWhere(
      (r) => r['featureType'] == null && r['elementType'] == 'geometry',
    );
    final styler = (rule['stylers'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere((s) => s['color'] != null);
    return styler['color'] as String;
  }

  test('is warm paper, not google grey', () {
    // Every ground and road tone stays on the design's warm ramp: more red
    // than blue, never a neutral or cool one.
    for (final feature in ['road.local', 'road.arterial', 'road.highway']) {
      final hex = geometryColour(feature).replaceFirst('#', '');
      final r = int.parse(hex.substring(0, 2), radix: 16);
      final b = int.parse(hex.substring(4, 6), radix: 16);
      expect(r, greaterThan(b), reason: '$feature is not a warm tone');
    }
  });

  // The first pass at this style put the ground and the roads two steps
  // apart on one ramp — which the design's own artboard can afford, because
  // it draws four roads on an empty rectangle. A real istanbul viewport is
  // mostly road, and at that density it read as one flat dark mass.
  test('the ground is lighter than every road on it', () {
    final ground = luminance(groundColour());
    for (final road in ['road.local', 'road.arterial', 'road.highway']) {
      expect(
        luminance(geometryColour(road)),
        lessThan(ground),
        reason: '$road is not darker than the ground',
      );
    }
  });

  test('roads separate from the ground rather than melting into it', () {
    final ground = luminance(groundColour());
    final local = luminance(geometryColour('road.local'));
    // The margin the first pass missed: its ground and road sat 0.06 apart
    // in luminance, which disappears at street density.
    expect(
      ground - local,
      greaterThan(0.1),
      reason: 'the quietest road is too close in value to the ground',
    );
  });

  test('a main road reads differently from a side street', () {
    final local = luminance(geometryColour('road.local'));
    final arterial = luminance(geometryColour('road.arterial'));
    final highway = luminance(geometryColour('road.highway'));

    expect(arterial, lessThan(local));
    expect(highway, lessThan(arterial));
  });

  test('parks and water are their own values, not just their own hues', () {
    final local = luminance(geometryColour('road.local'));
    for (final feature in ['poi.park', 'water']) {
      expect(
        (luminance(geometryColour(feature)) - local).abs(),
        greaterThan(0.02),
        reason: '$feature is separated from a side street by hue alone',
      );
    }
  });

  test('keeps the map quiet: no poi, transit or icon clutter', () {
    final rules = (jsonDecode(catsOfIstanbulMapStyle) as List<dynamic>)
        .cast<Map<String, dynamic>>();

    bool hidden(String feature) => rules.any(
      (r) =>
          r['featureType'] == feature &&
          r['elementType'] == null &&
          (r['stylers'] as List<dynamic>).any(
            (s) => (s as Map<String, dynamic>)['visibility'] == 'off',
          ),
    );

    expect(hidden('poi'), isTrue);
    expect(hidden('transit'), isTrue);
  });
}
