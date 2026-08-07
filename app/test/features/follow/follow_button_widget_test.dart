import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:dio/dio.dart';

import 'package:app/core/identity/device_identity.dart';
import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/auth/data/auth_api.dart';
import 'package:app/features/auth/ui/login_screen.dart';
import 'package:app/features/follow/data/follows_api.dart';
import 'package:app/features/follow/ui/follow_button.dart';
import 'package:app/features/map/data/cat_marker.dart';

const _catId = 'cat-1';

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

// Mirrors auth_gate_test.dart's fakes exactly.
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
  bool glass = false,
}) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: Center(
            child: FollowButton(catId: _catId, glass: glass),
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
      sessionIdentityServiceProvider.overrideWithValue(session),
      followsApiProvider.overrideWithValue(followsApi),
      authApiProvider.overrideWithValue(authApi ?? _FakeAuthApi()),
      deviceIdentityServiceProvider.overrideWithValue(
        _fakeDeviceIdentityService(),
      ),
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

  group('glass variant (on-cover placement)', () {
    testWidgets(
      'renders icon-only, with neither the labeled outline button nor its text',
      (tester) async {
        final api = _FakeFollowsApi();
        await tester.pumpWidget(
          _appWith(
            session: _FakeSessionIdentityService(),
            followsApi: api,
            glass: true,
          ),
        );

        expect(find.byIcon(Icons.favorite_border), findsOneWidget);
        expect(find.byType(OutlinedButton), findsNothing);
        expect(find.text('Takip et'), findsNothing);
      },
    );

    testWidgets(
      'a guest tap still gates behind auth, never calls follow before auth succeeds',
      (tester) async {
        final api = _FakeFollowsApi();
        await tester.pumpWidget(
          _appWith(
            session: _FakeSessionIdentityService(),
            followsApi: api,
            glass: true,
          ),
        );

        await tester.tap(find.byIcon(Icons.favorite_border));
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
      'an already-authenticated tap follows immediately and swaps to the filled heart',
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
            glass: true,
          ),
        );

        await tester.tap(find.byIcon(Icons.favorite_border));
        await tester.pumpAndSettle();

        expect(api.followCalls, 1);
        expect(find.byIcon(Icons.favorite), findsOneWidget);
        expect(find.byIcon(Icons.favorite_border), findsNothing);
      },
    );
  });
}
