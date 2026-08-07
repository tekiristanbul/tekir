import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/features/badges/data/badge.dart';
import 'package:app/features/badges/data/badges_api.dart';
import 'package:app/features/badges/ui/badges_notifier.dart';
import 'package:app/features/discover/ui/discover_notifier.dart';
import 'package:app/features/follow/data/follows_api.dart';
import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/notifications/data/notification.dart';
import 'package:app/features/notifications/data/notifications_api.dart';
import 'package:app/features/notifications/ui/notifications_notifier.dart';
import 'package:app/features/profile/data/profile.dart';
import 'package:app/features/profile/data/profile_api.dart';
import 'package:app/features/profile/ui/profile_notifier.dart';

// Mirrors follows_notifier_test.dart's fake exactly.
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

const _sessionA = SessionIdentity(
  accessToken: 'at-a',
  refreshToken: 'rt-a',
  userId: 'user-a',
);
const _sessionB = SessionIdentity(
  accessToken: 'at-b',
  refreshToken: 'rt-b',
  userId: 'user-b',
);

Profile _profile(String name) => Profile(
  displayName: name,
  totals: const ContributionTotals(
    updates: 1,
    helps: 0,
    catsAdded: 0,
    distinctCats: 1,
  ),
  badges: const [],
  recentContributions: const [],
);

class _FakeProfileApi implements ProfileApi {
  _FakeProfileApi(this.profile);
  Profile profile;
  Completer<void>? pending;

  @override
  Future<Profile> fetch() async {
    if (pending != null) await pending!.future;
    return profile;
  }
}

class _FakeBadgesApi implements BadgesApi {
  _FakeBadgesApi(this.items);
  List<BadgeStatus> items;

  @override
  Future<List<BadgeStatus>> fetch() async => items;
}

class _FakeNotificationsApi implements NotificationsApi {
  _FakeNotificationsApi(this.items);
  List<AppNotification> items;

  @override
  Future<NotificationsPage> fetch({String? cursor}) async =>
      NotificationsPage(items: items, nextCursor: null);

  @override
  Future<void> markRead(String id) async {}
}

class _FakeFollowsApi implements FollowsApi {
  _FakeFollowsApi(this.cats);
  List<CatMarker> cats;

  @override
  Future<void> follow(String catId) async {}

  @override
  Future<void> unfollow(String catId) async {}

  @override
  Future<List<CatMarker>> fetchFollows() async => cats;
}

