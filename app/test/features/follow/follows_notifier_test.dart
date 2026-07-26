import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/features/follow/data/follows_api.dart';
import 'package:app/features/follow/ui/follow_state_notifier.dart';
import 'package:app/features/map/data/cat_marker.dart';

// Mirrors auth_gate_test.dart's fake exactly.
class _FakeSessionIdentityService implements SessionIdentityService {
  _FakeSessionIdentityService({SessionIdentity? initial}) : _cached = initial;

  SessionIdentity? _cached;

  @override
  SessionIdentity? get cached => _cached;

  @override
  Future<SessionIdentity?> restore() async => _cached;

  @override
  Future<void> save(SessionIdentity identity) async => _cached = identity;

  @override
  Future<void> logout() async => _cached = null;
}

const _session = SessionIdentity(
  accessToken: 'at',
  refreshToken: 'rt',
  userId: 'u1',
);

const _marker = CatMarker(
  id: 'cat-1',
  name: 'tekir',
  primaryPhoto: '',
  lat: 41.0256,
  lng: 28.9744,
);

class _FakeFollowsApi implements FollowsApi {
  List<CatMarker> fetchResult = const [];
  Object? followError;
  Object? unfollowError;
  int followCalls = 0;
  int unfollowCalls = 0;

  @override
  Future<void> follow(String catId) async {
    followCalls++;
    if (followError != null) throw followError!;
  }

  @override
  Future<void> unfollow(String catId) async {
    unfollowCalls++;
    if (unfollowError != null) throw unfollowError!;
  }

  @override
  Future<List<CatMarker>> fetchFollows() async => fetchResult;
}

ProviderContainer _containerWith({
  SessionIdentityService? session,
  FollowsApi? followsApi,
}) {
  final container = ProviderContainer(
    overrides: [
      sessionIdentityServiceProvider.overrideWithValue(
        session ?? _FakeSessionIdentityService(),
      ),
      followsApiProvider.overrideWithValue(followsApi ?? _FakeFollowsApi()),
    ],
  );
  return container;
}

void main() {
  test(
    'a guest (no session) resolves to an empty set, without calling the api',
    () async {
      final api = _FakeFollowsApi()..fetchResult = const [_marker];
      final container = _containerWith(followsApi: api);
      addTearDown(container.dispose);

      await container.read(sessionProvider.future);
      final follows = await container.read(followsProvider.future);

      expect(follows, isEmpty);
    },
  );

  test(
    'an authenticated session loads the account\'s followed cat ids',
    () async {
      final api = _FakeFollowsApi()..fetchResult = const [_marker];
      final container = _containerWith(
        session: _FakeSessionIdentityService(initial: _session),
        followsApi: api,
      );
      addTearDown(container.dispose);

      await container.read(sessionProvider.future);
      final follows = await container.read(followsProvider.future);

      expect(follows, {'cat-1'});
    },
  );

  test('toggle follows an unfollowed cat on success', () async {
    final api = _FakeFollowsApi();
    final container = _containerWith(
      session: _FakeSessionIdentityService(initial: _session),
      followsApi: api,
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    await container.read(followsProvider.future);

    await container.read(followsProvider.notifier).toggle('cat-1');

    expect(container.read(followsProvider).value, {'cat-1'});
    expect(api.followCalls, 1);
  });

  test('toggle unfollows an already-followed cat on success', () async {
    final api = _FakeFollowsApi()..fetchResult = const [_marker];
    final container = _containerWith(
      session: _FakeSessionIdentityService(initial: _session),
      followsApi: api,
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    await container.read(followsProvider.future);

    await container.read(followsProvider.notifier).toggle('cat-1');

    expect(container.read(followsProvider).value, isEmpty);
    expect(api.unfollowCalls, 1);
  });

  test('toggle leaves state unchanged and rethrows on failure', () async {
    final api = _FakeFollowsApi()..followError = const FollowServerException();
    final container = _containerWith(
      session: _FakeSessionIdentityService(initial: _session),
      followsApi: api,
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    await container.read(followsProvider.future);

    await expectLater(
      container.read(followsProvider.notifier).toggle('cat-1'),
      throwsA(isA<FollowServerException>()),
    );
    expect(container.read(followsProvider).value, isEmpty);
  });

  test('logging out clears the followed set back to empty', () async {
    final api = _FakeFollowsApi()..fetchResult = const [_marker];
    final sessionService = _FakeSessionIdentityService(initial: _session);
    final container = _containerWith(session: sessionService, followsApi: api);
    addTearDown(container.dispose);

    await container.read(sessionProvider.future);
    expect(await container.read(followsProvider.future), {'cat-1'});

    await container.read(sessionProvider.notifier).logout();
    expect(await container.read(followsProvider.future), isEmpty);
  });

  test('signing in loads the newly-authenticated account\'s follows', () async {
    final api = _FakeFollowsApi()..fetchResult = const [_marker];
    final sessionService = _FakeSessionIdentityService();
    final container = _containerWith(session: sessionService, followsApi: api);
    addTearDown(container.dispose);

    await container.read(sessionProvider.future);
    expect(await container.read(followsProvider.future), isEmpty);

    await container.read(sessionProvider.notifier).save(_session);
    expect(await container.read(followsProvider.future), {'cat-1'});
  });
}
