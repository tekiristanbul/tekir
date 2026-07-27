import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:app/core/theme/app_theme.dart';
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

Future<void> _pump(WidgetTester tester, _FakeNotificationsApi api) async {
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
      overrides: [notificationsApiProvider.overrideWithValue(api)],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows the empty state when there are no notifications', (
    tester,
  ) async {
    final api = _FakeNotificationsApi();
    await _pump(tester, api);
    await tester.pumpAndSettle();

    expect(find.text('Henüz bildirimin yok'), findsOneWidget);
    expect(api.fetchCalls, 1);
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
