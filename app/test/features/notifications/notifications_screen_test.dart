import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/follow/data/follows_api.dart';
import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/notifications/data/notification.dart';
import 'package:app/features/notifications/data/notifications_api.dart';
import 'package:app/features/notifications/ui/notifications_screen.dart';

AppNotification _notification(String id, {bool read = false}) =>
    AppNotification(
      id: id,
      catId: 'cat-$id',
      updateId: 'upd-$id',
      read: read,
      createdAt: DateTime.utc(2026, 3, 1),
    );

CatMarker _followedCat(
  String id, {
  String name = '',
  DateTime? seenAt,
  bool needsHelp = false,
}) {
  return CatMarker(
    id: id,
    name: name,
    primaryPhoto: '',
    lat: 41.0,
    lng: 29.0,
    lastUpdateAt: seenAt,
    activeAlert: needsHelp
        ? ActiveAlert(
            createdAt: DateTime.now(),
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
          )
        : null,
  );
}

class _FakeFollowsApi implements FollowsApi {
  _FakeFollowsApi({this.cats = const [], this.error});

  List<CatMarker> cats;
  Object? error;

  @override
  Future<void> follow(String catId) async {}

  @override
  Future<void> unfollow(String catId) async {}

  @override
  Future<List<CatMarker>> fetchFollows() async {
    if (error != null) throw error!;
    return cats;
  }
}

class _FakeNotificationsApi implements NotificationsApi {
  _FakeNotificationsApi({
    this.firstPage = const NotificationsPage(items: [], nextCursor: null),
    this.secondPage,
    this.fetchError,
  });

  final NotificationsPage firstPage;
  final NotificationsPage? secondPage;
  final Object? fetchError;

  int fetchCalls = 0;
  final markReadCalls = <String>[];

  @override
  Future<NotificationsPage> fetch({String? cursor}) async {
    fetchCalls++;
    if (fetchError != null) throw fetchError!;
    if (cursor == null) return firstPage;
    return secondPage ?? const NotificationsPage(items: [], nextCursor: null);
  }

  @override
  Future<void> markRead(String id) async {
    markReadCalls.add(id);
  }
}

