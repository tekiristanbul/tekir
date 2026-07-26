import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/auth/data/auth_api.dart';
import 'package:app/features/auth/ui/login_screen.dart';
import 'package:app/features/follow/data/follows_api.dart';
import 'package:app/features/follow/ui/follow_button.dart';
import 'package:app/features/map/data/cat_marker.dart';

const _catId = 'cat-1';

// Mirrors auth_gate_test.dart's fakes exactly.
class _FakeSessionIdentityService implements SessionIdentityService {
  _FakeSessionIdentityService({SessionIdentity? initial}) : _cached = initial;

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

class _FakeAuthApi implements AuthApi {
  AuthSession? nextSession;

  @override
  Future<void> requestOtp(String phone) async {}

  @override
  Future<AuthSession> verifyOtp({
    required String phone,
    required String code,
  }) async => nextSession!;

  @override
  Future<void> setDisplayName(String displayName) async {}
}

class _FakeFollowsApi implements FollowsApi {
  int followCalls = 0;

  @override
  Future<void> follow(String catId) async => followCalls++;

  @override
  Future<void> unfollow(String catId) async {}

  @override
  Future<List<CatMarker>> fetchFollows() async => const [];
}

Widget _appWith({
  required SessionIdentityService session,
  required FollowsApi followsApi,
  AuthApi? authApi,
}) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(
          body: Center(child: FollowButton(catId: _catId)),
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
      sessionIdentityServiceProvider.overrideWithValue(session),
      followsApiProvider.overrideWithValue(followsApi),
      authApiProvider.overrideWithValue(authApi ?? _FakeAuthApi()),
    ],
    child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
  );
}

void main() {
  testWidgets(
    'a guest tap shows the auth prompt and never calls follow before auth succeeds',
    (tester) async {
      final api = _FakeFollowsApi();
      await tester.pumpWidget(
        _appWith(session: _FakeSessionIdentityService(), followsApi: api),
      );

      await tester.tap(find.text('Takip et'));
      await tester.pumpAndSettle();

      expect(
        find.text('Bir kediyi takip etmek için giriş yap'),
        findsOneWidget,
      );
      expect(find.byType(LoginScreen), findsNothing);
      expect(api.followCalls, 0);
    },
  );

  testWidgets(
    'signing in from the guest prompt resumes the follow intent exactly once',
    (tester) async {
      final api = _FakeFollowsApi();
      final authApi = _FakeAuthApi()
        ..nextSession = const AuthSession(
          accessToken: 'at',
          refreshToken: 'rt',
          userId: 'user-1',
          isNewAccount: false,
        );
      await tester.pumpWidget(
        _appWith(
          session: _FakeSessionIdentityService(),
          followsApi: api,
          authApi: authApi,
        ),
      );

      await tester.tap(find.text('Takip et'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Giriş yap'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '5321112233');
      await tester.tap(find.text('Kod gönder'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '123456');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Giriş yap'));
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsNothing);
      expect(api.followCalls, 1);
      expect(find.text('Takip ediliyor'), findsOneWidget);
    },
  );

  testWidgets(
    'an already-authenticated tap follows immediately, with no auth prompt',
    (tester) async {
      final api = _FakeFollowsApi();
      await tester.pumpWidget(
        _appWith(
          session: _FakeSessionIdentityService(
            initial: const SessionIdentity(
              accessToken: 'at',
              refreshToken: 'rt',
              userId: 'u1',
            ),
          ),
          followsApi: api,
        ),
      );

      await tester.tap(find.text('Takip et'));
      await tester.pumpAndSettle();

      expect(api.followCalls, 1);
      expect(find.text('Bir kediyi takip etmek için giriş yap'), findsNothing);
      expect(find.text('Takip ediliyor'), findsOneWidget);
    },
  );
}
