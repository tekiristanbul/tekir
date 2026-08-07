import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:app/core/analytics/analytics.dart';
import 'package:app/core/identity/device_identity.dart';
import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/push/push_messaging_backend.dart';
import 'package:app/core/push/push_notifications.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/auth/data/auth_api.dart';
import 'package:app/features/follow/data/follows_api.dart';
import 'package:app/features/follow/ui/follow_button.dart';
import 'package:app/features/map/data/cat_marker.dart';

const _catId = 'cat-1';

class _FakeStorage implements DeviceKeyValueStorage {
  final _data = <String, String>{'device_id': 'did-1', 'device_token': 'tok-1'};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

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

class _FakeFollowsApi implements FollowsApi {
  int followCalls = 0;
  int unfollowCalls = 0;

  @override
  Future<void> follow(String catId) async => followCalls++;

  @override
  Future<void> unfollow(String catId) async => unfollowCalls++;

  @override
  Future<List<CatMarker>> fetchFollows() async => const [];
}

const _authenticatedSession = SessionIdentity(
  accessToken: 'at',
  refreshToken: 'rt',
  userId: 'u1',
);

Future<void> _pump(
  WidgetTester tester, {
  required _FakeFollowsApi followsApi,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(
          body: Center(child: FollowButton(catId: _catId)),
        ),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionIdentityServiceProvider.overrideWithValue(
          _FakeSessionIdentityService(initial: _authenticatedSession),
        ),
        followsApiProvider.overrideWithValue(followsApi),
        authApiProvider.overrideWithValue(_FakeAuthApi()),
        deviceIdentityServiceProvider.overrideWithValue(
          DeviceIdentityService(
            storage: _FakeStorage(),
            dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080')),
          ),
        ),
      ],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'following a cat for the first time shows the notification opt-in prompt',
    (tester) async {
      final api = _FakeFollowsApi();
      await _pump(tester, followsApi: api);

      await tester.tap(find.text('Takip et'));
      await tester.pumpAndSettle();

      expect(api.followCalls, 1);
      expect(
        find.text('Bu kedi için bildirim almak ister misin?'),
        findsOneWidget,
      );
    },
  );

  testWidgets('unfollowing never shows the notification opt-in prompt', (
    tester,
  ) async {
    final api = _FakeFollowsApi();
    await _pump(tester, followsApi: api);

    // follow, dismiss the prompt, then unfollow.
    await tester.tap(find.text('Takip et'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Şimdi değil'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Takip ediliyor'));
    await tester.pumpAndSettle();

    expect(api.unfollowCalls, 1);
    expect(find.text('Bu kedi için bildirim almak ister misin?'), findsNothing);
  });

  testWidgets(
    'the prompt is shown at most once per session, even across repeated follows',
    (tester) async {
      final api = _FakeFollowsApi();
      await _pump(tester, followsApi: api);

      await tester.tap(find.text('Takip et'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('İzin ver'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Takip ediliyor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Takip et'));
      await tester.pumpAndSettle();

      expect(api.followCalls, 2);
      expect(
        find.text('Bu kedi için bildirim almak ister misin?'),
        findsNothing,
      );
    },
  );

  testWidgets('"Şimdi değil" and "İzin ver" both simply dismiss the prompt', (
    tester,
  ) async {
    final api = _FakeFollowsApi();
    await _pump(tester, followsApi: api);

    await tester.tap(find.text('Takip et'));
    await tester.pumpAndSettle();
    expect(
      find.text('Bu kedi için bildirim almak ister misin?'),
      findsOneWidget,
    );

    await tester.tap(find.text('İzin ver'));
    await tester.pumpAndSettle();

    expect(find.text('Bu kedi için bildirim almak ister misin?'), findsNothing);
  });
  optInPermissionTests();
}

// ── issue #84: the opt-in sheet is the approved permission point ─────────────

class _PermissionCountingBackend implements PushMessagingBackend {
  int requestPermissionCalls = 0;

  @override
  Future<PushPermissionStatus> requestPermission() async {
    requestPermissionCalls++;
    return PushPermissionStatus.granted;
  }

  @override
  Future<PushPermissionStatus> currentPermission() async =>
      PushPermissionStatus.notRequested;

  @override
  Future<String?> getToken({String? vapidKey}) async => null;

  @override
  Stream<String> get onTokenRefresh => const Stream.empty();

  @override
  Stream<PushMessage> get onForegroundMessage => const Stream.empty();

  @override
  Stream<PushMessage> get onMessageOpened => const Stream.empty();

  @override
  Future<PushMessage?> takeInitialMessage() async => null;
}

Future<_PermissionCountingBackend> _pumpWithPush(WidgetTester tester) async {
  final backend = _PermissionCountingBackend();
  final pushService = PushNotificationsService(
    backend: backend,
    analytics: const NoopAnalyticsService(),
    dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080')),
    openCatDetail: (_) {},
  );
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(
          body: Center(child: FollowButton(catId: _catId)),
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionIdentityServiceProvider.overrideWithValue(
          _FakeSessionIdentityService(initial: _authenticatedSession),
        ),
        followsApiProvider.overrideWithValue(_FakeFollowsApi()),
        authApiProvider.overrideWithValue(_FakeAuthApi()),
        deviceIdentityServiceProvider.overrideWithValue(
          DeviceIdentityService(
            storage: _FakeStorage(),
            dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080')),
          ),
        ),
        pushNotificationsServiceProvider.overrideWithValue(pushService),
      ],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ),
  );
  await tester.pump();
  return backend;
}

void optInPermissionTests() {
  testWidgets('"İzin ver" is the only trigger for a real permission request', (
    tester,
  ) async {
    final backend = await _pumpWithPush(tester);

    // first launch / merely following: no request yet.
    expect(backend.requestPermissionCalls, 0);

    await tester.tap(find.text('Takip et'));
    await tester.pumpAndSettle();
    expect(backend.requestPermissionCalls, 0);

    await tester.tap(find.text('İzin ver'));
    await tester.pumpAndSettle();
    expect(backend.requestPermissionCalls, 1);
  });

  testWidgets('"Şimdi değil" never requests permission', (tester) async {
    final backend = await _pumpWithPush(tester);

    await tester.tap(find.text('Takip et'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Şimdi değil'));
    await tester.pumpAndSettle();

    expect(backend.requestPermissionCalls, 0);
  });
}
