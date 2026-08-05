/// Cross-screen accessibility regression checks (issue #109).
///
/// docs/design/app-states.md, "global rules" and "reduced motion": every
/// action target is at least 44 logical px, no state overflows at large
/// system text scale, and with reduced motion active a screen jumps
/// straight to its settled frame. Each feature slice already owns these
/// checks for its own states; this suite owns the sweep across every
/// routed screen's settled composition — the app shell, chrome, and
/// screen-level layouts that no single slice owns — so a new screen or a
/// regressed shared component cannot ship without them.
///
/// Environment (text scale, reduced motion) is injected through the test
/// platform dispatcher rather than a MediaQuery wrapper so it also reaches
/// [CatsOfIstanbulApp]'s own MaterialApp, which builds its MediaQuery from
/// the view.
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:app/core/identity/device_identity.dart';
import 'package:app/core/network/api_client.dart';
import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/router/app_shell.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/account/data/account_api.dart';
import 'package:app/features/account/ui/account_screen.dart';
import 'package:app/features/add_cat/data/add_cat_api.dart';
import 'package:app/features/add_cat/ui/add_cat_screen.dart';
import 'package:app/features/auth/data/auth_api.dart';
import 'package:app/features/auth/ui/login_screen.dart';
import 'package:app/features/badges/data/badge.dart';
import 'package:app/features/badges/data/badges_api.dart';
import 'package:app/features/badges/ui/badge_detail_screen.dart';
import 'package:app/features/badges/ui/badges_screen.dart';
import 'package:app/features/cat_detail/data/cat_detail.dart';
import 'package:app/features/cat_detail/ui/cat_detail_notifier.dart';
import 'package:app/features/cat_detail/ui/cat_detail_screen.dart';
import 'package:app/features/discover/data/discover_api.dart';
import 'package:app/features/discover/data/discover_cat.dart';
import 'package:app/features/discover/data/discover_location_service.dart';
import 'package:app/features/discover/ui/discover_screen.dart';
import 'package:app/features/follow/data/follows_api.dart';
import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/map/data/location_service.dart';
import 'package:app/features/map/ui/cats_map_notifier.dart';
import 'package:app/features/notifications/data/notification.dart';
import 'package:app/features/notifications/data/notifications_api.dart';
import 'package:app/features/notifications/ui/notifications_screen.dart';
import 'package:app/features/profile/data/profile.dart';
import 'package:app/features/profile/data/profile_api.dart';
import 'package:app/features/profile/ui/profile_screen.dart';
import 'package:app/main.dart';

const _session = SessionIdentity(
  accessToken: 'at',
  refreshToken: 'rt',
  userId: 'user-1',
);

class _FakeSessionIdentityService implements SessionIdentityService {
  _FakeSessionIdentityService([this._cached]);

  SessionIdentity? _cached;

  @override
  SessionIdentity? get cached => _cached;

  @override
  Future<SessionIdentity?> restore() async => _cached;

  @override
  Future<void> save(SessionIdentity identity) async => _cached = identity;

  @override
  Future<void> logout({String? deviceToken}) async => _cached = null;
}

class _FakeAuthApi implements AuthApi {
  @override
  Future<void> requestOtp(String phone) async {}

  @override
  Future<AuthSession> verifyOtp({
    required String phone,
    required String code,
  }) async => throw UnimplementedError();

  @override
  Future<void> setDisplayName(String displayName) async {}
}

class _FakeDeviceStorage implements DeviceKeyValueStorage {
  final _data = <String, String>{'device_id': 'did-1', 'device_token': 'tok-1'};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

class _FakeFollowsApi implements FollowsApi {
  _FakeFollowsApi([this.cats = const []]);

  final List<CatMarker> cats;

  @override
  Future<void> follow(String catId) async {}

  @override
  Future<void> unfollow(String catId) async {}

  @override
  Future<List<CatMarker>> fetchFollows() async => cats;
}

class _FixedDiscoverLocationService extends DiscoverLocationService {
  @override
  Future<DiscoverLocationOutcome> resolve() async =>
      const DiscoverLocationResolved(lat: 41.03, lng: 28.98);
}

class _FakeDiscoverApi extends DiscoverApi {
  _FakeDiscoverApi(this.nearby) : super(ApiClient());

  final List<DiscoverCat> nearby;

  @override
  Future<DiscoverPage> fetch({
    required DiscoverFilter filter,
    required double lat,
    required double lng,
    String? cursor,
  }) async => DiscoverPage(items: nearby, nextCursor: null);
}

class _FakeProfileApi implements ProfileApi {
  _FakeProfileApi(this.profile);

