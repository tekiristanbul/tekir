import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/network/api_client.dart';
import 'package:app/features/auth/data/auth_api.dart';

class _FixedStatusAdapter implements HttpClientAdapter {
  _FixedStatusAdapter(this.statusCode, {this.body = '{}'});

  final int statusCode;
  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ConnectionErrorAdapter implements HttpClientAdapter {
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

AuthApi _apiWith(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'));
  dio.httpClientAdapter = adapter;
  return AuthApi(ApiClient(dio: dio));
}

void main() {
  group('AuthApi.requestOtp error mapping', () {
    test('400 -> OtpInvalidPhoneException', () async {
      final api = _apiWith(_FixedStatusAdapter(400));
      await expectLater(
        api.requestOtp('+905321112233'),
        throwsA(isA<OtpInvalidPhoneException>()),
      );
    });

    test('429 -> OtpResendTooSoonException', () async {
      final api = _apiWith(_FixedStatusAdapter(429));
      await expectLater(
        api.requestOtp('+905321112233'),
        throwsA(isA<OtpResendTooSoonException>()),
      );
    });

    test('a connection error -> AuthNetworkException', () async {
      final api = _apiWith(_ConnectionErrorAdapter());
      await expectLater(
        api.requestOtp('+905321112233'),
        throwsA(isA<AuthNetworkException>()),
      );
    });

    test('an unmapped 5xx -> AuthServerException', () async {
      final api = _apiWith(_FixedStatusAdapter(503));
      await expectLater(
        api.requestOtp('+905321112233'),
        throwsA(isA<AuthServerException>()),
      );
    });
  });

  group('AuthApi.verifyOtp error mapping', () {
    test('401 with no distinguishing body -> OtpInvalidCodeException', () async {
      final api = _apiWith(_FixedStatusAdapter(401));
      await expectLater(
        api.verifyOtp(phone: '+905321112233', code: '000000'),
        throwsA(isA<OtpInvalidCodeException>()),
      );
    });

    test('401 with {"error":"invalid code"} -> OtpInvalidCodeException', () async {
      final api = _apiWith(
        _FixedStatusAdapter(401, body: '{"error":"invalid code"}'),
      );
      await expectLater(
        api.verifyOtp(phone: '+905321112233', code: '000000'),
        throwsA(isA<OtpInvalidCodeException>()),
      );
    });

    test(
      '401 with {"error":"missing device token"} -> AuthDeviceTokenInvalidException',
      () async {
        final api = _apiWith(
          _FixedStatusAdapter(401, body: '{"error":"missing device token"}'),
        );
        await expectLater(
          api.verifyOtp(phone: '+905321112233', code: '000000'),
          throwsA(isA<AuthDeviceTokenInvalidException>()),
        );
      },
    );

    test(
      '401 with {"error":"invalid device token"} -> AuthDeviceTokenInvalidException',
      () async {
        final api = _apiWith(
          _FixedStatusAdapter(401, body: '{"error":"invalid device token"}'),
        );
        await expectLater(
          api.verifyOtp(phone: '+905321112233', code: '000000'),
          throwsA(isA<AuthDeviceTokenInvalidException>()),
        );
      },
    );

    test('410 -> OtpExpiredCodeException', () async {
      final api = _apiWith(_FixedStatusAdapter(410));
      await expectLater(
        api.verifyOtp(phone: '+905321112233', code: '000000'),
        throwsA(isA<OtpExpiredCodeException>()),
      );
    });

    test('429 -> OtpTooManyAttemptsException', () async {
      final api = _apiWith(_FixedStatusAdapter(429));
      await expectLater(
        api.verifyOtp(phone: '+905321112233', code: '000000'),
        throwsA(isA<OtpTooManyAttemptsException>()),
      );
    });

    test('409 -> AuthDeviceConflictException', () async {
      final api = _apiWith(_FixedStatusAdapter(409));
      await expectLater(
        api.verifyOtp(phone: '+905321112233', code: '000000'),
        throwsA(isA<AuthDeviceConflictException>()),
      );
    });

    test('a successful response parses the full session', () async {
      final api = _apiWith(
        _FixedStatusAdapter(
          200,
          body:
              '{"access_token":"at","refresh_token":"rt","user_id":"u1","is_new_account":true}',
        ),
      );

      final session = await api.verifyOtp(
        phone: '+905321112233',
        code: '123456',
      );

      expect(session.accessToken, 'at');
      expect(session.refreshToken, 'rt');
      expect(session.userId, 'u1');
      expect(session.isNewAccount, isTrue);
    });
  });

  group('AuthApi.setDisplayName error mapping', () {
    test('400 -> InvalidDisplayNameException', () async {
      final api = _apiWith(_FixedStatusAdapter(400));
      await expectLater(
        api.setDisplayName(''),
        throwsA(isA<InvalidDisplayNameException>()),
      );
    });

    test('a connection error -> AuthNetworkException', () async {
      final api = _apiWith(_ConnectionErrorAdapter());
      await expectLater(
        api.setDisplayName('Ayşe'),
        throwsA(isA<AuthNetworkException>()),
      );
    });
  });
}
