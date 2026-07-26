import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/features/auth/data/auth_api.dart';
import 'package:app/features/auth/ui/auth_notifier.dart';

class _FakeAuthApi implements AuthApi {
  Object? nextRequestError;
  Object? nextVerifyError;
  Object? nextSetNameError;
  AuthSession? nextSession;

  String? lastRequestedPhone;
  String? lastVerifiedPhone;
  String? lastVerifiedCode;
  String? lastDisplayName;
  int requestCalls = 0;

  @override
  Future<void> requestOtp(String phone) async {
    requestCalls++;
    lastRequestedPhone = phone;
    if (nextRequestError != null) throw nextRequestError!;
  }

  @override
  Future<AuthSession> verifyOtp({
    required String phone,
    required String code,
  }) async {
    lastVerifiedPhone = phone;
    lastVerifiedCode = code;
    if (nextVerifyError != null) throw nextVerifyError!;
    return nextSession!;
  }

  @override
  Future<void> setDisplayName(String displayName) async {
    lastDisplayName = displayName;
    if (nextSetNameError != null) throw nextSetNameError!;
  }
}

class _FakeSessionIdentityService implements SessionIdentityService {
  SessionIdentity? _cached;
  SessionIdentity? saved;
  int logoutCalls = 0;

  @override
  SessionIdentity? get cached => _cached;

  @override
  Future<SessionIdentity?> restore() async => _cached;

  @override
  Future<void> save(SessionIdentity identity) async {
    saved = identity;
    _cached = identity;
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
    _cached = null;
  }
}

