import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/network/api_client.dart';
import 'package:app/features/discover/data/discover_api.dart';
import 'package:app/features/discover/data/discover_cat.dart';
import 'package:app/features/discover/data/discover_location_service.dart';
import 'package:app/features/discover/ui/discover_notifier.dart';
import 'package:app/features/follow/data/follows_api.dart';
import 'package:app/features/map/data/cat_marker.dart';

class _FakeSessionIdentityService implements SessionIdentityService {
  SessionIdentity? _cached;

  @override
  SessionIdentity? get cached => _cached;

  @override
  Future<SessionIdentity?> restore() async => _cached;

  @override
  Future<SessionIdentity?> refreshIfExpired() async => _cached;

  @override
  Future<void> save(SessionIdentity identity) async => _cached = identity;

  @override
  Future<void> logout({String? deviceToken}) async => _cached = null;
}

class _FakeFollowsApi implements FollowsApi {
  @override
  Future<void> follow(String catId) async {}

  @override
  Future<void> unfollow(String catId) async {}

  @override
  Future<List<CatMarker>> fetchFollows() async => const [];
}

class _FakeLocationService extends DiscoverLocationService {
  _FakeLocationService(this.outcome);

  DiscoverLocationOutcome outcome;
  int calls = 0;

  @override
  Future<DiscoverLocationOutcome> resolve() async {
    calls++;
    return outcome;
  }
}

class _FakeDiscoverApi extends DiscoverApi {
  _FakeDiscoverApi(this.pages) : super(ApiClient());

  /// One entry consumed per call, in order — lets a test script exactly
  /// what each successive page (or a mid-sequence error) should be.
  final List<Object> pages;
  int calls = 0;
  final List<String?> cursorsSeen = [];

  @override
  Future<DiscoverPage> fetch({
    required DiscoverFilter filter,
    required double lat,
    required double lng,
    String? cursor,
  }) async {
    cursorsSeen.add(cursor);
    final next = pages[calls];
    calls++;
    if (next is Exception) throw next;
    return next as DiscoverPage;
  }
}

const _resolved = DiscoverLocationResolved(lat: 41.0, lng: 29.0);

ProviderContainer _buildContainer({
  required _FakeLocationService location,
  required _FakeDiscoverApi discoverApi,
}) {
  final container = ProviderContainer(
    overrides: [
      sessionIdentityServiceProvider.overrideWithValue(
        _FakeSessionIdentityService(),
      ),
      followsApiProvider.overrideWithValue(_FakeFollowsApi()),
      discoverLocationServiceProvider.overrideWithValue(location),
      discoverApiProvider.overrideWithValue(discoverApi),
    ],
  );
  return container;
}