  final Profile profile;

  @override
  Future<Profile> fetch() async => profile;
}

class _FakeNotificationsApi implements NotificationsApi {
  _FakeNotificationsApi(this.page);

  final NotificationsPage page;

  @override
  Future<NotificationsPage> fetch({String? cursor}) async => page;

  @override
  Future<void> markRead(String id) async {}
}

class _FakeBadgesApi implements BadgesApi {
  _FakeBadgesApi(this.items);

  final List<BadgeStatus> items;

  @override
  Future<List<BadgeStatus>> fetch() async => items;
}

class _FakeAccountApi implements AccountApi {
  @override
  Future<AccountInfo> fetchMe() async => const AccountInfo(
    deviceId: 'did-1',
    userId: 'user-1',
    phoneVerified: true,
  );
}

class _FakeAddCatApi implements AddCatApi {
  @override
  Future<List<DuplicateCandidate>> fetchNearby({
    required double lat,
    required double lng,
  }) async => const [];

  @override
  Future<CatDetail> createCat({
    required double lat,
    required double lng,
    String? name,
    required bool confirmedNew,
    required Uint8List photoBytes,
    required String photoFilename,
    required String idempotencyKey,
    void Function(int sent, int total)? onSendProgress,
  }) async => throw UnimplementedError();
}

class _FakeLocationService implements LocationService {
  @override
  Future<ResolvedLocation> resolveInitialCenter() async =>
      const ResolvedLocation(center: istanbulFallback, isFallback: false);
}

/// Same fixed-state technique as widget_test.dart's _FixedCatsMapNotifier:
/// GoogleMap's callbacks never fire under `flutter test`, so the settled
/// state is driven directly.
class _FixedCatsMapNotifier extends CatsMapNotifier {
  _FixedCatsMapNotifier(this._state);

  final CatsMapState _state;

  @override
  CatsMapState build() => _state;
}

class _FixedCatDetailNotifier extends CatDetailNotifier {
  _FixedCatDetailNotifier(super.catId, this._state);

  final CatDetailState _state;

  @override
  CatDetailState build() => _state;

  @override
  Future<void> load() async {}
}

BadgeStatus _badge(String id, {bool earned = false}) => BadgeStatus(
  id: id,
  name: 'Rozet $id',
  icon: 'eye',
  condition: 'Koşul $id',
  descr: 'Açıklama $id',
  value: earned ? 5 : 2,
  target: 5,
  earned: earned,
  earnedAt: earned ? DateTime.utc(2026, 2, 1) : null,
);

final _catDetail = CatDetail(
  id: 'cat-1',
  name: 'tekir',
  lat: 41.0256,
  lng: 28.9744,
  areaLabel: 'Galata Kulesi çevresi, Beyoğlu',
  primaryPhoto: null,
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdateAt: DateTime.utc(2026, 1, 2),
);

/// One routed screen in its settled composition.
class _ScreenCase {
  const _ScreenCase(this.name, this.pump, {this.usesPlatformView = false});

  final String name;
  final Future<void> Function(WidgetTester tester) pump;

  /// Screens mounting a real GoogleMap platform view: its
  /// onMapCreated/onCameraIdle never fire under `flutter test`, so
  /// pumpAndSettle can hang — these settle with bounded pumps instead.
  final bool usesPlatformView;
}

final _stubRoutes = <GoRoute>[
  GoRoute(
    path: '/cats/:id',
    builder: (context, state) => const Scaffold(body: Text('cat detail')),
  ),
  GoRoute(
    path: '/login',
    builder: (context, state) => const Scaffold(body: Text('login')),
  ),
  GoRoute(
    path: '/badges',
    builder: (context, state) => const Scaffold(body: Text('badges')),
  ),
  GoRoute(
    path: '/badges/:id',
    builder: (context, state) => const Scaffold(body: Text('badge detail')),
  ),
  GoRoute(
    path: '/account',
    builder: (context, state) => const Scaffold(body: Text('account')),
  ),
  GoRoute(
    path: '/add-cat',
    builder: (context, state) => const Scaffold(body: Text('add cat')),
  ),
  GoRoute(
    path: '/notifications',
    builder: (context, state) => const Scaffold(body: Text('notifications')),
  ),
];

GoRouter _router(Widget home) => GoRouter(
  routes: [
    GoRoute(path: '/', builder: (context, state) => home),
    ..._stubRoutes,
  ],
);

/// Tab routes (`/discover`, `/profile`) settle inside the real [AppShell]
/// via a StatefulShellRoute mirroring appRouter's, so the bottom-nav chrome
/// is part of the checked composition. The map branch stays a stub: shell
/// branches mount lazily, so it never builds, and the shell-with-real-map
/// composition already has its own case pumping [CatsOfIstanbulApp].
GoRouter _shellRouter(String initialLocation) => GoRouter(
  initialLocation: initialLocation,
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          AppShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => const Scaffold(body: Text('map')),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/discover',
              builder: (context, state) => const DiscoverScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/profile',
              builder: (context, state) => const ProfileScreen(),
            ),
          ],
        ),
      ],
    ),
    ..._stubRoutes,
  ],
);