void main() {
  group('ProfileNotifier session-scoped reset', () {
    test('logging out resets profile state to initial', () async {
      final session = _FakeSessionIdentityService(initial: _sessionA);
      final container = ProviderContainer(
        overrides: [
          sessionIdentityServiceProvider.overrideWithValue(session),
          profileApiProvider.overrideWithValue(_FakeProfileApi(_profile('A'))),
        ],
      );
      addTearDown(container.dispose);
      await container.read(sessionProvider.future);

      await container.read(profileProvider.notifier).load();
      expect(container.read(profileProvider).profile?.displayName, 'A');

      await container.read(sessionProvider.notifier).logout();

      expect(container.read(profileProvider).profile, isNull);
      expect(container.read(profileProvider).hasLoadedOnce, isFalse);
    });

    test(
      'logging into a different account resets profile state to initial',
      () async {
        final session = _FakeSessionIdentityService(initial: _sessionA);
        final container = ProviderContainer(
          overrides: [
            sessionIdentityServiceProvider.overrideWithValue(session),
            profileApiProvider.overrideWithValue(
              _FakeProfileApi(_profile('A')),
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(sessionProvider.future);

        await container.read(profileProvider.notifier).load();
        expect(container.read(profileProvider).profile?.displayName, 'A');

        await container.read(sessionProvider.notifier).save(_sessionB);

        expect(container.read(profileProvider).profile, isNull);
        expect(container.read(profileProvider).hasLoadedOnce, isFalse);
      },
    );

    test('a slow load() for account A discards its result if account B is '
        'current by the time it resolves', () async {
      final api = _FakeProfileApi(_profile('A'))..pending = Completer<void>();
      final session = _FakeSessionIdentityService(initial: _sessionA);
      final container = ProviderContainer(
        overrides: [
          sessionIdentityServiceProvider.overrideWithValue(session),
          profileApiProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);
      await container.read(sessionProvider.future);

      final loadFuture = container.read(profileProvider.notifier).load();

      // account switches to B while A's fetch is still in flight.
      await container.read(sessionProvider.notifier).logout();
      await container.read(sessionProvider.notifier).save(_sessionB);
      api.pending!.complete();
      await loadFuture;

      expect(container.read(profileProvider).profile, isNull);
      expect(container.read(profileProvider).isLoading, isFalse);
    });
  });

  group('BadgesNotifier session-scoped reset', () {
    test('logging out resets badges state to initial', () async {
      final session = _FakeSessionIdentityService(initial: _sessionA);
      final container = ProviderContainer(
        overrides: [
          sessionIdentityServiceProvider.overrideWithValue(session),
          badgesApiProvider.overrideWithValue(
            _FakeBadgesApi([
              BadgeStatus(
                id: 'first_sighting',
                name: 'İlk',
                icon: 'eye',
                condition: 'c',
                descr: 'd',
                value: 1,
                target: 1,
                earned: true,
                earnedAt: DateTime.utc(2026, 1, 1),
              ),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(sessionProvider.future);

      await container.read(badgesProvider.notifier).load();
      expect(container.read(badgesProvider).items, isNotEmpty);

      await container.read(sessionProvider.notifier).logout();

      expect(container.read(badgesProvider).items, isEmpty);
      expect(container.read(badgesProvider).hasLoadedOnce, isFalse);
    });
  });

  group('NotificationsNotifier session-scoped reset', () {
    test('logging out resets notifications state to initial', () async {
      final session = _FakeSessionIdentityService(initial: _sessionA);
      final container = ProviderContainer(
        overrides: [
          sessionIdentityServiceProvider.overrideWithValue(session),
          notificationsApiProvider.overrideWithValue(
            _FakeNotificationsApi([
              AppNotification(
                id: 'n1',
                catId: 'cat-1',
                updateId: 'u1',
                read: false,
                createdAt: DateTime.utc(2026, 1, 1),
              ),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(sessionProvider.future);

      await container.read(notificationsProvider.notifier).load();
      expect(container.read(notificationsProvider).items, isNotEmpty);

      await container.read(sessionProvider.notifier).logout();

      expect(container.read(notificationsProvider).items, isEmpty);
      expect(container.read(notificationsProvider).hasLoadedOnce, isFalse);
    });
  });

  group('DiscoverNotifier session-scoped reset', () {
    test('logging out resets discover state to initial', () async {
      final session = _FakeSessionIdentityService(initial: _sessionA);
      const marker = CatMarker(
        id: 'cat-1',
        name: 'tekir',
        primaryPhoto: '',
        lat: 41.0,
        lng: 29.0,
      );
      final container = ProviderContainer(
        overrides: [
          sessionIdentityServiceProvider.overrideWithValue(session),
          followsApiProvider.overrideWithValue(_FakeFollowsApi([marker])),
        ],
      );
      addTearDown(container.dispose);
      await container.read(sessionProvider.future);

      await container.read(discoverProvider.notifier).loadFollowing();
      expect(container.read(discoverProvider).following.cats, isNotEmpty);

      await container.read(sessionProvider.notifier).logout();

      expect(container.read(discoverProvider).following.cats, isEmpty);
      expect(container.read(discoverProvider).following.hasLoadedOnce, isFalse);
    });

    test(
      'signing into a different account resets discover state to initial',
      () async {
        final session = _FakeSessionIdentityService(initial: _sessionA);
        const marker = CatMarker(
          id: 'cat-1',
          name: 'tekir',
          primaryPhoto: '',
          lat: 41.0,
          lng: 29.0,
        );
        final container = ProviderContainer(
          overrides: [
            sessionIdentityServiceProvider.overrideWithValue(session),
            followsApiProvider.overrideWithValue(_FakeFollowsApi([marker])),
          ],
        );
        addTearDown(container.dispose);
        await container.read(sessionProvider.future);

        await container.read(discoverProvider.notifier).loadFollowing();
        expect(container.read(discoverProvider).following.cats, isNotEmpty);

        await container.read(sessionProvider.notifier).save(_sessionB);

        expect(container.read(discoverProvider).following.cats, isEmpty);
        expect(
          container.read(discoverProvider).following.hasLoadedOnce,
          isFalse,
        );
      },
    );
  });
}
