import 'dart:async';

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
  Future<SessionIdentity?> refreshIfExpired() async => _cached;

  @override
  Future<void> save(SessionIdentity identity) async => _cached = identity;

  @override
  Future<void> logout({String? deviceToken}) async => _cached = null;
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

  /// When set, `follow` waits on this instead of returning immediately —
  /// the in-flight window an optimistic toggle is supposed to fill.
  Completer<void>? followGate;

  @override
  Future<void> follow(String catId) async {
    followCalls++;
    final gate = followGate;
    if (gate != null) await gate.future;
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

  test('toggle flips local state before the request resolves', () async {
    final api = _FakeFollowsApi()..followGate = Completer<void>();
    final container = _containerWith(
      session: _FakeSessionIdentityService(initial: _session),
      followsApi: api,
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    await container.read(followsProvider.future);

    final pending = container.read(followsProvider.notifier).toggle('cat-1');

    // The request has been issued and has not answered, and the cat already
    // reads as followed: this is the same-frame feedback the state contract
    // requires of every user-triggered mutation.
    expect(api.followCalls, 1);
    expect(container.read(followsProvider).value, {'cat-1'});

    api.followGate!.complete();
    await pending;
    expect(container.read(followsProvider).value, {'cat-1'});
  });

  test('a read issued before a confirmed toggle never undoes it', () async {
    // The resumed-intent shape: a fetch is in flight, the user follows,
    // and the fetch answers from a moment before that follow existed.
    final api = _FakeFollowsApi();
    final container = _containerWith(
      session: _FakeSessionIdentityService(initial: _session),
      followsApi: api,
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    await container.read(followsProvider.future);

    await container.read(followsProvider.notifier).toggle('cat-1');
    // Re-running build is what a session change does; the api still does
    // not know about the follow.
    container.invalidate(followsProvider);

    expect(await container.read(followsProvider.future), {'cat-1'});
  });

  test(
    'a failed toggle drops the local decision as well as the state',
    () async {
      final api = _FakeFollowsApi()..followError = Exception('boom');
      final container = _containerWith(
        session: _FakeSessionIdentityService(initial: _session),
        followsApi: api,
      );
      addTearDown(container.dispose);
      await container.read(sessionProvider.future);
      await container.read(followsProvider.future);

      await expectLater(
        container.read(followsProvider.notifier).toggle('cat-1'),
        throwsA(isA<Exception>()),
      );

      expect(container.read(followsProvider).value, isEmpty);
      container.invalidate(followsProvider);
      expect(await container.read(followsProvider.future), isEmpty);
    },
  );

  test('a failure already superseded by a newer tap reverts nothing', () async {
    // Double-tapped heart: the follow is still in flight when the
    // unfollow is issued and confirmed, and only then does the follow
    // fail. The first tap is no longer anyone's intent, so it may not
    // restore its own idea of "before".
    final api = _FakeFollowsApi()..followGate = Completer<void>();
    final container = _containerWith(
      session: _FakeSessionIdentityService(initial: _session),
      followsApi: api,
    );
    addTearDown(container.dispose);
    await container.read(sessionProvider.future);
    await container.read(followsProvider.future);

    final notifier = container.read(followsProvider.notifier);
    final firstTap = notifier.toggle('cat-1');
    expect(container.read(followsProvider).value, {'cat-1'});

    // Second tap, on the state the first one optimistically produced.
    await notifier.toggle('cat-1');
    expect(container.read(followsProvider).value, isEmpty);
    expect(api.unfollowCalls, 1);

    api.followError = Exception('boom');
    api.followGate!.complete();
    await expectLater(firstTap, throwsA(isA<Exception>()));

    // Still unfollowed: the failed follow neither restored itself nor
    // deleted the unfollow's local decision on the way out.
    expect(container.read(followsProvider).value, isEmpty);
    api.fetchResult = const [_marker];
    container.invalidate(followsProvider);
    expect(await container.read(followsProvider.future), isEmpty);
  });
}
