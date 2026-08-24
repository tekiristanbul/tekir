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

  void fail(LatLngBounds bounds, Object error) {
    final completers = _pending[bounds];
    if (completers == null || completers.isEmpty) {
      throw StateError('no pending request for $bounds');
    }
    completers.removeAt(0).completeError(error);
  }

  @override
  Future<List<CatMarker>> fetchInBounds(LatLngBounds bounds) => _await(bounds);
}

void main() {
  group('the selection survives a refetch', _selectionSurvivesRefetchTests);

  group('applyUpdate (issue #286)', _applyUpdateTests);

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

  test('only explicit retries bump the attempt counter, never plain '
      'fetches', () async {
    final api = _ControllableCatsApi();
    final container = ProviderContainer(
      overrides: [catsApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    final notifier = container.read(catsMapProvider.notifier);

    // plain fetches — the first read and camera-idle refetches — leave
    // the counter alone so the initial-read gate is never remounted by
    // panning the map.
    final first = notifier.fetchForBounds(_boundsA);
    expect(container.read(catsMapProvider).attempt, 0);
    api.resolve(_boundsA, const []);
    await first;
    expect(container.read(catsMapProvider).attempt, 0);

    final second = notifier.fetchForBounds(_boundsB);
    expect(container.read(catsMapProvider).attempt, 0);
    api._pending[_boundsB]!.removeAt(0).completeError(Exception('down'));
    await second;
    expect(container.read(catsMapProvider).attempt, 0);

    final retry = notifier.retryForBounds(_boundsB);
    expect(container.read(catsMapProvider).attempt, 1);
    api._pending[_boundsB]!.removeAt(0).completeError(Exception('down'));
    await retry;
    expect(container.read(catsMapProvider).attempt, 1);
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

  group('removeCat (issue #228)', () {
    const otherCat = CatMarker(
      id: 'cat-2',
      primaryPhoto: '',
      lat: 41.03,
      lng: 28.98,
    );

    test('drops exactly the matching marker, in place', () async {
      final api = _ControllableCatsApi();
      final container = ProviderContainer(
        overrides: [catsApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(catsMapProvider.notifier);
      final future = notifier.fetchForBounds(_boundsA);
      api.resolve(_boundsA, const [_cat, otherCat]);
      await future;

      notifier.removeCat(_cat.id);

      expect(container.read(catsMapProvider).markers, [otherCat]);
    });

    test('clears selectedMarker only when it is the removed cat', () async {
      final api = _ControllableCatsApi();
      final container = ProviderContainer(
        overrides: [catsApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(catsMapProvider.notifier);
      final future = notifier.fetchForBounds(_boundsA);
      api.resolve(_boundsA, const [_cat, otherCat]);
      await future;

      notifier.selectCat(otherCat);

      notifier.removeCat(_cat.id);
      expect(container.read(catsMapProvider).selectedMarker, otherCat);

      notifier.removeCat(otherCat.id);
      expect(container.read(catsMapProvider).selectedMarker, isNull);
    });

    test('is a no-op when the cat is absent — never an invalidate/refetch', () {
      final api = _ControllableCatsApi();
      final container = ProviderContainer(
        overrides: [catsApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(catsMapProvider.notifier);
      notifier.selectCat(_cat);

      notifier.removeCat('does-not-exist');

      expect(container.read(catsMapProvider).markers, isEmpty);
      // Still selected — an invalidate would have reset build()'s state and
      // cleared this too; removeCat's own no-op path must not.
      expect(container.read(catsMapProvider).selectedMarker, _cat);
      expect(api._pending, isEmpty);
    });
  });

  test('renameCat patches the matching marker in place, leaving the rest of '
      'the loaded viewport untouched (issue #230)', () async {
    const other = CatMarker(id: 'cat-2', primaryPhoto: '', lat: 41, lng: 29);
    final api = _ControllableCatsApi();
    final container = ProviderContainer(
      overrides: [catsApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    final notifier = container.read(catsMapProvider.notifier);
    final fetch = notifier.fetchForBounds(_boundsA);
    api.resolve(_boundsA, const [_cat, other]);
    await fetch;
    notifier.selectCat(_cat);

    notifier.renameCat('cat-1', 'boncuk');

    final state = container.read(catsMapProvider);
    expect(state.markers.map((m) => m.name), ['boncuk', '']);
    expect(state.selectedMarker?.name, 'boncuk');
    expect(state.hasLoadedOnce, isTrue);
  });

  test('renameCat is a no-op when the cat is not currently loaded', () async {
    final container = ProviderContainer(
      overrides: [catsApiProvider.overrideWithValue(_ControllableCatsApi())],
    );
    addTearDown(container.dispose);

    final notifier = container.read(catsMapProvider.notifier);
    notifier.renameCat('unknown-cat', 'boncuk');

    final state = container.read(catsMapProvider);
    expect(state.markers, isEmpty);
    expect(state.selectedMarker, isNull);
    expect(state.hasLoadedOnce, isFalse);
  });
}

// A refetch used to rebuild CatsMapState by hand and drop the selection.
// Selecting a cat moves the camera, the camera settling refetches the
// viewport, and the refetch landing deselected the cat — a second after the
// tap, with its sheet still open about it.
void _selectionSurvivesRefetchTests() {
  const cat = CatMarker(
    id: 'cat-1',
    name: 'tekir',
    primaryPhoto: '',
    lat: 41.0,
    lng: 29.0,
  );
  final bounds = LatLngBounds(
    southwest: const LatLng(40.9, 28.9),
    northeast: const LatLng(41.1, 29.1),
  );

  test('a viewport refetch leaves the selected cat selected', () async {
    final api = _ControllableCatsApi();
    final container = ProviderContainer(
      overrides: [catsApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(catsMapProvider.notifier);

    notifier.selectCat(cat);
    final pending = notifier.fetchForBounds(bounds);
    api.resolve(bounds, const [cat]);
    await pending;

    expect(container.read(catsMapProvider).selectedMarker?.id, 'cat-1');
  });

  test(
    'it stays selected even when it falls out of the new viewport',
    () async {
      final api = _ControllableCatsApi();
      final container = ProviderContainer(
        overrides: [catsApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(catsMapProvider.notifier);

      notifier.selectCat(cat);
      final pending = notifier.fetchForBounds(bounds);
      api.resolve(bounds, const []);
      await pending;

      // The sheet about this cat is still open; taking the selection away
      // under it would be the map contradicting the screen.
      expect(container.read(catsMapProvider).selectedMarker?.id, 'cat-1');
    },
  );

  test('a failed refetch leaves it selected too', () async {
    final api = _ControllableCatsApi();
    final container = ProviderContainer(
      overrides: [catsApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(catsMapProvider.notifier);

    notifier.selectCat(cat);
    final pending = notifier.fetchForBounds(bounds);
    api.fail(bounds, Exception('offline'));
    await pending;

    expect(container.read(catsMapProvider).selectedMarker?.id, 'cat-1');
  });

  test('clearing the selection is still the only thing that clears it', () {
    final container = ProviderContainer(
      overrides: [catsApiProvider.overrideWithValue(_ControllableCatsApi())],
    );
    addTearDown(container.dispose);
    final notifier = container.read(catsMapProvider.notifier);

    notifier.selectCat(cat);
    notifier.clearSelection();

    expect(container.read(catsMapProvider).selectedMarker, isNull);
  });
}

// issue #286: a cat updated from the map's own quick sheet reflects it
// without waiting for the next viewport read.
void _applyUpdateTests() {
  final alert = ActiveAlert(
    createdAt: DateTime.utc(2026, 3, 1, 9),
    expiresAt: DateTime.utc(2026, 3, 4, 9),
  );
  const cat = CatMarker(
    id: 'cat-1',
    name: 'tekir',
    primaryPhoto: '',
    lat: 41.0,
    lng: 29.0,
  );

  test('moves the marker freshness forward in place', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(catsMapProvider.notifier);
    notifier.state = const CatsMapState(markers: [cat], hasLoadedOnce: true);

    notifier.applyUpdate('cat-1', lastUpdateAt: DateTime.utc(2026, 3, 1, 9));

    expect(
      container.read(catsMapProvider).markers.single.lastUpdateAt,
      DateTime.utc(2026, 3, 1, 9),
    );
  });

  test('a help-carrying update puts the mark on the marker', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(catsMapProvider.notifier);
    notifier.state = const CatsMapState(markers: [cat], hasLoadedOnce: true);

    notifier.applyUpdate(
      'cat-1',
      lastUpdateAt: alert.createdAt,
      activeAlert: alert,
    );

    expect(container.read(catsMapProvider).markers.single.needsHelp, isTrue);
  });

  test('an ordinary update never clears an existing help mark', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(catsMapProvider.notifier);
    notifier.state = CatsMapState(
      markers: [
        CatMarker(
          id: 'cat-1',
          name: 'tekir',
          primaryPhoto: '',
          lat: 41.0,
          lng: 29.0,
          activeAlert: alert,
        ),
      ],
      hasLoadedOnce: true,
    );

    notifier.applyUpdate('cat-1', lastUpdateAt: DateTime.utc(2026, 3, 2));

    // Help ends by expiring, never because someone put food down.
    expect(container.read(catsMapProvider).markers.single.needsHelp, isTrue);
  });

  test('the open selection is patched alongside the marker', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(catsMapProvider.notifier);
    notifier.state = const CatsMapState(
      markers: [cat],
      selectedMarker: cat,
      hasLoadedOnce: true,
    );

    notifier.applyUpdate('cat-1', lastUpdateAt: DateTime.utc(2026, 3, 1, 9));

    expect(
      container.read(catsMapProvider).selectedMarker!.lastUpdateAt,
      DateTime.utc(2026, 3, 1, 9),
    );
  });

  test('a cat that is not loaded is left alone', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(catsMapProvider.notifier);
    notifier.state = const CatsMapState(markers: [cat], hasLoadedOnce: true);
    final before = container.read(catsMapProvider);

    notifier.applyUpdate('cat-999', lastUpdateAt: DateTime.utc(2026, 3, 1, 9));

    expect(identical(container.read(catsMapProvider), before), isTrue);
  });
}
