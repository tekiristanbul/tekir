import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/auth/data/auth_api.dart';
import 'package:app/features/auth/ui/auth_gate.dart';
import 'package:app/features/auth/ui/login_screen.dart';

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
  Future<void> save(SessionIdentity identity) async => _cached = identity;

  @override
  Future<void> logout() async => _cached = null;
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
