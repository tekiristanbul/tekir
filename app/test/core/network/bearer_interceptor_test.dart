import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/device_identity.dart';
import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/network/bearer_interceptor.dart';

class _FakeStorage implements DeviceKeyValueStorage {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? lastOptions;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    return ResponseBody.fromString('{}', 200);
  }

  @override
  void close({bool force = false}) {}
}

class _FixedRefreshAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '{"access_token":"at","refresh_token":"rt"}',
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<SessionIdentityService> _buildServiceWithSession(
  SessionIdentity identity,
) async {
  final storage = _FakeStorage();
  final svc = SessionIdentityService(
    storage: storage,
    dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080'))
      ..httpClientAdapter = _FixedRefreshAdapter(),
  );
  await svc.save(identity);
  return svc;
}

void main() {
  const apiBaseUrl = 'http://localhost:8080';

  group('BearerInterceptor', () {
    test('attaches Authorization: Bearer when a session is cached', () async {
      const identity = SessionIdentity(
        accessToken: 'access-tok',
        refreshToken: 'refresh-tok',
        userId: 'user-1',
      );
      final svc = await _buildServiceWithSession(identity);
      final capturing = _CapturingAdapter();

      final dio = Dio(BaseOptions(baseUrl: apiBaseUrl));
      dio.interceptors.add(
        BearerInterceptor(service: svc, apiBaseUrl: apiBaseUrl),
      );
      dio.httpClientAdapter = capturing;

      await dio.get<void>('/v1/me');

      expect(
        capturing.lastOptions?.headers['Authorization'],
        'Bearer access-tok',
      );
    });

    test('does not attach a header when no session is cached', () async {
      final svc = SessionIdentityService(
        storage: _FakeStorage(),
        dio: Dio(BaseOptions(baseUrl: apiBaseUrl))
          ..httpClientAdapter = _CapturingAdapter(),
      );

      final capturing = _CapturingAdapter();
      final dio = Dio(BaseOptions(baseUrl: apiBaseUrl));
      dio.interceptors.add(
        BearerInterceptor(service: svc, apiBaseUrl: apiBaseUrl),
      );
      dio.httpClientAdapter = capturing;

      await dio.get<void>('/v1/me');

      expect(
        capturing.lastOptions?.headers.containsKey('Authorization'),
        isFalse,
      );
    });

    test(
      'does not attach the header to requests targeting a different origin',
      () async {
        const identity = SessionIdentity(
          accessToken: 'access-tok',
          refreshToken: 'refresh-tok',
          userId: 'user-1',
        );
        final svc = await _buildServiceWithSession(identity);
        final capturing = _CapturingAdapter();

        final dio = Dio(BaseOptions());
        dio.interceptors.add(
          BearerInterceptor(service: svc, apiBaseUrl: apiBaseUrl),
        );
        dio.httpClientAdapter = capturing;

        await dio.get<void>('http://other-host.example.com/some-path');

        expect(
          capturing.lastOptions?.headers.containsKey('Authorization'),
          isFalse,
        );
      },
    );
  });
}