ProviderContainer _containerWith(
  _FakeAuthApi api, {
  _FakeSessionIdentityService? session,
}) {
  final container = ProviderContainer(
    overrides: [
      authApiProvider.overrideWithValue(api),
      sessionIdentityServiceProvider.overrideWithValue(
        session ?? _FakeSessionIdentityService(),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('AuthNotifier — phone step', () {
    test(
      'a short phone number is rejected locally, no api call made',
      () async {
        final api = _FakeAuthApi();
        final container = _containerWith(api);
        final notifier = container.read(authProvider.notifier);

        notifier.setPhone('532 11');
        final ok = await notifier.sendCode();

        expect(ok, isFalse);
        expect(container.read(authProvider).error, AuthError.invalidPhone);
        expect(api.requestCalls, 0);
      },
    );

    test(
      'a valid phone sends the code and advances to the code step',
      () async {
        final api = _FakeAuthApi();
        final container = _containerWith(api);
        final notifier = container.read(authProvider.notifier);

        notifier.setPhone('532 111 22 33');
        await notifier.sendCode();

        expect(container.read(authProvider).step, AuthStep.code);
        expect(api.lastRequestedPhone, '+905321112233');
      },
    );

    test(
      'server-reported invalid phone maps to AuthError.invalidPhone',
      () async {
        final api = _FakeAuthApi()
          ..nextRequestError = const OtpInvalidPhoneException();
        final container = _containerWith(api);
        final notifier = container.read(authProvider.notifier);

        notifier.setPhone('5321112233');
        await notifier.sendCode();

        expect(container.read(authProvider).error, AuthError.invalidPhone);
        expect(container.read(authProvider).step, AuthStep.phone);
      },
    );

    test('resend-too-soon maps to AuthError.resendTooSoon', () async {
      final api = _FakeAuthApi()
        ..nextRequestError = const OtpResendTooSoonException();
      final container = _containerWith(api);
      final notifier = container.read(authProvider.notifier);

      notifier.setPhone('5321112233');
      await notifier.sendCode();

      expect(container.read(authProvider).error, AuthError.resendTooSoon);
    });

    test('a network failure maps to AuthError.network', () async {
      final api = _FakeAuthApi()
        ..nextRequestError = const AuthNetworkException();
      final container = _containerWith(api);
      final notifier = container.read(authProvider.notifier);

      notifier.setPhone('5321112233');
      await notifier.sendCode();

      expect(container.read(authProvider).error, AuthError.network);
    });

    test('an unmapped failure maps to AuthError.server', () async {
      final api = _FakeAuthApi()..nextRequestError = Exception('boom');
      final container = _containerWith(api);
      final notifier = container.read(authProvider.notifier);

      notifier.setPhone('5321112233');
      await notifier.sendCode();

      expect(container.read(authProvider).error, AuthError.server);
    });
  });

  group('AuthNotifier — code step', () {
    test('an incomplete code is rejected locally, no api call made', () async {
      final api = _FakeAuthApi();
      final container = _containerWith(api);
      final notifier = container.read(authProvider.notifier);
      notifier.setCode('12');

      final done = await notifier.verifyCode();

      expect(done, isFalse);
      expect(container.read(authProvider).error, AuthError.codeIncomplete);
    });

    test(
      'a returning account finishes the flow and saves the session',
      () async {
        final api = _FakeAuthApi()
          ..nextSession = const AuthSession(
            accessToken: 'at',
            refreshToken: 'rt',
            userId: 'user-1',
            isNewAccount: false,
          );
        final session = _FakeSessionIdentityService();
        final container = _containerWith(api, session: session);
        final notifier = container.read(authProvider.notifier);
        notifier.setPhone('5321112233');
        notifier.setCode('123456');

        final done = await notifier.verifyCode();

        expect(done, isTrue);
        expect(session.saved?.accessToken, 'at');
        expect(
          container.read(authProvider).step,
          AuthStep.phone,
        ); // state reset
      },
    );

    test(
      'a brand-new account advances to the name step without finishing',
      () async {
        final api = _FakeAuthApi()
          ..nextSession = const AuthSession(
            accessToken: 'at',
            refreshToken: 'rt',
            userId: 'user-2',
            isNewAccount: true,
          );
        final session = _FakeSessionIdentityService();
        final container = _containerWith(api, session: session);
        final notifier = container.read(authProvider.notifier);
        notifier.setPhone('5321112233');
        notifier.setCode('123456');

        final done = await notifier.verifyCode();

        expect(done, isFalse);
        expect(container.read(authProvider).step, AuthStep.name);
        // the session is already saved even though the flow isn't finished —
        // the account genuinely exists server-side at this point.
        expect(session.saved?.userId, 'user-2');
      },
    );

    test('invalid code, expired code, too many attempts, and device '
        'conflict map to their own distinct errors', () async {
      final cases = <Object, AuthError>{
        const OtpInvalidCodeException(): AuthError.invalidCode,
        const OtpExpiredCodeException(): AuthError.expiredCode,
        const OtpTooManyAttemptsException(): AuthError.tooManyAttempts,
        const AuthDeviceConflictException(): AuthError.deviceConflict,
        const AuthNetworkException(): AuthError.network,
        Exception('boom'): AuthError.server,
      };

      for (final entry in cases.entries) {
        final api = _FakeAuthApi()..nextVerifyError = entry.key;
        final container = _containerWith(api);
        final notifier = container.read(authProvider.notifier);
        notifier.setPhone('5321112233');
        notifier.setCode('123456');

        final done = await notifier.verifyCode();

        expect(done, isFalse);
        expect(container.read(authProvider).error, entry.value);
      }
    });
  });

  group('AuthNotifier — name step', () {
    test('an empty name is rejected locally, no api call made', () async {
      final api = _FakeAuthApi();
      final container = _containerWith(api);
      final notifier = container.read(authProvider.notifier);
      notifier.setName('   ');

      final done = await notifier.submitName();

      expect(done, isFalse);
      expect(container.read(authProvider).error, AuthError.nameRequired);
      expect(api.lastDisplayName, isNull);
    });

    test('a valid name finishes the flow, trimmed', () async {
      final api = _FakeAuthApi();
      final container = _containerWith(api);
      final notifier = container.read(authProvider.notifier);
      notifier.setName('  Ayşe  ');

      final done = await notifier.submitName();

      expect(done, isTrue);
      expect(api.lastDisplayName, 'Ayşe');
    });

    test('a server-rejected name maps to AuthError.nameRequired', () async {
      final api = _FakeAuthApi()
        ..nextSetNameError = const InvalidDisplayNameException();
      final container = _containerWith(api);
      final notifier = container.read(authProvider.notifier);
      notifier.setName('Ayşe');

      final done = await notifier.submitName();

      expect(done, isFalse);
      expect(container.read(authProvider).error, AuthError.nameRequired);
    });
  });

  test('cancel resets the flow', () async {
    final api = _FakeAuthApi();
    final container = _containerWith(api);
    final notifier = container.read(authProvider.notifier);
    notifier.start(contextText: 'Bir kediyi takip etmek için giriş yap');
    notifier.setPhone('5321112233');

    notifier.cancel();

    final state = container.read(authProvider);
    expect(state.step, AuthStep.phone);
    expect(state.phone, '');
    expect(state.contextText, isNull);
  });

  test('start records the gate context text', () {
    final api = _FakeAuthApi();
    final container = _containerWith(api);
    container.read(authProvider.notifier).start(contextText: 'Giriş yap');

    expect(container.read(authProvider).contextText, 'Giriş yap');
  });
}
