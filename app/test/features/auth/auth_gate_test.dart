import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:dio/dio.dart';

import 'package:app/core/identity/device_identity.dart';
import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/auth/data/auth_api.dart';
import 'package:app/core/analytics/analytics.dart';
import 'package:app/features/auth/ui/auth_gate.dart';
import 'package:app/features/auth/ui/login_screen.dart';

// Pre-populated in-memory storage so AuthNotifier.verifyCode's device
// identity init() resolves instantly with no real platform channel —
// mirrors cat_update_composer_notifier_test.dart's identical need.
class _FakeDeviceStorage implements DeviceKeyValueStorage {
  final _data = <String, String>{'device_id': 'did-1', 'device_token': 'tok-1'};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

DeviceIdentityService _fakeDeviceIdentityService() => DeviceIdentityService(
  storage: _FakeDeviceStorage(),
  dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080')),
);

class _FakeAuthApi implements AuthApi {
  AuthSession? nextSession;

  @override
  Future<void> requestOtp(String phone) async {}

  @override
  Future<AuthSession> verifyOtp({
    required String phone,
    required String code,
  }) async {
    return nextSession!;
  }

  @override
  Future<void> setDisplayName(String displayName) async {}
}

class _FakeSessionIdentityService implements SessionIdentityService {
  SessionIdentity? _cached;

  _FakeSessionIdentityService({SessionIdentity? initial}) : _cached = initial;

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

Widget _appWith(
  _FakeAuthApi api,
  _FakeSessionIdentityService session, {
  required int Function() onAuthenticatedCount,
  required VoidCallback onAuthenticated,
}) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => AuthGate.require(
                  context,
                  ref,
                  contextText: 'Bir kediyi takip etmek için giriş yap',
                  intent: AnalyticsAuthIntent.follow,
                  onAuthenticated: onAuthenticated,
                ),
                child: const Text('follow'),
              ),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) =>
            LoginScreen(contextText: state.extra as String?),
      ),
    ],
  );

  return ProviderScope(
    overrides: [
      authApiProvider.overrideWithValue(api),
      sessionIdentityServiceProvider.overrideWithValue(session),
      deviceIdentityServiceProvider.overrideWithValue(
        _fakeDeviceIdentityService(),
      ),
    ],
    child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
  );
}

void main() {
  testWidgets(
    'an already-authenticated user runs the action immediately, no sheet',
    (tester) async {
      var authenticatedCalls = 0;
      final session = _FakeSessionIdentityService(
        initial: const SessionIdentity(
          accessToken: 'at',
          refreshToken: 'rt',
          userId: 'u1',
        ),
      );
      await tester.pumpWidget(
        _appWith(
          _FakeAuthApi(),
          session,
          onAuthenticatedCount: () => authenticatedCalls,
          onAuthenticated: () => authenticatedCalls++,
        ),
      );

      await tester.tap(find.text('follow'));
      await tester.pumpAndSettle();

      expect(authenticatedCalls, 1);
      expect(find.byType(LoginScreen), findsNothing);
    },
  );

  testWidgets('a guest sees the prompt sheet with the gate context text', (
    tester,
  ) async {
    var authenticatedCalls = 0;
    await tester.pumpWidget(
      _appWith(
        _FakeAuthApi(),
        _FakeSessionIdentityService(),
        onAuthenticatedCount: () => authenticatedCalls,
        onAuthenticated: () => authenticatedCalls++,
      ),
    );

    await tester.tap(find.text('follow'));
    await tester.pumpAndSettle();

    expect(find.text('Bir kediyi takip etmek için giriş yap'), findsOneWidget);
    expect(authenticatedCalls, 0);
  });

  testWidgets('dismissing the sheet ("Vazgeç") never runs the action', (
    tester,
  ) async {
    var authenticatedCalls = 0;
    await tester.pumpWidget(
      _appWith(
        _FakeAuthApi(),
        _FakeSessionIdentityService(),
        onAuthenticatedCount: () => authenticatedCalls,
        onAuthenticated: () => authenticatedCalls++,
      ),
    );

    await tester.tap(find.text('follow'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();

    expect(authenticatedCalls, 0);
    expect(find.byType(LoginScreen), findsNothing);
  });

  testWidgets('completing login from the sheet runs the action exactly once', (
    tester,
  ) async {
    var authenticatedCalls = 0;
    final api = _FakeAuthApi()
      ..nextSession = const AuthSession(
        accessToken: 'at',
        refreshToken: 'rt',
        userId: 'user-1',
        isNewAccount: false,
      );
    await tester.pumpWidget(
      _appWith(
        api,
        _FakeSessionIdentityService(),
        onAuthenticatedCount: () => authenticatedCalls,
        onAuthenticated: () => authenticatedCalls++,
      ),
    );

    await tester.tap(find.text('follow'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Giriş yap'));
    await tester.pumpAndSettle();

    expect(find.text('Doğrulama kodu'), findsNothing); // still phone step
    await tester.enterText(find.byType(TextField).first, '5321112233');
    await tester.tap(find.text('Kod gönder'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Giriş yap'));
    await tester.pumpAndSettle();

    expect(authenticatedCalls, 1);
    expect(find.byType(LoginScreen), findsNothing);
  });
}
