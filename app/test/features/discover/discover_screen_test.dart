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

  @override
  Future<DiscoverLocationOutcome> resolve() async {
    calls++;
    return outcome;
  }
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
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
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
    testWidgets('shows a loading indicator before the first page arrives', (
      tester,
    ) async {
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

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      completer.complete(const DiscoverPage(items: []));
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
                category: 'food_needed',
                categoryLabel: 'mamaya ihtiyacı var',
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

    testWidgets(
      'permission denied shows a recoverable state, retry re-resolves',
      (tester) async {
        final location = _FixedDiscoverLocationService(
          const DiscoverLocationPermissionDenied(),
        );
        await _pump(tester, session: null, locationService: location);

        expect(find.text('Konum izni gerekli'), findsOneWidget);
        expect(location.calls, 1);

        location.outcome = const DiscoverLocationResolved(lat: 41.0, lng: 29.0);
        await tester.tap(find.text('Tekrar dene'));
        await tester.pumpAndSettle();

        expect(location.calls, 2);
        expect(find.text('Yakında kedi bulunamadı'), findsOneWidget);
      },
    );

    testWidgets('permission denied forever offers to open settings', (
      tester,
    ) async {
      await _pump(
        tester,
        session: null,
        locationService: _FixedDiscoverLocationService(
          const DiscoverLocationPermissionDeniedForever(),
        ),
      );

      expect(find.text('Konum izni kapalı'), findsOneWidget);
      expect(find.text('Ayarları aç'), findsOneWidget);
    });

    testWidgets('location service disabled offers to open location settings', (
      tester,
    ) async {
      await _pump(
        tester,
        session: null,
        locationService: _FixedDiscoverLocationService(
          const DiscoverLocationServiceDisabled(),
        ),
      );

      expect(find.text('Konum servisleri kapalı'), findsOneWidget);
      expect(find.text('Konum ayarlarını aç'), findsOneWidget);
    });

    testWidgets('generic location failure shows a plain retry', (tester) async {
      await _pump(
        tester,
        session: null,
        locationService: _FixedDiscoverLocationService(
          const DiscoverLocationUnavailable(),
        ),
      );

      expect(find.text('Konum alınamadı'), findsOneWidget);
      expect(find.text('Tekrar dene'), findsOneWidget);
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
              category: 'trapped',
              categoryLabel: 'mahsur kalmış',
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

    testWidgets('shows the empty state when there are no followed cats', (
      tester,
    ) async {
      await _pump(tester, session: _session, followsApi: _FakeFollowsApi());
      await _selectFollowingTab(tester);

      expect(find.text('Henüz takip ettiğin kedi yok'), findsOneWidget);
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
