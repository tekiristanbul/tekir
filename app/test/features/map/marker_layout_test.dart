import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/map/data/marker_layout.dart';

CatMarker _cat(String id, double lat, double lng) =>
    CatMarker(id: id, primaryPhoto: '', lat: lat, lng: lng);

void main() {
  group('fanOutCoincident', () {
    test('leaves cats that do not share a spot where they are', () {
      final fanned = fanOutCoincident([
        _cat('a', 41.0256, 28.9744),
        _cat('b', 41.0300, 28.9800),
      ]);

      expect(fanned, isEmpty);
    });

    // Identical coordinates make the pin drawn last the only tappable one:
    // the others are unreachable, not merely hidden.
    test('spreads cats recorded at the same coordinate apart', () {
      const lat = 41.0256;
      const lng = 28.9744;
      final fanned = fanOutCoincident([
        _cat('a', lat, lng),
        _cat('b', lat, lng),
        _cat('c', lat, lng),
      ]);

      expect(fanned.keys, containsAll(<String>['a', 'b', 'c']));
      final positions = fanned.values.toList();
      for (var i = 0; i < positions.length; i++) {
        for (var j = i + 1; j < positions.length; j++) {
          final dLat = positions[i].latitude - positions[j].latitude;
          final dLng = positions[i].longitude - positions[j].longitude;
          expect(
            math.sqrt(dLat * dLat + dLng * dLng),
            greaterThan(coincidenceEpsilonDegrees),
            reason: 'pins $i and $j would still overlap',
          );
        }
      }
    });

    test('keeps every pin within a few metres of the real spot', () {
      const lat = 41.0256;
      const lng = 28.9744;
      final fanned = fanOutCoincident([
        _cat('a', lat, lng),
        _cat('b', lat, lng),
      ]);

      for (final position in fanned.values) {
        expect((position.latitude - lat).abs(), lessThan(0.0002));
        expect((position.longitude - lng).abs(), lessThan(0.0002));
      }
    });

    // A pin that jumped between rebuilds would be worse than one that
    // overlaps: the arrangement is derived from the cats' own ids, not from
    // the order the api returned them in.
    test('places a cat identically regardless of input order', () {
      const lat = 41.0256;
      const lng = 28.9744;
      final first = fanOutCoincident([
        _cat('a', lat, lng),
        _cat('b', lat, lng),
      ]);
      final second = fanOutCoincident([
        _cat('b', lat, lng),
        _cat('a', lat, lng),
      ]);

      expect(first['a']!.latitude, second['a']!.latitude);
      expect(first['a']!.longitude, second['a']!.longitude);
      expect(first['b']!.latitude, second['b']!.latitude);
    });
  });

  group('draw order', () {
    test('the selected pin outranks every unselected one', () {
      expect(selectedMarkerZIndex, greaterThan(latitudeZIndex(-90)));
      expect(selectedMarkerZIndex, greaterThan(latitudeZIndex(90)));
    });

    // Southern pins over northern ones — the convention a map reader
    // expects, and stable, so the same cat wins the same overlap on every
    // rebuild instead of flickering between them.
    test('southern pins draw above northern ones', () {
      expect(latitudeZIndex(41.00), greaterThan(latitudeZIndex(41.05)));
    });
  });
}
