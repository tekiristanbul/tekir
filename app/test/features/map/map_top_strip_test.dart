import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/map/data/location_service.dart';
import 'package:app/features/map/ui/cats_map_notifier.dart';
import 'package:app/features/map/ui/map_screen.dart';
import 'package:app/features/notifications/data/notification.dart';
import 'package:app/features/notifications/data/notifications_api.dart';
import 'package:app/features/profile/data/profile.dart';
import 'package:app/features/profile/data/profile_api.dart';
import 'package:app/core/network/api_client.dart';

/// The map's top strip (issue #284): the search pill's live count, the
/// bell's unread badge, the account avatar's initials, and the help strip's
/// count — the four pieces of the chrome that state a number rather than
/// just sitting there.

final _alert = ActiveAlert(
  createdAt: DateTime.utc(2026, 3, 1),
  expiresAt: DateTime.utc(2027, 3, 1),
);

CatMarker _cat(String id, {bool needsHelp = false}) => CatMarker(
  id: id,
  name: id,
  primaryPhoto: '',
  lat: 41.02,
  lng: 28.97,
  activeAlert: needsHelp ? _alert : null,
);

class _FixedCatsMapNotifier extends CatsMapNotifier {
  _FixedCatsMapNotifier(this._state);

  final CatsMapState _state;

  @override
  CatsMapState build() => _state;
}

class _FakeSessionIdentityService implements SessionIdentityService {
  _FakeSessionIdentityService([this.cached]);

  @override
  final SessionIdentity? cached;

  @override
  Future<SessionIdentity?> restore() async => cached;

  @override
  Future<SessionIdentity?> refreshIfExpired() async => cached;

  @override
  Future<void> save(SessionIdentity identity) async {}

  @override
  Future<void> logout({String? deviceToken}) async {}
}

class _FakeNotificationsApi implements NotificationsApi {
  _FakeNotificationsApi(this.items);

  final List<AppNotification> items;

  @override
  Future<NotificationsPage> fetch({String? cursor}) async =>
      NotificationsPage(items: items, nextCursor: null);

  @override
  Future<void> markRead(String id) async {}
}

class _FakeProfileApi extends ProfileApi {
  _FakeProfileApi(this.profile) : super(ApiClient());

  final Profile profile;

  @override
  Future<Profile> fetch() async => profile;
}

AppNotification _notification(String id, {required bool read}) =>
    AppNotification(
      id: id,
      catId: 'cat-$id',
      updateId: 'update-$id',
      read: read,
      createdAt: DateTime.utc(2026, 3, 1),
    );

Profile _profile(String? displayName) => Profile(
  displayName: displayName,
  totals: const ContributionTotals(
    updates: 0,
    helps: 0,
    catsAdded: 0,
    distinctCats: 0,
  ),
  badges: const [],
  recentContributions: const [],
);

const _session = SessionIdentity(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
);

Future<void> _pumpMap(
  WidgetTester tester, {
  CatsMapState state = const CatsMapState(),
  SessionIdentity? session,
  List<AppNotification> notifications = const [],
  Profile? profile,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        initialLocationProvider.overrideWith(
          (ref) async => const ResolvedLocation(
            center: istanbulFallback,
            isFallback: false,
          ),
        ),
        catsMapProvider.overrideWith(() => _FixedCatsMapNotifier(state)),
        sessionIdentityServiceProvider.overrideWithValue(
          _FakeSessionIdentityService(session),
        ),
        notificationsApiProvider.overrideWithValue(
          _FakeNotificationsApi(notifications),
        ),
        if (profile != null)
          profileApiProvider.overrideWithValue(_FakeProfileApi(profile)),
      ],
      child: const MaterialApp(home: MapScreen()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  group('search pill', () {
    testWidgets('states how many cats are in view once the map has read', (
      tester,
    ) async {
      await _pumpMap(
        tester,
        state: CatsMapState(
          markers: [_cat('a'), _cat('b'), _cat('c')],
          hasLoadedOnce: true,
        ),
      );

      expect(find.text('kedi ara · yakında 3'), findsOneWidget);
    });

    testWidgets('claims no count before the first read lands', (tester) async {
      await _pumpMap(tester);

      // Not "yakında 0": an unread map has not found zero cats, it has not
      // looked yet.
      expect(find.text('kedi ara'), findsOneWidget);
      expect(find.textContaining('yakında'), findsNothing);
    });
  });

  group('help strip', () {
    testWidgets('counts only the cats in view that need help', (tester) async {
      await _pumpMap(
        tester,
        state: CatsMapState(
          markers: [_cat('a'), _cat('b', needsHelp: true), _cat('c')],
          hasLoadedOnce: true,
        ),
      );

      expect(find.text('1 kedi yardım bekliyor'), findsOneWidget);
    });

    testWidgets('is absent when nothing in view needs help', (tester) async {
      await _pumpMap(
        tester,
        state: CatsMapState(markers: [_cat('a')], hasLoadedOnce: true),
      );

      expect(find.textContaining('yardım bekliyor'), findsNothing);
    });
  });

  group('notification bell', () {
    testWidgets('shows no badge for a guest, and reads no inbox', (
      tester,
    ) async {
      await _pumpMap(tester, notifications: [_notification('1', read: false)]);

      expect(find.text('1'), findsNothing);
    });

    testWidgets('counts the unread notifications for a signed-in account', (
      tester,
    ) async {
      await _pumpMap(
        tester,
        session: _session,
        notifications: [
          _notification('1', read: false),
          _notification('2', read: false),
          _notification('3', read: true),
        ],
      );

      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('caps the badge rather than showing a two-digit count', (
      tester,
    ) async {
      await _pumpMap(
        tester,
        session: _session,
        notifications: [
          for (var i = 0; i < 12; i++) _notification('$i', read: false),
        ],
      );

      expect(find.text('9+'), findsOneWidget);
    });
  });

  group('account avatar', () {
    testWidgets('shows the account initials once the profile loads', (
      tester,
    ) async {
      await _pumpMap(
        tester,
        session: _session,
        profile: _profile('Ayşe Yılmaz'),
      );

      expect(find.text('AY'), findsOneWidget);
    });

    testWidgets('shows a glyph rather than guessing for a guest', (
      tester,
    ) async {
      await _pumpMap(tester);

      expect(find.byIcon(Icons.person_outline), findsOneWidget);
    });
  });

  group('accountInitials', () {
    test('takes the first and last word, at most two letters', () {
      expect(accountInitials('Ayşe Yılmaz'), 'AY');
      expect(accountInitials('Ayşe Nur Yılmaz'), 'AY');
    });

    test('takes one letter from a single-word name', () {
      expect(accountInitials('okan'), 'O');
    });

    test('upper-cases in turkish, where i becomes İ', () {
      expect(accountInitials('irem'), 'İ');
    });

    test('never invents initials for an absent or blank name', () {
      expect(accountInitials(null), isNull);
      expect(accountInitials('   '), isNull);
    });
  });
}
