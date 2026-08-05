import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/map/data/cats_api.dart';
import 'package:app/features/map/ui/cats_map_notifier.dart';

const _cat = CatMarker(
  id: 'cat-1',
  primaryPhoto:
      'https://upload.wikimedia.org/wikipedia/commons/thumb/4/4d/Cat_November_2010-1a.jpg/500px-Cat_November_2010-1a.jpg',
  lat: 41.0256,
  lng: 28.9744,
);

final _boundsA = LatLngBounds(
  southwest: const LatLng(41, 28),
  northeast: const LatLng(42, 29),
);
final _boundsB = LatLngBounds(
  southwest: const LatLng(40, 27),
  northeast: const LatLng(41, 28),
);

/// A fake CatsApi whose responses resolve on demand, so tests can control
/// completion order independently of call order.
class _ControllableCatsApi implements CatsApi {
  final _pending = <LatLngBounds, List<Completer<List<CatMarker>>>>{};

  Future<List<CatMarker>> _await(LatLngBounds bounds) {
    final completer = Completer<List<CatMarker>>();
    (_pending[bounds] ??= []).add(completer);
    return completer.future;
  }

  void resolve(LatLngBounds bounds, List<CatMarker> markers) {
    final completers = _pending[bounds];
    if (completers == null || completers.isEmpty) {
      throw StateError('no pending request for $bounds');
    }
    completers.removeAt(0).complete(markers);
  }

  @override
  Future<List<CatMarker>> fetchInBounds(LatLngBounds bounds) => _await(bounds);
}

void main() {
  test('a slower stale request never overwrites a newer one', () async {
    final api = _ControllableCatsApi();
    final container = ProviderContainer(
      overrides: [catsApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    final notifier = container.read(catsMapProvider.notifier);

    // start the slow (stale) request for boundsA, then the fast one for boundsB.
    final first = notifier.fetchForBounds(_boundsA);
    final second = notifier.fetchForBounds(_boundsB);

    // boundsB (the newer request) resolves first...
    api.resolve(_boundsB, const [_cat]);
    await second;

    // ...then the stale boundsA request finally resolves too.
    api.resolve(_boundsA, const []);
    await first;

    final state = container.read(catsMapProvider);
    expect(
      state.markers,
      [_cat],
      reason: 'the newer request result must win, not the stale one',
    );
  });

  test(
    'a failed request surfaces an error without discarding prior markers unexpectedly',
    () async {
      final api = _ControllableCatsApi();
      final container = ProviderContainer(
        overrides: [catsApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(catsMapProvider.notifier);

      final future = notifier.fetchForBounds(_boundsA);
      final completers = api._pending[_boundsA]!;
      completers.removeAt(0).completeError(Exception('network down'));
      await future;

      final state = container.read(catsMapProvider);
      expect(state.error, isNotNull);
      expect(state.isLoading, isFalse);
      expect(state.hasLoadedOnce, isTrue);
    },
  );

  test(
    'a successful fetch records the request bounds\' real search radius',
    () async {
      final api = _ControllableCatsApi();
      final container = ProviderContainer(
        overrides: [catsApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(catsMapProvider.notifier);
      final future = notifier.fetchForBounds(_boundsA);
      api.resolve(_boundsA, const [_cat]);
      await future;

      final state = container.read(catsMapProvider);
      // boundsA spans 1° of latitude (~111 km); center-to-nearest-edge is
      // the smaller half-span — well under 60 km, well over 30 km.
      expect(state.searchRadiusMeters, isNotNull);
      expect(state.searchRadiusMeters, greaterThan(30000));
      expect(state.searchRadiusMeters, lessThan(60000));
      expect(state.searchRadiusMeters, searchRadiusOf(_boundsA));
    },
  );

  test('every fetch bumps the attempt counter, including failures', () async {
    final api = _ControllableCatsApi();
    final container = ProviderContainer(
      overrides: [catsApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    final notifier = container.read(catsMapProvider.notifier);

    final first = notifier.fetchForBounds(_boundsA);
    expect(container.read(catsMapProvider).attempt, 1);
    api.resolve(_boundsA, const []);
    await first;
    expect(container.read(catsMapProvider).attempt, 1);

    final second = notifier.fetchForBounds(_boundsB);
    expect(container.read(catsMapProvider).attempt, 2);
    api._pending[_boundsB]!.removeAt(0).completeError(Exception('down'));
    await second;
    expect(container.read(catsMapProvider).attempt, 2);
  });

  test('selectCat sets the selected marker; clearSelection clears it', () {
    final container = ProviderContainer(
      overrides: [catsApiProvider.overrideWithValue(_ControllableCatsApi())],
    );
    addTearDown(container.dispose);

    final notifier = container.read(catsMapProvider.notifier);
    expect(container.read(catsMapProvider).selectedMarker, isNull);

    notifier.selectCat(_cat);
    expect(container.read(catsMapProvider).selectedMarker, _cat);

    notifier.clearSelection();
    expect(container.read(catsMapProvider).selectedMarker, isNull);
  });
}
