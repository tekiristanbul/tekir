import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/device_identity.dart';
import 'package:app/core/network/device_interceptor.dart';

// ── fake storage ──────────────────────────────────────────────────────────────

class _FakeStorage implements DeviceKeyValueStorage {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

// ── fake Dio adapter that captures request options ────────────────────────────

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

// ── helper: build a service with a pre-cached identity ───────────────────────

Future<DeviceIdentityService> _buildServiceWithIdentity(
  DeviceIdentity identity,
) async {
  final storage = _FakeStorage();
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'));
  dio.httpClientAdapter = _FixedAdapter(identity);
  final svc = DeviceIdentityService(storage: storage, dio: dio);
  await svc.init();
  return svc;
}

class _FixedAdapter implements HttpClientAdapter {
  _FixedAdapter(this._identity);

  final DeviceIdentity _identity;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '{"device_id":"${_identity.deviceId}","device_token":"${_identity.deviceToken}"}',
      201,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

// ── tests ─────────────────────────────────────────────────────────────────────

void main() {
  const apiBaseUrl = 'http://localhost:8080';

  group('DeviceInterceptor', () {
    test('attaches X-Device-Token when identity is cached', () async {
      const identity = DeviceIdentity(deviceId: 'did', deviceToken: 'tok');
      final svc = await _buildServiceWithIdentity(identity);
      final capturing = _CapturingAdapter();

      final dio = Dio(BaseOptions(baseUrl: apiBaseUrl));
      dio.interceptors.add(
        DeviceInterceptor(service: svc, apiBaseUrl: apiBaseUrl),
      );
      dio.httpClientAdapter = capturing;

      await dio.get<void>('/v1/cats?bbox=28,41,29,42');

      expect(
        capturing.lastOptions?.headers['X-Device-Token'],
        'tok',
        reason: 'token must be attached for api requests',
      );
    });

    test('does not attach token when no identity is cached', () async {
      // Service is never init()-ed so cached remains null.
      final svc = DeviceIdentityService(
        storage: _FakeStorage(),
        dio: Dio(BaseOptions(baseUrl: apiBaseUrl))
          ..httpClientAdapter = _CapturingAdapter(),
      );

      final capturing = _CapturingAdapter();
      final dio = Dio(BaseOptions(baseUrl: apiBaseUrl));
      dio.interceptors.add(
        DeviceInterceptor(service: svc, apiBaseUrl: apiBaseUrl),
      );
      dio.httpClientAdapter = capturing;

      await dio.get<void>('/v1/cats?bbox=28,41,29,42');

      expect(
        capturing.lastOptions?.headers.containsKey('X-Device-Token'),
        isFalse,
        reason: 'no token must be attached when identity is unavailable',
      );
    });

    test(
      'does not attach token to requests targeting a different origin',
      () async {
        const identity = DeviceIdentity(deviceId: 'did', deviceToken: 'tok');
        final svc = await _buildServiceWithIdentity(identity);
        final capturing = _CapturingAdapter();

        final dio = Dio(BaseOptions());
        dio.interceptors.add(
          DeviceInterceptor(service: svc, apiBaseUrl: apiBaseUrl),
        );
        dio.httpClientAdapter = capturing;

        await dio.get<void>('http://other-host.example.com/some-path');

        expect(
          capturing.lastOptions?.headers.containsKey('X-Device-Token'),
          isFalse,
          reason: 'token must not be sent to a different origin',
        );
      },
    );

    test(
      'registration Dio bypass: POST /v1/devices does not carry X-Device-Token',
      () async {
        // The registration Dio inside DeviceIdentityService is a separate instance
        // with no interceptors. We verify that the registration request itself never
        // carries an X-Device-Token header (which would be circular / wrong).
        final registrationCapturing = _CapturingAdapter();
        final registrationDio = Dio(BaseOptions(baseUrl: apiBaseUrl));
        registrationDio.httpClientAdapter = _InspectingFixedAdapter(
          identity: const DeviceIdentity(
            deviceId: 'did-bypass',
            deviceToken: 'tok-bypass',
          ),
          capturing: registrationCapturing,
        );

        final svc = DeviceIdentityService(
          storage: _FakeStorage(),
          dio: registrationDio,
        );
        await svc.init();

        final opts = registrationCapturing.lastOptions;
        expect(opts, isNotNull);
        expect(
          opts!.headers.containsKey('X-Device-Token'),
          isFalse,
          reason: 'registration request must not carry a device token',
        );
      },
    );
  });
}

class _InspectingFixedAdapter implements HttpClientAdapter {
  _InspectingFixedAdapter({required this.identity, required this.capturing});

  final DeviceIdentity identity;
  final _CapturingAdapter capturing;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    capturing.lastOptions = options;
    return ResponseBody.fromString(
      '{"device_id":"${identity.deviceId}","device_token":"${identity.deviceToken}"}',
      201,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
