import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/account/data/account_api.dart';
import 'package:app/features/account/ui/account_screen.dart';
import 'package:app/features/auth/data/auth_api.dart';

class _FakeAccountApi implements AccountApi {
  AccountInfo? nextInfo;
  Object? nextError;
  int calls = 0;

  Object? deleteError;
  int deleteCalls = 0;

  @override
  Future<AccountInfo> fetchMe() async {
    calls++;
    if (nextError != null) throw nextError!;
    return nextInfo!;
  }

  @override
  Future<void> deleteAccount() async {
    deleteCalls++;
    if (deleteError != null) throw deleteError!;
    // The account is gone from here on: a reload lands on the guest shape.
    nextInfo = const AccountInfo(
      deviceId: 'device-1',
      userId: null,
      phoneVerified: false,
    );
  }
}

class _FakeAuthApi implements AuthApi {
  @override
  Future<void> requestOtp(String phone) async {}

  @override
  Future<AuthSession> verifyOtp({
    required String phone,
    required String code,
  }) async {
    return const AuthSession(
      accessToken: 'at',
      refreshToken: 'rt',
      userId: 'user-1',
      isNewAccount: false,
    );
  }

  @override
  Future<void> setDisplayName(String displayName) async {}
}

class _FakeSessionIdentityService implements SessionIdentityService {
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

Future<void> _pump(
  WidgetTester tester, {
  required _FakeAccountApi accountApi,
  _FakeAuthApi? authApi,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        accountApiProvider.overrideWithValue(accountApi),
        authApiProvider.overrideWithValue(authApi ?? _FakeAuthApi()),
        sessionIdentityServiceProvider.overrideWithValue(
          _FakeSessionIdentityService(),
        ),
      ],
      child: MaterialApp(theme: AppTheme.light, home: const AccountScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the guest empty-state with a login cta', (tester) async {
    final api = _FakeAccountApi()
      ..nextInfo = const AccountInfo(
        deviceId: 'd1',
        userId: null,
        phoneVerified: false,
      );
    await _pump(tester, accountApi: api);

    expect(find.text('Giriş yapmadın'), findsOneWidget);
    expect(find.text('Giriş yap'), findsOneWidget);
    expect(find.text('Çıkış yap'), findsNothing);
  });

  testWidgets('shows the authenticated state with a logout button', (
    tester,
  ) async {
    final api = _FakeAccountApi()
      ..nextInfo = const AccountInfo(
        deviceId: 'd1',
        userId: 'user-1',
        phoneVerified: true,
      );
    await _pump(tester, accountApi: api);

    expect(find.text('Telefon doğrulandı'), findsOneWidget);
    expect(find.text('Çıkış yap'), findsOneWidget);
    expect(find.text('Giriş yapmadın'), findsNothing);
  });

  testWidgets('never shows a phone number, since the api never returns one', (
    tester,
  ) async {
    final api = _FakeAccountApi()
      ..nextInfo = const AccountInfo(
        deviceId: 'd1',
        userId: 'user-1',
        phoneVerified: true,
      );
    await _pump(tester, accountApi: api);

    expect(find.textContaining('+90'), findsNothing);
  });

  testWidgets('a fetch failure shows a retry state', (tester) async {
    final api = _FakeAccountApi()..nextError = Exception('network down');
    await _pump(tester, accountApi: api);

    expect(
      find.text('Bağlantı sorunu oldu. Tekrar dener misin?'),
      findsOneWidget,
    );

    api.nextError = null;
    api.nextInfo = const AccountInfo(
      deviceId: 'd1',
      userId: null,
      phoneVerified: false,
    );
    await tester.tap(find.text('Tekrar dene'));
    await tester.pumpAndSettle();

    expect(find.text('Giriş yapmadın'), findsOneWidget);
  });

  testWidgets('logout returns the screen to the guest state', (tester) async {
    final api = _FakeAccountApi()
      ..nextInfo = const AccountInfo(
        deviceId: 'd1',
        userId: 'user-1',
        phoneVerified: true,
      );
    await _pump(tester, accountApi: api);
    expect(find.text('Çıkış yap'), findsOneWidget);

    // after logout, /v1/me (device-token only) reports a guest again.
    api.nextInfo = const AccountInfo(
      deviceId: 'd1',
      userId: null,
      phoneVerified: false,
    );
    await tester.tap(find.text('Çıkış yap'));
    await tester.pumpAndSettle();

    expect(find.text('Giriş yapmadın'), findsOneWidget);
  });

  group('account deletion (issue #242)', () {
    testWidgets('is offered to a signed-in account, never to a guest', (
      tester,
    ) async {
      final api = _FakeAccountApi()
        ..nextInfo = const AccountInfo(
          deviceId: 'd1',
          userId: 'user-1',
          phoneVerified: true,
        );
      await _pump(tester, accountApi: api);
      expect(find.text('Hesabımı sil'), findsOneWidget);

      api.nextInfo = const AccountInfo(
        deviceId: 'd1',
        userId: null,
        phoneVerified: false,
      );
      await tester.tap(find.text('Çıkış yap'));
      await tester.pumpAndSettle();

      expect(find.text('Hesabımı sil'), findsNothing);
    });

    // Deleting is terminal, so it must not happen on a single tap.
    testWidgets('asks for confirmation, and cancelling deletes nothing', (
      tester,
    ) async {
      final api = _FakeAccountApi()
        ..nextInfo = const AccountInfo(
          deviceId: 'd1',
          userId: 'user-1',
          phoneVerified: true,
        );
      await _pump(tester, accountApi: api);

      await tester.tap(find.text('Hesabımı sil'));
      await tester.pumpAndSettle();
      expect(find.text('Vazgeç'), findsOneWidget);

      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();

      expect(api.deleteCalls, 0);
      expect(find.text('Çıkış yap'), findsOneWidget);
    });

    testWidgets('confirming deletes and returns to the guest state', (
      tester,
    ) async {
      final api = _FakeAccountApi()
        ..nextInfo = const AccountInfo(
          deviceId: 'd1',
          userId: 'user-1',
          phoneVerified: true,
        );
      await _pump(tester, accountApi: api);

      await tester.tap(find.text('Hesabımı sil'));
      await tester.pumpAndSettle();
      // the dialog's own confirm button, not the screen's trigger
      await tester.tap(find.widgetWithText(TextButton, 'Hesabımı sil').last);
      await tester.pumpAndSettle();

      expect(api.deleteCalls, 1);
      expect(find.text('Giriş yapmadın'), findsOneWidget);
    });

    // A failed deletion must leave the user signed in: signing them out of
    // an account that still exists would strand them with no way back.
    testWidgets('a failure keeps the session and offers a retry', (
      tester,
    ) async {
      final api = _FakeAccountApi()
        ..nextInfo = const AccountInfo(
          deviceId: 'd1',
          userId: 'user-1',
          phoneVerified: true,
        )
        ..deleteError = const AccountServerException();
      await _pump(tester, accountApi: api);

      await tester.tap(find.text('Hesabımı sil'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Hesabımı sil').last);
      await tester.pumpAndSettle();

      expect(api.deleteCalls, 1);
      expect(find.text('Hesap silinemedi, tekrar dene.'), findsOneWidget);
      expect(find.text('Çıkış yap'), findsOneWidget);
    });
  });
}
