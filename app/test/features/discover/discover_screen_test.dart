import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/network/api_client.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/discover/data/discover_api.dart';
import 'package:app/features/discover/data/discover_cat.dart';
import 'package:app/features/discover/data/discover_location_service.dart';
import 'package:app/features/discover/ui/discover_screen.dart';
import 'package:app/features/discover/ui/discover_skeleton.dart';
import 'package:app/features/follow/data/follows_api.dart';
import 'package:app/features/map/data/cat_marker.dart';

const _session = SessionIdentity(
  accessToken: 'at',
  refreshToken: 'rt',
  userId: 'user-1',
);

class _FakeSessionIdentityService implements SessionIdentityService {
  _FakeSessionIdentityService({this._cached});

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
  _FakeFollowsApi({this.nextCats = const [], this.nextError});

  List<CatMarker> nextCats;
  Object? nextError;
  int calls = 0;
  Completer<void>? pending;

  @override
  Future<void> follow(String catId) async {}

  @override
  Future<void> unfollow(String catId) async {}

  @override
  Future<List<CatMarker>> fetchFollows() async {
    calls++;
    if (pending != null) await pending!.future;
    if (nextError != null) throw nextError!;
    return nextCats;
  }
}

/// A fixed, already-resolved location — every screen test that doesn't
/// specifically exercise the location-trouble states uses this, so the
/// default "Yakınımda" tab never touches the real Geolocator platform
/// channel (which hangs `pumpAndSettle` indefinitely — there is no
/// registered handler for it in the widget-test binding).
class _FixedDiscoverLocationService extends DiscoverLocationService {
  _FixedDiscoverLocationService([
    this.outcome = const DiscoverLocationResolved(lat: 41.03, lng: 28.98),
  ]);

  DiscoverLocationOutcome outcome;
  int calls = 0;
  int recoverCalls = 0;

  @override
  Future<DiscoverLocationOutcome> resolve() async {
    calls++;
    return outcome;
  }

  @override
  Future<void> recoverPermission() async => recoverCalls++;
}

class _FakeDiscoverApi extends DiscoverApi {
  _FakeDiscoverApi() : super(ApiClient());

  DiscoverPage Function(DiscoverFilter filter, String? cursor)? onFetch;
  List<DiscoverCat> nextNearby = const [];
  List<DiscoverCat> nextNeedsHelp = const [];
  String? nextCursor;
  Object? nextError;
  int calls = 0;

  @override
  Future<DiscoverPage> fetch({
    required DiscoverFilter filter,
    required double lat,
    required double lng,
    String? cursor,
  }) async {
    calls++;
    if (nextError != null) throw nextError!;
    if (onFetch != null) return onFetch!(filter, cursor);
    final items = filter == DiscoverFilter.nearby ? nextNearby : nextNeedsHelp;
    return DiscoverPage(items: items, nextCursor: nextCursor);
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required SessionIdentity? session,
  _FakeFollowsApi? followsApi,
  _FixedDiscoverLocationService? locationService,
  _FakeDiscoverApi? discoverApi,
  double textScale = 1.0,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => const DiscoverScreen()),
      GoRoute(
        path: '/login',
        builder: (context, state) => const Scaffold(body: Text('login screen')),
      ),
      GoRoute(
        path: '/cats/:id',
        builder: (context, state) =>
            Scaffold(body: Text('cat detail ${state.pathParameters['id']}')),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionIdentityServiceProvider.overrideWithValue(
          _FakeSessionIdentityService(cached: session),
        ),
        discoverLocationServiceProvider.overrideWithValue(
          locationService ?? _FixedDiscoverLocationService(),
        ),
        discoverApiProvider.overrideWithValue(
          discoverApi ?? _FakeDiscoverApi(),
        ),
        if (followsApi != null)
          followsApiProvider.overrideWithValue(followsApi),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light,
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _selectFollowingTab(WidgetTester tester) async {
  await tester.tap(find.text('Takip ettiklerim'));
  await tester.pumpAndSettle();
}

Future<void> _selectNeedsHelpTab(WidgetTester tester) async {
  await tester.tap(find.text('Yardım gerekiyor'));
  await tester.pumpAndSettle();
}

void main() {
  group('nearby tab (default)', () {
    testWidgets(
      'initial read shows nothing before 400 ms, then the list skeleton',
      (tester) async {
        final completer = Completer<DiscoverPage>();
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => const DiscoverScreen(),
            ),
          ],
        );
        final blockingApi = _BlockingDiscoverApi(completer);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sessionIdentityServiceProvider.overrideWithValue(
                _FakeSessionIdentityService(),
              ),
              discoverLocationServiceProvider.overrideWithValue(
                _FixedDiscoverLocationService(),
              ),
              discoverApiProvider.overrideWithValue(blockingApi),
            ],
            child: MaterialApp.router(
              theme: AppTheme.light,
              routerConfig: router,
            ),
          ),
        );
        await tester.pump();

