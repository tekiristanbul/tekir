import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/auth/data/auth_api.dart';
import 'package:app/features/auth/ui/login_screen.dart';

class _FakeAuthApi implements AuthApi {
  Object? nextRequestError;
  Object? nextVerifyError;
  AuthSession? nextSession;
  int requestCalls = 0;

  @override
  Future<void> requestOtp(String phone) async {
    requestCalls++;
    if (nextRequestError != null) throw nextRequestError!;
  }

  @override
  Future<AuthSession> verifyOtp({
    required String phone,
    required String code,
  }) async {
    if (nextVerifyError != null) throw nextVerifyError!;
    return nextSession!;
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
  Future<void> save(SessionIdentity identity) async => _cached = identity;

  @override
  Future<void> logout() async => _cached = null;
}

Future<bool?> _pumpLogin(
  WidgetTester tester, {
  required _FakeAuthApi api,
  String? contextText,
}) async {
  bool? poppedWith;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authApiProvider.overrideWithValue(api),
        sessionIdentityServiceProvider.overrideWithValue(
          _FakeSessionIdentityService(),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  poppedWith = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => LoginScreen(contextText: contextText),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return poppedWith;
}

void main() {
  testWidgets('shows the gate context text on the phone step', (tester) async {
    await _pumpLogin(
      tester,
      api: _FakeAuthApi(),
      contextText: 'Bir kediyi takip etmek için giriş yap',
    );

    expect(find.text('Bir kediyi takip etmek için giriş yap'), findsOneWidget);
  });

  testWidgets('an invalid phone number shows an inline error, no api call', (
    tester,
  ) async {
    final api = _FakeAuthApi();
    await _pumpLogin(tester, api: api);

    await tester.enterText(find.byType(TextField).first, '123');
    await tester.tap(find.text('Kod gönder'));
    await tester.pumpAndSettle();

    expect(find.text('Geçerli bir telefon numarası gir'), findsOneWidget);
    expect(api.requestCalls, 0);
  });

  testWidgets('a valid phone advances to the code step', (tester) async {
    final api = _FakeAuthApi();
    await _pumpLogin(tester, api: api);

    await tester.enterText(find.byType(TextField).first, '532 111 22 33');
    await tester.tap(find.text('Kod gönder'));
    await tester.pumpAndSettle();

    expect(find.text('Doğrulama kodu'), findsOneWidget);
    expect(api.requestCalls, 1);
  });

  testWidgets('a returning account finishes the flow and pops with success', (
    tester,
  ) async {
    final api = _FakeAuthApi()
      ..nextSession = const AuthSession(
        accessToken: 'at',
        refreshToken: 'rt',
        userId: 'user-1',
        isNewAccount: false,
      );

    bool? result;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authApiProvider.overrideWithValue(api),
          sessionIdentityServiceProvider.overrideWithValue(
            _FakeSessionIdentityService(),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '5321112233');
    await tester.tap(find.text('Kod gönder'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Giriş yap'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
  });

  testWidgets(
    'a brand-new account shows the name step, then finishes on submit',
    (tester) async {
      final api = _FakeAuthApi()
        ..nextSession = const AuthSession(
          accessToken: 'at',
          refreshToken: 'rt',
          userId: 'user-2',
          isNewAccount: true,
        );

      final box = _ResultBox();
      await _pumpLoginAndAdvanceToName(tester, api, box);

      expect(find.text('Görünen adını seç'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'Ayşe');
      await tester.tap(find.text('Kaydet ve devam et'));
      await tester.pumpAndSettle();

      expect(box.value, isTrue);
    },
  );

  testWidgets('an empty name on the name step shows an inline error', (
    tester,
  ) async {
    final api = _FakeAuthApi()
      ..nextSession = const AuthSession(
        accessToken: 'at',
        refreshToken: 'rt',
        userId: 'user-3',
        isNewAccount: true,
      );

    await _pumpLoginAndAdvanceToName(tester, api, _ResultBox());
    await tester.tap(find.text('Kaydet ve devam et'));
    await tester.pumpAndSettle();

    expect(find.text('Bir isim gir'), findsOneWidget);
  });

  testWidgets('invalid code shows its inline turkish message', (tester) async {
    final api = _FakeAuthApi()
      ..nextVerifyError = const OtpInvalidCodeException();
    await _pumpLogin(tester, api: api);

    await tester.enterText(find.byType(TextField).first, '5321112233');
    await tester.tap(find.text('Kod gönder'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Giriş yap'));
    await tester.pumpAndSettle();

    expect(find.text('Kodu yanlış girdin, tekrar dene'), findsOneWidget);
  });

  testWidgets('expired code shows its inline turkish message', (tester) async {
    final api = _FakeAuthApi()
      ..nextVerifyError = const OtpExpiredCodeException();
    await _pumpLogin(tester, api: api);

    await tester.enterText(find.byType(TextField).first, '5321112233');
    await tester.tap(find.text('Kod gönder'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Giriş yap'));
    await tester.pumpAndSettle();

    expect(find.text('Kodun süresi doldu, yeni kod iste'), findsOneWidget);
  });

  testWidgets('offline/network failure shows its inline turkish message', (
    tester,
  ) async {
    final api = _FakeAuthApi()..nextRequestError = const AuthNetworkException();
    await _pumpLogin(tester, api: api);

    await tester.enterText(find.byType(TextField).first, '5321112233');
    await tester.tap(find.text('Kod gönder'));
    await tester.pumpAndSettle();

    expect(find.text('Bağlantı sorunu, tekrar dene'), findsOneWidget);
  });

  testWidgets('retrying after a failure can still succeed', (tester) async {
    final api = _FakeAuthApi()..nextRequestError = const AuthNetworkException();
    await _pumpLogin(tester, api: api);

    await tester.enterText(find.byType(TextField).first, '5321112233');
    await tester.tap(find.text('Kod gönder'));
    await tester.pumpAndSettle();
    expect(find.text('Bağlantı sorunu, tekrar dene'), findsOneWidget);

    api.nextRequestError = null;
    await tester.tap(find.text('Kod gönder'));
    await tester.pumpAndSettle();

    expect(find.text('Doğrulama kodu'), findsOneWidget);
  });

  testWidgets('cancel (close icon) pops without authenticating', (
    tester,
  ) async {
    bool? result;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authApiProvider.overrideWithValue(_FakeAuthApi()),
          sessionIdentityServiceProvider.overrideWithValue(
            _FakeSessionIdentityService(),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(result, isFalse);
  });
}

/// Mutable holder for the eventual pop result — `bool? result` captured
/// inside the pushed route's `onPressed` closure is still unset at the
/// point this helper itself returns (the pushed screen hasn't been popped
/// yet, since the caller still has more steps to drive), so tests read
/// [value] only after their own further interaction completes.
class _ResultBox {
  bool? value;
}

Future<void> _pumpLoginAndAdvanceToName(
  WidgetTester tester,
  _FakeAuthApi api,
  _ResultBox box,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authApiProvider.overrideWithValue(api),
        sessionIdentityServiceProvider.overrideWithValue(
          _FakeSessionIdentityService(),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  box.value = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();

  await tester.enterText(find.byType(TextField).first, '5321112233');
  await tester.tap(find.text('Kod gönder'));
  await tester.pumpAndSettle();

  await tester.enterText(find.byType(TextField).first, '123456');
  await tester.tap(find.widgetWithText(ElevatedButton, 'Giriş yap'));
  await tester.pumpAndSettle();
}
