import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dio/dio.dart';

import 'package:app/core/identity/device_identity.dart';
import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/router/app_router.dart';
import 'package:app/features/add_cat/ui/add_cat_screen.dart';
import 'package:app/features/auth/data/auth_api.dart';
import 'package:app/features/map/data/location_service.dart';
import 'package:app/features/map/ui/cats_map_notifier.dart';

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

// Mirrors follow_button_widget_test.dart's fakes exactly — same
// guest/resumed-intent/already-authenticated gate mechanism (AuthGate),
// just gating the map's add-cat action (issue #70) instead of follow
// (issue #65).
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

class _EmptyCatsMapNotifier extends CatsMapNotifier {
  @override
  CatsMapState build() => const CatsMapState(hasLoadedOnce: true);
}

Future<void> _pumpMap(
  WidgetTester tester, {
  required SessionIdentityService session,
  AuthApi? authApi,
}) async {
  // appRouter is a module-level singleton; reset location so earlier tests
  // in this file/isolate can't leak a navigated-away location into a later
  // one (mirrors map_marker_navigation_test.dart).
  appRouter.go('/');
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        initialLocationProvider.overrideWith(
          (ref) async => const ResolvedLocation(
            center: istanbulFallback,
            isFallback: false,
          ),
        ),
        catsMapProvider.overrideWith(_EmptyCatsMapNotifier.new),
        sessionIdentityServiceProvider.overrideWithValue(session),
        authApiProvider.overrideWithValue(authApi ?? _FakeAuthApi()),
        deviceIdentityServiceProvider.overrideWithValue(
          _fakeDeviceIdentityService(),
        ),
      ],
      child: MaterialApp.router(routerConfig: appRouter),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets(
    'a guest tap on the add-cat button shows the auth prompt and never opens the add-cat form',
    (tester) async {
      await _pumpMap(tester, session: _FakeSessionIdentityService());

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      expect(find.text('Kedi eklemek için giriş yap'), findsOneWidget);
      expect(find.byType(AddCatScreen), findsNothing);
    },
  );

  testWidgets(
    'signing in from the guest prompt resumes the add-cat intent exactly once',
    (tester) async {
      final authApi = _FakeAuthApi()
        ..nextSession = const AuthSession(
          accessToken: 'at',
          refreshToken: 'rt',
          userId: 'user-1',
          isNewAccount: false,
        );
      await _pumpMap(
        tester,
        session: _FakeSessionIdentityService(),
        authApi: authApi,
      );

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Giriş yap'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '5321112233');
      await tester.tap(find.text('Kod gönder'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '123456');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Giriş yap'));
      // AddCatScreen mounts a real GoogleMap platform view once it opens —
      // like map_marker_navigation_test.dart's _pumpMap, pumpAndSettle
      // would hang on its continuous internal animation, so settle with
      // fixed-duration pumps instead.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(AddCatScreen), findsOneWidget);
    },
  );

  testWidgets(
    'an already-authenticated tap opens the add-cat form immediately, with no auth prompt',
    (tester) async {
      await _pumpMap(
        tester,
        session: _FakeSessionIdentityService(
          initial: const SessionIdentity(
            accessToken: 'at',
            refreshToken: 'rt',
            userId: 'u1',
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.add));
      // see the comment above: AddCatScreen's real GoogleMap platform view
      // means pumpAndSettle would hang here.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Kedi eklemek için giriş yap'), findsNothing);
      expect(find.byType(AddCatScreen), findsOneWidget);
    },
  );
}