void main() {
  test('ensureNearbyLoaded only fetches once across repeated calls', () async {
    final location = _FakeLocationService(_resolved);
    final api = _FakeDiscoverApi([const DiscoverPage(items: [])]);
    final container = _buildContainer(location: location, discoverApi: api);
    addTearDown(container.dispose);

    await container.read(discoverProvider.notifier).ensureNearbyLoaded();
    await container.read(discoverProvider.notifier).ensureNearbyLoaded();
    await container.read(discoverProvider.notifier).ensureNearbyLoaded();

    expect(api.calls, 1);
    expect(location.calls, 1);
    expect(container.read(discoverProvider).nearby.hasLoadedOnce, isTrue);
  });

  test('retryNearby re-resolves location even after hasLoadedOnce', () async {
    final location = _FakeLocationService(
      const DiscoverLocationPermissionDenied(),
    );
    final api = _FakeDiscoverApi([const DiscoverPage(items: [])]);
    final container = _buildContainer(location: location, discoverApi: api);
    addTearDown(container.dispose);

    await container.read(discoverProvider.notifier).ensureNearbyLoaded();
    expect(location.calls, 1);
    expect(
      container.read(discoverProvider).nearby.locationOutcome,
      isA<DiscoverLocationPermissionDenied>(),
    );

    location.outcome = _resolved;
    await container.read(discoverProvider.notifier).retryNearby();

    expect(location.calls, 2);
    expect(
      container.read(discoverProvider).nearby.locationOutcome,
      isA<DiscoverLocationResolved>(),
    );
    expect(api.calls, 1);
  });

  test(
    'loadMoreNearby appends the next page and advances the cursor',
    () async {
      final location = _FakeLocationService(_resolved);
      final api = _FakeDiscoverApi([
        const DiscoverPage(
          items: [DiscoverCat(id: 'a', primaryPhoto: '', distanceMeters: 10)],
          nextCursor: 'cursor-1',
        ),
        const DiscoverPage(
          items: [DiscoverCat(id: 'b', primaryPhoto: '', distanceMeters: 20)],
        ),
      ]);
      final container = _buildContainer(location: location, discoverApi: api);
      addTearDown(container.dispose);

      await container.read(discoverProvider.notifier).ensureNearbyLoaded();
      expect(container.read(discoverProvider).nearby.cats, hasLength(1));
      expect(container.read(discoverProvider).nearby.hasMore, isTrue);

      await container.read(discoverProvider.notifier).loadMoreNearby();

      final nearby = container.read(discoverProvider).nearby;
      expect(nearby.cats.map((c) => c.id), ['a', 'b']);
      expect(nearby.hasMore, isFalse);
      expect(api.cursorsSeen, [null, 'cursor-1']);
    },
  );

  test('loadMoreNearby is a no-op once there is no next cursor', () async {
    final location = _FakeLocationService(_resolved);
    final api = _FakeDiscoverApi([const DiscoverPage(items: [])]);
    final container = _buildContainer(location: location, discoverApi: api);
    addTearDown(container.dispose);

    await container.read(discoverProvider.notifier).ensureNearbyLoaded();
    await container.read(discoverProvider.notifier).loadMoreNearby();

    expect(api.calls, 1);
  });

  test('loadMoreNearby is a no-op when location was never resolved', () async {
    final location = _FakeLocationService(
      const DiscoverLocationPermissionDenied(),
    );
    final api = _FakeDiscoverApi([const DiscoverPage(items: [])]);
    final container = _buildContainer(location: location, discoverApi: api);
    addTearDown(container.dispose);

    await container.read(discoverProvider.notifier).ensureNearbyLoaded();
    await container.read(discoverProvider.notifier).loadMoreNearby();

    expect(api.calls, 0);
  });

  test('nearby and needsHelp tabs load and page independently', () async {
    final location = _FakeLocationService(_resolved);
    final api = _FakeDiscoverApi([
      const DiscoverPage(
        items: [
          DiscoverCat(id: 'nearby-1', primaryPhoto: '', distanceMeters: 5),
        ],
      ),
      const DiscoverPage(
        items: [DiscoverCat(id: 'help-1', primaryPhoto: '', distanceMeters: 5)],
      ),
    ]);
    final container = _buildContainer(location: location, discoverApi: api);
    addTearDown(container.dispose);

    await container.read(discoverProvider.notifier).ensureNearbyLoaded();
    await container.read(discoverProvider.notifier).ensureNeedsHelpLoaded();

    final state = container.read(discoverProvider);
    expect(state.nearby.cats.single.id, 'nearby-1');
    expect(state.needsHelp.cats.single.id, 'help-1');
  });

  test(
    'selectTab only changes selectedTab, never fetches on its own',
    () async {
      final location = _FakeLocationService(_resolved);
      final api = _FakeDiscoverApi([const DiscoverPage(items: [])]);
      final container = _buildContainer(location: location, discoverApi: api);
      addTearDown(container.dispose);

      container
          .read(discoverProvider.notifier)
          .selectTab(DiscoverTab.needsHelp);

      expect(
        container.read(discoverProvider).selectedTab,
        DiscoverTab.needsHelp,
      );
      expect(api.calls, 0);
      expect(location.calls, 0);
    },
  );

  test('renameCat patches the matching cat in place across all three tabs, '
      'leaving the rest of the loaded lists untouched (issue #230)', () async {
    final location = _FakeLocationService(_resolved);
    final api = _FakeDiscoverApi([
      const DiscoverPage(
        items: [
          DiscoverCat(id: 'cat-1', primaryPhoto: '', distanceMeters: 5),
          DiscoverCat(id: 'cat-2', primaryPhoto: '', distanceMeters: 10),
        ],
      ),
      const DiscoverPage(
        items: [DiscoverCat(id: 'cat-1', primaryPhoto: '', distanceMeters: 5)],
      ),
    ]);
    final container = ProviderContainer(
      overrides: [
        sessionIdentityServiceProvider.overrideWithValue(
          _FakeSessionIdentityService(),
        ),
        followsApiProvider.overrideWithValue(
          _FollowsApiWith([
            const CatMarker(id: 'cat-1', primaryPhoto: '', lat: 41, lng: 29),
          ]),
        ),
        discoverLocationServiceProvider.overrideWithValue(location),
        discoverApiProvider.overrideWithValue(api),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(discoverProvider.notifier);
    await notifier.ensureNearbyLoaded();
    await notifier.ensureNeedsHelpLoaded();
    await notifier.loadFollowing();

    notifier.renameCat('cat-1', 'boncuk');

    final state = container.read(discoverProvider);
    expect(state.nearby.cats.map((c) => c.name), ['boncuk', '']);
    expect(state.needsHelp.cats.single.name, 'boncuk');
    expect(state.following.cats.single.name, 'boncuk');
  });

  test('renameCat is a no-op when the cat is not currently loaded', () async {
    final location = _FakeLocationService(_resolved);
    final api = _FakeDiscoverApi([const DiscoverPage(items: [])]);
    final container = _buildContainer(location: location, discoverApi: api);
    addTearDown(container.dispose);

    final notifier = container.read(discoverProvider.notifier);
    notifier.renameCat('unknown-cat', 'boncuk');

    final state = container.read(discoverProvider);
    expect(state.nearby.cats, isEmpty);
    expect(state.needsHelp.cats, isEmpty);
    expect(state.following.cats, isEmpty);
  });
}

class _FollowsApiWith implements FollowsApi {
  _FollowsApiWith(this.cats);

  final List<CatMarker> cats;

  @override
  Future<void> follow(String catId) async {}

  @override
  Future<void> unfollow(String catId) async {}

  @override
  Future<List<CatMarker>> fetchFollows() async => cats;
}