// The overrides parameter is untyped and re-cast on use: riverpod 3 no
// longer exports the Override type by name, and inference fills it back in
// from ProviderScope's own parameter type.
Future<void> _pumpApp(
  WidgetTester tester,
  GoRouter router,
  List<Object> overrides,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides.cast(),
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ),
  );
}

Future<void> _pumpRouted(
  WidgetTester tester,
  Widget home,
  List<Object> overrides,
) => _pumpApp(tester, _router(home), overrides);

Future<void> _pumpShellRouted(
  WidgetTester tester,
  String initialLocation,
  List<Object> overrides,
) => _pumpApp(tester, _shellRouter(initialLocation), overrides);

final _cases = <_ScreenCase>[
  _ScreenCase('app shell with the map empty-radius state', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialLocationProvider.overrideWith(
            (ref) async => const ResolvedLocation(
              center: istanbulFallback,
              isFallback: false,
            ),
          ),
          catsMapProvider.overrideWith(
            () => _FixedCatsMapNotifier(
              const CatsMapState(
                hasLoadedOnce: true,
                markers: [],
                searchRadiusMeters: 300,
              ),
            ),
          ),
        ],
        child: const CatsOfIstanbulApp(),
      ),
    );
  }, usesPlatformView: true),
  _ScreenCase('discover nearby list in the app shell', (tester) async {
    await _pumpShellRouted(tester, '/discover', [
      sessionIdentityServiceProvider.overrideWithValue(
        _FakeSessionIdentityService(),
      ),
      discoverLocationServiceProvider.overrideWithValue(
        _FixedDiscoverLocationService(),
      ),
      discoverApiProvider.overrideWithValue(
        _FakeDiscoverApi([
          const DiscoverCat(
            id: 'cat-1',
            name: 'Tekir',
            primaryPhoto: '',
            areaLabel: 'Galata',
            distanceMeters: 42,
          ),
          DiscoverCat(
            id: 'cat-2',
            name: 'Boncuk',
            primaryPhoto: '',
            areaLabel: 'Karaköy',
            distanceMeters: 120,
            activeAlert: ActiveAlert(
              createdAt: DateTime.utc(2026, 3, 1),
              expiresAt: DateTime.utc(2027, 3, 1),
            ),
          ),
        ]),
      ),
    ]);
  }),
  _ScreenCase('signed-in profile in the app shell', (tester) async {
    await _pumpShellRouted(tester, '/profile', [
      sessionIdentityServiceProvider.overrideWithValue(
        _FakeSessionIdentityService(_session),
      ),
      profileApiProvider.overrideWithValue(
        _FakeProfileApi(
          Profile(
            displayName: 'okan',
            totals: const ContributionTotals(
              updates: 3,
              helps: 1,
              catsAdded: 2,
              distinctCats: 2,
            ),
            badges: [_badge('b1', earned: true), _badge('b2')],
            recentContributions: [
              RecentContribution(
                type: 'update',
                catId: 'cat-1',
                catName: 'tekir',
                catPrimaryPhoto: null,
                statuses: const ['fed'],
                createdAt: DateTime.utc(2026, 3, 1),
              ),
            ],
          ),
        ),
      ),
    ]);
  }),
  _ScreenCase('notifications list', (tester) async {
    await _pumpRouted(tester, const NotificationsScreen(), [
      notificationsApiProvider.overrideWithValue(
        _FakeNotificationsApi(
          NotificationsPage(
            items: [
              AppNotification(
                id: 'n1',
                catId: 'cat-1',
                updateId: 'u1',
                read: false,
                createdAt: DateTime.utc(2026, 3, 1),
              ),
              AppNotification(
                id: 'n2',
                catId: 'cat-2',
                updateId: 'u2',
                read: true,
                createdAt: DateTime.utc(2026, 2, 1),
              ),
            ],
            nextCursor: null,
          ),
        ),
      ),
      followsApiProvider.overrideWithValue(
        _FakeFollowsApi(const [
          CatMarker(
            id: 'cat-1',
            name: 'Tekir',
            primaryPhoto: '',
            lat: 41.0,
            lng: 29.0,
          ),
        ]),
      ),
    ]);
  }),
  _ScreenCase('add cat location step', (tester) async {
    await _pumpRouted(tester, const AddCatScreen(), [
      addCatApiProvider.overrideWithValue(_FakeAddCatApi()),
      locationServiceProvider.overrideWith((ref) => _FakeLocationService()),
    ]);
  }, usesPlatformView: true),
  _ScreenCase('login phone step', (tester) async {
    await _pumpRouted(tester, const LoginScreen(contextText: null), [
      authApiProvider.overrideWithValue(_FakeAuthApi()),
      sessionIdentityServiceProvider.overrideWithValue(
        _FakeSessionIdentityService(),
      ),
      deviceIdentityServiceProvider.overrideWithValue(
        DeviceIdentityService(
          storage: _FakeDeviceStorage(),
          dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080')),
        ),
      ),
    ]);
  }),
  _ScreenCase('cat detail loaded', (tester) async {
    await _pumpRouted(tester, const CatDetailScreen(catId: 'cat-1'), [
      catDetailProvider('cat-1').overrideWith(
        () => _FixedCatDetailNotifier(
          'cat-1',
          CatDetailState(detail: _catDetail, hasLoadedOnce: true),
        ),
      ),
      sessionIdentityServiceProvider.overrideWithValue(
        _FakeSessionIdentityService(),
      ),
    ]);
  }),
  _ScreenCase('badges overview', (tester) async {
    await _pumpRouted(tester, const BadgesScreen(), [
      badgesApiProvider.overrideWithValue(
        _FakeBadgesApi([_badge('b1', earned: true), _badge('b2')]),
      ),
    ]);
  }),
  _ScreenCase('badge detail', (tester) async {
    await _pumpRouted(tester, const BadgeDetailScreen(badgeId: 'b1'), [
      badgesApiProvider.overrideWithValue(_FakeBadgesApi([_badge('b1')])),
    ]);
  }),
  _ScreenCase('account signed in', (tester) async {
    await _pumpRouted(tester, const AccountScreen(), [
      accountApiProvider.overrideWithValue(_FakeAccountApi()),
      authApiProvider.overrideWithValue(_FakeAuthApi()),
      sessionIdentityServiceProvider.overrideWithValue(
        _FakeSessionIdentityService(_session),
      ),
    ]);
  }),
];