        // 0–400 ms: nothing loading-related — no skeleton, and never a
        // bare spinner screen.
        expect(find.byType(DiscoverListSkeleton), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);

        await tester.pump(const Duration(milliseconds: 399));
        expect(find.byType(DiscoverListSkeleton), findsNothing);

        await tester.pump(const Duration(milliseconds: 1));
        expect(find.byType(DiscoverListSkeleton), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);

        completer.complete(const DiscoverPage(items: []));
        await tester.pump();
        await tester.pump();
        expect(find.byType(DiscoverListSkeleton), findsNothing);
        expect(find.text('Yakında kedi bulunamadı'), findsOneWidget);
      },
    );

    testWidgets('a read finishing within 400 ms never shows the skeleton', (
      tester,
    ) async {
      await _pump(tester, session: null, discoverApi: _FakeDiscoverApi());

      expect(find.byType(DiscoverListSkeleton), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('lists nearby cats with distance and navigates to detail', (
      tester,
    ) async {
      final api = _FakeDiscoverApi()
        ..nextNearby = const [
          DiscoverCat(
            id: 'cat-1',
            name: 'Tekir',
            primaryPhoto: '',
            areaLabel: 'Galata',
            distanceMeters: 42,
          ),
        ];
      await _pump(tester, session: null, discoverApi: api);

      expect(find.text('Tekir'), findsOneWidget);
      expect(find.text('40 m'), findsOneWidget);

      await tester.tap(find.text('Tekir'));
      await tester.pumpAndSettle();

      expect(find.text('cat detail cat-1'), findsOneWidget);
    });

    testWidgets(
      'shows the needs-help badge instead of distance-only rows when active',
      (tester) async {
        final api = _FakeDiscoverApi()
          ..nextNearby = [
            DiscoverCat(
              id: 'cat-1',
              name: 'Boncuk',
              primaryPhoto: '',
              distanceMeters: 900,
              activeAlert: ActiveAlert(
                createdAt: DateTime.now(),
                expiresAt: DateTime.now().add(const Duration(hours: 1)),
              ),
            ),
          ];
        await _pump(tester, session: null, discoverApi: api);

        expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
        expect(find.text('900 m'), findsOneWidget);
      },
    );

    testWidgets('empty result shows the empty state', (tester) async {
      await _pump(tester, session: null, discoverApi: _FakeDiscoverApi());

      expect(find.text('Yakında kedi bulunamadı'), findsOneWidget);
    });

    testWidgets('a fetch error shows retry, and retry re-fetches', (
      tester,
    ) async {
      final api = _FakeDiscoverApi()
        ..nextError = const DiscoverServerException();
      await _pump(tester, session: null, discoverApi: api);

      expect(
        find.text('Bağlantı sorunu oldu. Tekrar dener misin?'),
        findsOneWidget,
      );

      api.nextError = null;
      api.nextNearby = const [
        DiscoverCat(id: 'cat-1', primaryPhoto: '', distanceMeters: 10),
      ];
      await tester.tap(find.text('Tekrar dene'));
      await tester.pumpAndSettle();

      expect(find.text('İsimsiz kedi'), findsOneWidget);
      expect(api.calls, 2);
    });

    // Apple review 0.4.2 (guideline 2.1(a)) screenshotted the retry-labelled
    // error card these tests used to assert. No location outcome renders as
    // an error any more: the list loads against the istanbul center and
    // gives up only the distance column.
    testWidgets('an unresolved location lists cats without distances', (
      tester,
    ) async {
      final api = _FakeDiscoverApi()
        ..nextNearby = const [
          DiscoverCat(
            id: 'a',
            name: 'Tekir',
            primaryPhoto: '',
            distanceMeters: 320,
          ),
        ];
      await _pump(
        tester,
        session: null,
        discoverApi: api,
        locationService: _FixedDiscoverLocationService(
          const DiscoverLocationPermissionDenied(),
        ),
      );

      expect(api.calls, 1);
      expect(find.text('Tekir'), findsOneWidget);
      expect(
        find.text('konum yok — istanbul merkezi gösteriliyor'),
        findsOneWidget,
      );
      expect(find.text('konum iznini aç'), findsOneWidget);
      expect(find.text('320 m'), findsNothing);
      expect(find.text('Tekrar dene'), findsNothing);
    });

    testWidgets('a position outside istanbul falls back the same way', (
      tester,
    ) async {
      // A reviewer granting the permission from california is the other
      // half of the 0.4.2 rejection: cupertino coordinates earned a
      // `400 invalid area` that reached the screen as a retry error.
      final api = _FakeDiscoverApi()
        ..nextNearby = const [
          DiscoverCat(
            id: 'a',
            name: 'Tekir',
            primaryPhoto: '',
            distanceMeters: 320,
          ),
        ];
      await _pump(
        tester,
        session: null,
        discoverApi: api,
        locationService: _FixedDiscoverLocationService(
          const DiscoverLocationOutOfArea(),
        ),
      );

      expect(find.text('Tekir'), findsOneWidget);
      expect(
        find.text('konum yok — istanbul merkezi gösteriliyor'),
        findsOneWidget,
      );
    });

    testWidgets(
      'a real in-area position keeps the distances and the note off',
      (tester) async {
        final api = _FakeDiscoverApi()
          ..nextNearby = const [
            DiscoverCat(
              id: 'a',
              name: 'Tekir',
              primaryPhoto: '',
              distanceMeters: 320,
            ),
          ];
        await _pump(tester, session: null, discoverApi: api);

        expect(find.text('320 m'), findsOneWidget);
        expect(
          find.text('konum yok — istanbul merkezi gösteriliyor'),
          findsNothing,
        );
      },
    );

    testWidgets('the note cta recovers the permission and re-resolves', (
      tester,
    ) async {
      // A plain re-resolve can't recover a denial iOS has stopped
      // re-prompting for (issue #262) — the cta has to go through
      // recoverPermission, which reaches the settings page instead.
      final api = _FakeDiscoverApi()
        ..nextNearby = const [
          DiscoverCat(
            id: 'a',
            name: 'Tekir',
            primaryPhoto: '',
            distanceMeters: 320,
          ),
        ];
      final location = _FixedDiscoverLocationService(
        const DiscoverLocationPermissionDenied(),
      );
      await _pump(
        tester,
        session: null,
        discoverApi: api,
        locationService: location,
      );
      expect(location.calls, 1);

      location.outcome = const DiscoverLocationResolved(lat: 41.03, lng: 28.98);
      await tester.tap(find.text('konum iznini aç'));
      await tester.pumpAndSettle();

      expect(location.recoverCalls, 1);
      expect(location.calls, 2);
      expect(
        find.text('konum yok — istanbul merkezi gösteriliyor'),
        findsNothing,
      );
      expect(find.text('320 m'), findsOneWidget);
    });

    testWidgets('an empty fallback list still explains the anchor', (
      tester,
    ) async {
      await _pump(
        tester,
        session: null,
        locationService: _FixedDiscoverLocationService(
          const DiscoverLocationServiceDisabled(),
        ),
      );

      expect(find.text('Yakında kedi bulunamadı'), findsOneWidget);
      expect(
        find.text('konum yok — istanbul merkezi gösteriliyor'),
        findsOneWidget,
      );
    });

    testWidgets(
      'scrolling to the bottom loads the next page without duplicates',
      (tester) async {
        final firstPage = List.generate(
          20,
          (i) => DiscoverCat(
            id: 'cat-$i',
            name: 'cat-$i',
            primaryPhoto: '',
            distanceMeters: (i + 1) * 10,
          ),
        );
        final secondPage = [
          DiscoverCat(
            id: 'cat-last',
            name: 'cat-last',
            primaryPhoto: '',
            distanceMeters: 999,
          ),
        ];
        final api = _FakeDiscoverApi();
        var page = 0;
        api.onFetch = (filter, cursor) {
          page++;
          if (page == 1) {
            return DiscoverPage(items: firstPage, nextCursor: 'cursor-1');
          }
          return DiscoverPage(items: secondPage);
        };
        await _pump(tester, session: null, discoverApi: api);

        expect(find.text('cat-last'), findsNothing);

        await tester.drag(find.byType(ListView), const Offset(0, -6000));
        await tester.pumpAndSettle();

        expect(find.text('cat-last'), findsOneWidget);
        expect(api.calls, 2);
      },
    );
  });

  group('needs-help tab', () {
    testWidgets('lists only active needs-help cats', (tester) async {
      final api = _FakeDiscoverApi()
        ..nextNeedsHelp = [
          DiscoverCat(
            id: 'cat-1',
            name: 'Pamuk',
            primaryPhoto: '',
            distanceMeters: 15,
            activeAlert: ActiveAlert(
              createdAt: DateTime.now(),
              expiresAt: DateTime.now().add(const Duration(hours: 2)),
            ),
          ),
        ];
      await _pump(tester, session: null, discoverApi: api);
      await _selectNeedsHelpTab(tester);

      expect(find.text('Pamuk'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets('empty result shows the needs-help empty state', (
      tester,
    ) async {
      await _pump(tester, session: null, discoverApi: _FakeDiscoverApi());
      await _selectNeedsHelpTab(tester);

      expect(find.text('Şu an yardım bekleyen kedi yok'), findsOneWidget);
    });
  });

  group('following tab', () {
    testWidgets('a guest sees the login cta and never fetches follows', (
      tester,
    ) async {
      final api = _FakeFollowsApi();
      await _pump(tester, session: null, followsApi: api);
      await _selectFollowingTab(tester);

      expect(find.text('Giriş yapmadın'), findsOneWidget);
      expect(find.text('Giriş yap'), findsOneWidget);
      expect(api.calls, 0);
    });

    testWidgets(
      'a session that resolves after this screen has already mounted still loads the follows list',
      (tester) async {
        final api = _FakeFollowsApi(
          nextCats: const [
            CatMarker(
              id: 'cat-1',
              name: 'Tekir',
              primaryPhoto: '',
              lat: 41.0,
              lng: 29.0,
            ),
          ],
        );
        final sessionService = _FakeSessionIdentityService();
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => const DiscoverScreen(),
            ),
          ],
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sessionIdentityServiceProvider.overrideWithValue(sessionService),
              followsApiProvider.overrideWithValue(api),
              discoverLocationServiceProvider.overrideWithValue(
                _FixedDiscoverLocationService(),
              ),
              discoverApiProvider.overrideWithValue(_FakeDiscoverApi()),
            ],
            child: MaterialApp.router(
              theme: AppTheme.light,
              routerConfig: router,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _selectFollowingTab(tester);
        expect(find.text('Giriş yapmadın'), findsOneWidget);
        expect(api.calls, 0);

        final container = ProviderScope.containerOf(
          tester.element(find.byType(DiscoverScreen)),
        );
        await container.read(sessionProvider.notifier).save(_session);
        await tester.pumpAndSettle();

        expect(find.text('Tekir'), findsOneWidget);
        expect(api.calls, 1);
      },
    );

    testWidgets(
      'the initial follows read gates its skeleton behind 400 ms too',
      (tester) async {
        final api = _FakeFollowsApi(
          nextCats: const [
            CatMarker(
              id: 'cat-1',
              name: 'Tekir',
              primaryPhoto: '',
              lat: 41.0,
              lng: 29.0,
            ),
          ],
        )..pending = Completer<void>();
        await _pump(tester, session: _session, followsApi: api);

        await tester.tap(find.text('Takip ettiklerim'));
        await tester.pump();
        expect(find.byType(DiscoverListSkeleton), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);

        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(DiscoverListSkeleton), findsOneWidget);

        api.pending!.complete();
        await tester.pump();
        await tester.pump();
        expect(find.byType(DiscoverListSkeleton), findsNothing);
        expect(find.text('Tekir'), findsOneWidget);
      },
    );

    testWidgets('shows the empty state when there are no followed cats', (
      tester,
    ) async {
      await _pump(tester, session: _session, followsApi: _FakeFollowsApi());
      await _selectFollowingTab(tester);

      expect(find.text('henüz kimseyi takip etmiyorsun'), findsOneWidget);
      expect(
        find.text(
          'bir kedinin sayfasındaki kalbe dokun; ona yardım '
          'gerektiğinde haberin olsun.',
        ),
        findsOneWidget,
      );
      // The filter row stays visible and tappable: the emptiness reads as
      // a filter result, not an empty app.
      expect(find.text('Takip ettiklerim'), findsOneWidget);
      expect(find.text('Yakınımda'), findsOneWidget);
    });

    testWidgets('the empty state\'s quiet action jumps to the nearby tab', (
      tester,
    ) async {
      await _pump(tester, session: _session, followsApi: _FakeFollowsApi());
      await _selectFollowingTab(tester);

      await tester.tap(find.text('yakındakilere göz at'));
      await tester.pumpAndSettle();

      expect(find.text('Yakında kedi bulunamadı'), findsOneWidget);
      expect(find.text('henüz kimseyi takip etmiyorsun'), findsNothing);
    });

    testWidgets('the empty state survives a large system text scale', (
      tester,
    ) async {
      await _pump(
        tester,
        session: _session,
        followsApi: _FakeFollowsApi(),
        textScale: 2.0,
      );
      await _selectFollowingTab(tester);

      expect(find.text('henüz kimseyi takip etmiyorsun'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lists followed cats and navigates to the cat detail on tap', (
      tester,
    ) async {
      final api = _FakeFollowsApi(
        nextCats: const [
          CatMarker(
            id: 'cat-1',
            name: 'Tekir',
            primaryPhoto: '',
            lat: 41.0,
            lng: 29.0,
            areaLabel: 'Galata',
          ),
        ],
      );
      await _pump(tester, session: _session, followsApi: api);
      await _selectFollowingTab(tester);

      expect(find.text('Tekir'), findsOneWidget);

      await tester.tap(find.text('Tekir'));
      await tester.pumpAndSettle();

      expect(find.text('cat detail cat-1'), findsOneWidget);
    });

    testWidgets('a fetch failure shows a retry state, and retry re-fetches', (
      tester,
    ) async {
      final api = _FakeFollowsApi(nextError: Exception('network down'));
      await _pump(tester, session: _session, followsApi: api);
      await _selectFollowingTab(tester);

      expect(
        find.text('Bağlantı sorunu oldu. Tekrar dener misin?'),
        findsOneWidget,
      );

      api.nextError = null;
      api.nextCats = const [
        CatMarker(
          id: 'cat-1',
          name: 'Tekir',
          primaryPhoto: '',
          lat: 41.0,
          lng: 29.0,
        ),
      ];
      await tester.tap(find.text('Tekrar dene'));
      await tester.pumpAndSettle();

      expect(find.text('Tekir'), findsOneWidget);
      expect(api.calls, 2);
    });
  });

  testWidgets('switching tabs preserves each tab\'s own loaded state', (
    tester,
  ) async {
    final discoverApi = _FakeDiscoverApi()
      ..nextNearby = const [
        DiscoverCat(
          id: 'cat-1',
          name: 'Tekir',
          primaryPhoto: '',
          distanceMeters: 10,
        ),
      ];
    final followsApi = _FakeFollowsApi(
      nextCats: const [
        CatMarker(
          id: 'cat-2',
          name: 'Boncuk',
          primaryPhoto: '',
          lat: 41.0,
          lng: 29.0,
        ),
      ],
    );
    await _pump(
      tester,
      session: _session,
      followsApi: followsApi,
      discoverApi: discoverApi,
    );
    expect(find.text('Tekir'), findsOneWidget);

    await _selectFollowingTab(tester);
    expect(find.text('Boncuk'), findsOneWidget);
    expect(find.text('Tekir'), findsNothing);

    await tester.tap(find.text('Yakınımda'));
    await tester.pumpAndSettle();
    expect(find.text('Tekir'), findsOneWidget);
    // nearby wasn't refetched a second time when returning to its tab.
    expect(discoverApi.calls, 1);
  });
}

/// A [DiscoverApi] whose first fetch never resolves until the test
/// completes it — used only to observe the loading state before settling.
class _BlockingDiscoverApi extends DiscoverApi {
  _BlockingDiscoverApi(this.completer) : super(ApiClient());

  final Completer<DiscoverPage> completer;

  @override
  Future<DiscoverPage> fetch({
    required DiscoverFilter filter,
    required double lat,
    required double lng,
    String? cursor,
  }) {
    return completer.future;
  }
}
