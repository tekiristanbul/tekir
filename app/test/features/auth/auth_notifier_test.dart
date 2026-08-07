import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/device_identity.dart';
import 'package:app/core/identity/session_identity.dart';
import 'package:app/features/auth/data/auth_api.dart';
import 'package:app/features/auth/ui/auth_notifier.dart';
import 'package:app/features/badges/data/badge.dart';
import 'package:app/features/profile/data/profile.dart';
import 'package:app/features/profile/data/profile_api.dart';
import 'package:app/features/profile/ui/profile_notifier.dart';

// Mirrors cat_update_composer_notifier_test.dart's fakes exactly — same
// stale-device-credential recovery mechanism, applied here to the login
// flow instead of the update composer.
class _FakeDeviceStorage implements DeviceKeyValueStorage {
  final _data = <String, String>{'device_id': 'did-1', 'device_token': 'tok-1'};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

class _EmptyDeviceStorage implements DeviceKeyValueStorage {
  final _data = <String, String>{};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

class _FailingRegistrationAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      message: 'connection refused',
    );
  }

  @override
  void close({bool force = false}) {}
}

class _CountingRegistrationAdapter implements HttpClientAdapter {
  int callCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
    return ResponseBody.fromString(
      '{"device_id":"did-fresh-$callCount","device_token":"tok-fresh-$callCount"}',
      201,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

DeviceIdentityService _defaultDeviceIdentityService() => DeviceIdentityService(
  storage: _FakeDeviceStorage(),
  dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080')),
);

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
  Future<SessionIdentity?> refreshIfExpired() async => _cached;

  @override
  Future<void> save(SessionIdentity identity) async {
    saved = identity;
    _cached = identity;
  }

  @override
  Future<void> logout({String? deviceToken}) async {
    logoutCalls++;
    _cached = null;
  }
}

ProviderContainer _containerWith(
  _FakeAuthApi api, {
  _FakeSessionIdentityService? session,
  DeviceIdentityService? deviceIdentityService,
  ProfileApi? profileApi,
}) {
  final container = ProviderContainer(
    overrides: [
      authApiProvider.overrideWithValue(api),
      sessionIdentityServiceProvider.overrideWithValue(
        session ?? _FakeSessionIdentityService(),
      ),
      deviceIdentityServiceProvider.overrideWithValue(
        deviceIdentityService ?? _defaultDeviceIdentityService(),
      ),
      if (profileApi != null) profileApiProvider.overrideWithValue(profileApi),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

class _FakeProfileApi implements ProfileApi {
  _FakeProfileApi(this.profile);
  Profile profile;

  @override
  Future<Profile> fetch() async => profile;
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

    test(
      'a stale device credential invalidates and re-registers on the next attempt',
      () async {
        final storage = _FakeDeviceStorage(); // pre-populated with did-1/tok-1
        final registrationAdapter = _CountingRegistrationAdapter();
        final deviceService = DeviceIdentityService(
          storage: storage,
          dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080'))
            ..httpClientAdapter = registrationAdapter,
        );
        final api = _FakeAuthApi()
          ..nextVerifyError = const AuthDeviceTokenInvalidException();
        final container = _containerWith(
          api,
          deviceIdentityService: deviceService,
        );
        final notifier = container.read(authProvider.notifier);
        notifier.setPhone('5321112233');
        notifier.setCode('123456');

        final firstDone = await notifier.verifyCode();

        expect(firstDone, isFalse);
        expect(
          container.read(authProvider).error,
          AuthError.staleDeviceCredential,
        );
        expect(container.read(authProvider).isSubmitting, isFalse);
        expect(authErrorMessageTr(AuthError.staleDeviceCredential), isNotEmpty);
        expect(
          deviceService.cached,
          isNull,
          reason: 'stale credential dropped',
        );
        expect(storage._data.containsKey('device_token'), isFalse);
        expect(
          registrationAdapter.callCount,
          0,
          reason: 'invalidate() only clears state, it does not re-register',
        );

        // Retryable: a following successful attempt re-registers first.
        api
          ..nextVerifyError = null
          ..nextSession = const AuthSession(
            accessToken: 'at',
            refreshToken: 'rt',
            userId: 'user-1',
            isNewAccount: false,
          );
        final secondDone = await notifier.verifyCode();

        expect(secondDone, isTrue);
        expect(container.read(authProvider).error, isNull);
        expect(
          registrationAdapter.callCount,
          1,
          reason: 'stale credential must not be replayed; a fresh one is used',
        );
      },
    );

    test(
      'a device identity init() failure maps to AuthError.network, no verify api call',
      () async {
        final deviceService = DeviceIdentityService(
          storage: _EmptyDeviceStorage(),
          dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080'))
            ..httpClientAdapter = _FailingRegistrationAdapter(),
        );
        final api = _FakeAuthApi()
          ..nextSession = const AuthSession(
            accessToken: 'at',
            refreshToken: 'rt',
            userId: 'user-1',
            isNewAccount: false,
          );
        final container = _containerWith(
          api,
          deviceIdentityService: deviceService,
        );
        final notifier = container.read(authProvider.notifier);
        notifier.setPhone('5321112233');
        notifier.setCode('123456');

        final done = await notifier.verifyCode();

        expect(done, isFalse);
        expect(container.read(authProvider).error, AuthError.network);
        expect(container.read(authProvider).isSubmitting, isFalse);
        expect(
          api.lastVerifiedPhone,
          isNull,
          reason: 'a doomed no-device-token request must never be sent',
        );
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

    test(
      'a name over 60 chars is rejected locally, no api call made',
      () async {
        final api = _FakeAuthApi();
        final container = _containerWith(api);
        final notifier = container.read(authProvider.notifier);
        notifier.setName('a' * 61);

        final done = await notifier.submitName();

        expect(done, isFalse);
        expect(container.read(authProvider).error, AuthError.nameTooLong);
        expect(api.lastDisplayName, isNull);
      },
    );

    test('a name at exactly 60 chars is accepted', () async {
      final api = _FakeAuthApi();
      final container = _containerWith(api);
      final notifier = container.read(authProvider.notifier);
      notifier.setName('a' * 60);

      final done = await notifier.submitName();

      expect(done, isTrue);
      expect(api.lastDisplayName, 'a' * 60);
    });

    test('reflects the new name into an already-loaded profileProvider — a '
        'brand-new account\'s profile can load (with a null name) in the gap '
        'between otp/verify and this step\'s own save (issue #80 '
        'product-owner review)', () async {
      final api = _FakeAuthApi();
      final profileApi = _FakeProfileApi(
        Profile(
          displayName: null,
          totals: const ContributionTotals(
            updates: 0,
            helps: 0,
            catsAdded: 0,
            distinctCats: 0,
          ),
          badges: const <BadgeStatus>[],
          recentContributions: const [],
        ),
      );
      final container = _containerWith(api, profileApi: profileApi);
      await container.read(profileProvider.notifier).load();
      expect(container.read(profileProvider).profile?.displayName, isNull);

      final notifier = container.read(authProvider.notifier);
      notifier.setName('Ayşe');
      final done = await notifier.submitName();

      expect(done, isTrue);
      expect(container.read(profileProvider).profile?.displayName, 'Ayşe');
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
