import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/device_identity.dart';
import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/network/bearer_interceptor.dart';
import 'package:app/core/network/session_refresh_interceptor.dart';

// Builds a minimally-shaped access token jwt — unsigned, since
// refreshIfExpired only ever reads the `exp` claim locally and never
// verifies the signature. Mirrors session_identity_service_test.dart's
// identical helper.
String _jwt({required Duration expiresIn}) {
  String segment(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final header = segment({'alg': 'HS256', 'typ': 'JWT'});
  final exp = DateTime.now().add(expiresIn).millisecondsSinceEpoch ~/ 1000;
  final payload = segment({'sub': 'user-1', 'exp': exp});
  return '$header.$payload.sig';
}

class _FakeStorage implements DeviceKeyValueStorage {
  final _data = <String, String>{};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

// Answers SessionIdentityService's own rotation Dio with a fixed fresh
// token pair — mirrors session_identity_service_test.dart's identical fake.
class _FixedRefreshAdapter implements HttpClientAdapter {
  _FixedRefreshAdapter({required this.accessToken, required this.refreshToken});

  final String accessToken;
  final String refreshToken;
  int callCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
    return ResponseBody.fromString(
      '{"access_token":"$accessToken","refresh_token":"$refreshToken"}',
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

// Answers a fixed sequence of status codes to the api Dio under test — the
// last entry repeats for any call past the sequence's length. Every real
// HTTP status (not a thrown transport error) so Dio's own default
// validateStatus is what turns a 401 into a DioException, exactly like a
// real backend response would.
class _StatusSequenceAdapter implements HttpClientAdapter {
  _StatusSequenceAdapter(this.statusCodes);

  final List<int> statusCodes;
  int callCount = 0;
  final capturedOptions = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    capturedOptions.add(options);
    final status = callCount < statusCodes.length
        ? statusCodes[callCount]
        : statusCodes.last;
    callCount++;
    return ResponseBody.fromString(
      '{}',
      status,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const apiBaseUrl = 'http://localhost:8080';

  group('SessionRefreshInterceptor', () {
    test('refreshes an expired session and retries the original request once, '
        'resolving with the retried response', () async {
      final refreshAdapter = _FixedRefreshAdapter(
        accessToken: 'new-access',
        refreshToken: 'new-refresh',
      );
      final svc = SessionIdentityService(
        storage: _FakeStorage(),
        dio: Dio(BaseOptions(baseUrl: apiBaseUrl))
          ..httpClientAdapter = refreshAdapter,
      );
      await svc.save(
        SessionIdentity(
          accessToken: _jwt(expiresIn: const Duration(minutes: -1)),
          refreshToken: 'old-refresh',
          userId: 'u',
        ),
      );

      final apiAdapter = _StatusSequenceAdapter([401, 200]);
      final dio = Dio(BaseOptions(baseUrl: apiBaseUrl))
        ..httpClientAdapter = apiAdapter;
      dio.interceptors.add(
        BearerInterceptor(service: svc, apiBaseUrl: apiBaseUrl),
      );
      dio.interceptors.add(
        SessionRefreshInterceptor(
          dio: dio,
          service: svc,
          apiBaseUrl: apiBaseUrl,
        ),
      );

      final response = await dio.get<void>('/v1/cats/cat-1/updates');

      expect(response.statusCode, 200);
      expect(
        apiAdapter.callCount,
        2,
        reason: 'the original attempt plus exactly one retry',
      );
      expect(
        apiAdapter.capturedOptions[1].headers['Authorization'],
        'Bearer new-access',
        reason: 'the retry must carry the freshly rotated token',
      );
      expect(svc.cached?.accessToken, 'new-access');
    });

    test('surfaces the original error when a request still 401s after a '
        'successful refresh, without a second retry', () async {
      final refreshAdapter = _FixedRefreshAdapter(
        accessToken: 'new-access',
        refreshToken: 'new-refresh',
      );
      final svc = SessionIdentityService(
        storage: _FakeStorage(),
        dio: Dio(BaseOptions(baseUrl: apiBaseUrl))
          ..httpClientAdapter = refreshAdapter,
      );
      await svc.save(
        SessionIdentity(
          accessToken: _jwt(expiresIn: const Duration(minutes: -1)),
          refreshToken: 'old-refresh',
          userId: 'u',
        ),
      );

      final apiAdapter = _StatusSequenceAdapter([401, 401, 401]);
      final dio = Dio(BaseOptions(baseUrl: apiBaseUrl))
        ..httpClientAdapter = apiAdapter;
      dio.interceptors.add(
        BearerInterceptor(service: svc, apiBaseUrl: apiBaseUrl),
      );
      dio.interceptors.add(
        SessionRefreshInterceptor(
          dio: dio,
          service: svc,
          apiBaseUrl: apiBaseUrl,
        ),
      );

      await expectLater(
        dio.get<void>('/v1/cats/cat-1/updates'),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
      expect(
        apiAdapter.callCount,
        2,
        reason: 'exactly one retry attempt, never a storm',
      );
    });

    test('does not attempt a refresh for a non-401 error', () async {
      final refreshAdapter = _FixedRefreshAdapter(
        accessToken: 'unused',
        refreshToken: 'unused',
      );
      final svc = SessionIdentityService(
        storage: _FakeStorage(),
        dio: Dio(BaseOptions(baseUrl: apiBaseUrl))
          ..httpClientAdapter = refreshAdapter,
      );
      await svc.save(
        SessionIdentity(
          accessToken: _jwt(expiresIn: const Duration(minutes: -1)),
          refreshToken: 'old-refresh',
          userId: 'u',
        ),
      );

      final apiAdapter = _StatusSequenceAdapter([500]);
      final dio = Dio(BaseOptions(baseUrl: apiBaseUrl))
        ..httpClientAdapter = apiAdapter;
      dio.interceptors.add(
        SessionRefreshInterceptor(
          dio: dio,
          service: svc,
          apiBaseUrl: apiBaseUrl,
        ),
      );

      await expectLater(dio.get<void>('/v1/me'), throwsA(isA<DioException>()));
      expect(apiAdapter.callCount, 1);
      expect(refreshAdapter.callCount, 0);
    });

    test('does not attempt a refresh when no session is cached', () async {
      final refreshAdapter = _FixedRefreshAdapter(
        accessToken: 'unused',
        refreshToken: 'unused',
      );
      final svc = SessionIdentityService(
        storage: _FakeStorage(),
        dio: Dio(BaseOptions(baseUrl: apiBaseUrl))
          ..httpClientAdapter = refreshAdapter,
      );

      final apiAdapter = _StatusSequenceAdapter([401]);
      final dio = Dio(BaseOptions(baseUrl: apiBaseUrl))
        ..httpClientAdapter = apiAdapter;
      dio.interceptors.add(
        SessionRefreshInterceptor(
          dio: dio,
          service: svc,
          apiBaseUrl: apiBaseUrl,
        ),
      );

      await expectLater(dio.get<void>('/v1/me'), throwsA(isA<DioException>()));
      expect(apiAdapter.callCount, 1);
      expect(refreshAdapter.callCount, 0);
    });

    test(
      'does not attempt a refresh for a 401 from a different origin',
      () async {
        final refreshAdapter = _FixedRefreshAdapter(
          accessToken: 'unused',
          refreshToken: 'unused',
        );
        final svc = SessionIdentityService(
          storage: _FakeStorage(),
          dio: Dio(BaseOptions(baseUrl: apiBaseUrl))
            ..httpClientAdapter = refreshAdapter,
        );
        await svc.save(
          SessionIdentity(
            accessToken: _jwt(expiresIn: const Duration(minutes: -1)),
            refreshToken: 'old-refresh',
            userId: 'u',
          ),
        );

        final apiAdapter = _StatusSequenceAdapter([401]);
        final dio = Dio(BaseOptions())..httpClientAdapter = apiAdapter;
        dio.interceptors.add(
          SessionRefreshInterceptor(
            dio: dio,
            service: svc,
            apiBaseUrl: apiBaseUrl,
          ),
        );

        await expectLater(
          dio.get<void>('http://other-host.example.com/some-path'),
          throwsA(isA<DioException>()),
        );
        expect(apiAdapter.callCount, 1);
        expect(refreshAdapter.callCount, 0);
      },
    );

    test('gives up without a retry when the local token still looks fresh '
        '(refreshIfExpired no-ops)', () async {
      final refreshAdapter = _FixedRefreshAdapter(
        accessToken: 'unused',
        refreshToken: 'unused',
      );
      final svc = SessionIdentityService(
        storage: _FakeStorage(),
        dio: Dio(BaseOptions(baseUrl: apiBaseUrl))
          ..httpClientAdapter = refreshAdapter,
      );
      final fresh = _jwt(expiresIn: const Duration(minutes: 15));
      await svc.save(
        SessionIdentity(accessToken: fresh, refreshToken: 'rt', userId: 'u'),
      );

      final apiAdapter = _StatusSequenceAdapter([401]);
      final dio = Dio(BaseOptions(baseUrl: apiBaseUrl))
        ..httpClientAdapter = apiAdapter;
      dio.interceptors.add(
        BearerInterceptor(service: svc, apiBaseUrl: apiBaseUrl),
      );
      dio.interceptors.add(
        SessionRefreshInterceptor(
          dio: dio,
          service: svc,
          apiBaseUrl: apiBaseUrl,
        ),
      );

      await expectLater(dio.get<void>('/v1/me'), throwsA(isA<DioException>()));
      expect(
        apiAdapter.callCount,
        1,
        reason: 'no retry — the same unchanged token would just 401 again',
      );
      expect(refreshAdapter.callCount, 0);
    });
  });
}