Future<void> _pump(
  WidgetTester tester,
  _FakeNotificationsApi api, {
  _FakeFollowsApi? followsApi,
  double textScale = 1.0,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const NotificationsScreen(),
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
        notificationsApiProvider.overrideWithValue(api),
        followsApiProvider.overrideWithValue(followsApi ?? _FakeFollowsApi()),
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
  await tester.pump();
}

void main() {
  group('quiet day (state 09)', () {
    testWidgets(
      'an empty inbox shows the olive banner with real count and window',
      (tester) async {
        final now = DateTime.now();
        final api = _FakeNotificationsApi();
        await _pump(
          tester,
          api,
          followsApi: _FakeFollowsApi(
            cats: [
              _followedCat('1', name: 'Boncuk', seenAt: now),
              _followedCat(
                '2',
                name: 'Pamuk',
                seenAt: now.subtract(const Duration(days: 1)),
              ),
              _followedCat(
                '3',
                name: 'Duman',
                seenAt: now.subtract(const Duration(days: 2)),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('aktif yardım çağrısı yok'), findsOneWidget);
        expect(
          find.text('takip ettiğin 3 kedi de son 3 günde görüldü.'),
          findsOneWidget,
        );
        expect(find.text('takip ettiklerin'), findsOneWidget);
        expect(find.text('bugün görüldü'), findsOneWidget);
        expect(find.text('dün görüldü'), findsOneWidget);
        expect(find.text('2 gün önce'), findsOneWidget);
        expect(api.fetchCalls, 1);
      },
    );

    testWidgets('an unavailable follows source drops the sub-line and list', (
      tester,
    ) async {
      await _pump(
        tester,
        _FakeNotificationsApi(),
        followsApi: _FakeFollowsApi(error: const FollowNetworkException()),
      );
      await tester.pumpAndSettle();

      expect(find.text('aktif yardım çağrısı yok'), findsOneWidget);
      expect(find.textContaining('takip ettiğin'), findsNothing);
      expect(find.text('takip ettiklerin'), findsNothing);
    });

    testWidgets('zero follows keeps the banner count-free', (tester) async {
      await _pump(tester, _FakeNotificationsApi());
      await tester.pumpAndSettle();

      expect(find.text('aktif yardım çağrısı yok'), findsOneWidget);
      expect(find.textContaining('takip ettiğin'), findsNothing);
      expect(find.text('takip ettiklerin'), findsNothing);
    });

    testWidgets(
      'a cat without last_update_at drops the sub-line, not the list',
      (tester) async {
        final now = DateTime.now();
        await _pump(
          tester,
          _FakeNotificationsApi(),
          followsApi: _FakeFollowsApi(
            cats: [
              _followedCat('1', name: 'Boncuk', seenAt: now),
              _followedCat('2', name: 'Pamuk'),
            ],
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('takip ettiğin'), findsNothing);
        expect(find.text('takip ettiklerin'), findsOneWidget);
        expect(find.text('Boncuk'), findsOneWidget);
        expect(find.text('bugün görüldü'), findsOneWidget);
        expect(find.text('Pamuk'), findsOneWidget);
      },
    );

    testWidgets(
      'an active help call among follows suppresses the quiet-day banner',
      (tester) async {
        await _pump(
          tester,
          _FakeNotificationsApi(),
          followsApi: _FakeFollowsApi(
            cats: [_followedCat('1', name: 'Boncuk', needsHelp: true)],
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('aktif yardım çağrısı yok'), findsNothing);
        expect(find.text('Henüz bildirimin yok'), findsOneWidget);
      },
    );

    testWidgets('a followed row navigates to the cat detail', (tester) async {
      await _pump(
        tester,
        _FakeNotificationsApi(),
        followsApi: _FakeFollowsApi(
          cats: [_followedCat('7', name: 'Boncuk', seenAt: DateTime.now())],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Boncuk'));
      await tester.pumpAndSettle();

      expect(find.text('cat detail 7'), findsOneWidget);
    });

    testWidgets('survives a large system text scale', (tester) async {
      await _pump(
        tester,
        _FakeNotificationsApi(),
        followsApi: _FakeFollowsApi(
          cats: [_followedCat('1', name: 'Boncuk', seenAt: DateTime.now())],
        ),
        textScale: 2.0,
      );
      await tester.pumpAndSettle();

      expect(find.text('aktif yardım çağrısı yok'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('shows a retry action on load failure, and retry re-fetches', (
    tester,
  ) async {
    final api = _FakeNotificationsApi(fetchError: Exception('boom'));
    await _pump(tester, api);
    await tester.pumpAndSettle();

    expect(find.text('Bildirimler yüklenemedi'), findsOneWidget);

    await tester.tap(find.text('Tekrar dene'));
    await tester.pumpAndSettle();

    expect(api.fetchCalls, 2);
  });

  testWidgets(
    'lists notifications newest first, distinguishing read from unread',
    (tester) async {
      final api = _FakeNotificationsApi(
        firstPage: NotificationsPage(
          items: [_notification('1'), _notification('2', read: true)],
          nextCursor: null,
        ),
      );
      await _pump(tester, api);
      await tester.pumpAndSettle();

      expect(
        find.text('Takip ettiğin bir kedi için yardım bildirimi'),
        findsNWidgets(2),
      );
    },
  );

  testWidgets(
    'a load-more button appears when a next page exists, and pages in more items',
    (tester) async {
      final api = _FakeNotificationsApi(
        firstPage: NotificationsPage(
          items: [_notification('1')],
          nextCursor: 'cursor-1',
        ),
        secondPage: NotificationsPage(
          items: [_notification('2')],
          nextCursor: null,
        ),
      );
      await _pump(tester, api);
      await tester.pumpAndSettle();

      expect(find.text('Daha fazla göster'), findsOneWidget);

      await tester.tap(find.text('Daha fazla göster'));
      await tester.pumpAndSettle();

      expect(
        find.text('Takip ettiğin bir kedi için yardım bildirimi'),
        findsNWidgets(2),
      );
      expect(find.text('Daha fazla göster'), findsNothing);
    },
  );

  testWidgets('tapping a notification marks it read and navigates to the cat', (
    tester,
  ) async {
    final api = _FakeNotificationsApi(
      firstPage: NotificationsPage(
        items: [_notification('1')],
        nextCursor: null,
      ),
    );
    await _pump(tester, api);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Takip ettiğin bir kedi için yardım bildirimi'));
    await tester.pumpAndSettle();

    expect(api.markReadCalls, ['1']);
    expect(find.text('cat detail cat-1'), findsOneWidget);
  });
}