/// iPhone-class viewport — the contract's "no overflow at large text
/// scale" is a phone guarantee; the default 800x600 test surface is wider
/// than any supported phone and would hide real overflows.
void _usePhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester, _ScreenCase screenCase) async {
  if (screenCase.usesPlatformView) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  } else {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
  }
}

void main() {
  for (final screenCase in _cases) {
    group(screenCase.name, () {
      testWidgets('every tap target is at least 44 logical px', (tester) async {
        _usePhoneViewport(tester);
        final handle = tester.ensureSemantics();
        addTearDown(handle.dispose);
        await screenCase.pump(tester);
        await _settle(tester, screenCase);

        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      });

      testWidgets('does not overflow at 2.0 text scale', (tester) async {
        _usePhoneViewport(tester);
        tester.platformDispatcher.textScaleFactorTestValue = 2.0;
        addTearDown(tester.platformDispatcher.clearAllTestValues);
        await screenCase.pump(tester);
        await _settle(tester, screenCase);

        expect(tester.takeException(), isNull);
      });

      testWidgets('settles immediately with reduced motion', (tester) async {
        _usePhoneViewport(tester);
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(
              disableAnimations: true,
              accessibleNavigation: true,
            );
        addTearDown(tester.platformDispatcher.clearAllTestValues);
        await screenCase.pump(tester);
        await _settle(tester, screenCase);

        expect(tester.takeException(), isNull);
        // The injected accessibility features must actually reach the app's
        // own MediaQuery — otherwise this test settles a normal-motion tree
        // and proves nothing.
        expect(
          MediaQuery.disableAnimationsOf(
            tester.element(find.byType(Scaffold).first),
          ),
          isTrue,
        );
      });
    });
  }
}
