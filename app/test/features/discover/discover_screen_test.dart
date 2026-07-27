import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/theme/app_theme.dart';
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
  Future<void> logout() async => _cached = null;
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

Future<void> _pump(
  WidgetTester tester, {
  required SessionIdentity? session,
  _FakeFollowsApi? followsApi,
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
        if (followsApi != null)
          followsApiProvider.overrideWithValue(followsApi),
      ],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a guest sees the login cta and never fetches follows', (
    tester,
  ) async {
    final api = _FakeFollowsApi();
    await _pump(tester, session: null, followsApi: api);

    expect(find.text('Giriş yapmadın'), findsOneWidget);
    expect(find.text('Giriş yap'), findsOneWidget);
    expect(api.calls, 0);
  });

  testWidgets('shows a loading indicator before the follows list arrives', (
    tester,
  ) async {
    final api = _FakeFollowsApi()..pending = Completer<void>();
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (context, state) => const DiscoverScreen()),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionIdentityServiceProvider.overrideWithValue(
            _FakeSessionIdentityService(cached: _session),
          ),
          followsApiProvider.overrideWithValue(api),
        ],
        child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
      ),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    api.pending!.complete();
  });

  testWidgets('shows the empty state when there are no followed cats', (
    tester,
  ) async {
    await _pump(tester, session: _session, followsApi: _FakeFollowsApi());

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
}
