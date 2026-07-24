import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/device_identity.dart';

// ── fake storage ─────────────────────────────────────────────────────────────

class _FakeStorage implements DeviceKeyValueStorage {
  final _data = <String, String>{};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;
}

// ── fake Dio that returns a canned response ───────────────────────────────────

class _FakeDioAdapter implements HttpClientAdapter {
  _FakeDioAdapter({required this.statusCode, required this.body});

  final int statusCode;
  final Map<String, dynamic> body;

  int callCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
    return ResponseBody.fromString(
      _encodeJson(body),
      statusCode,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ErrorDioAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(requestOptions: options, message: 'network error');
  }

  @override
  void close({bool force = false}) {}
}

String _encodeJson(Map<String, dynamic> m) {
  final entries = m.entries
      .map((e) {
        final val = e.value is String ? '"${e.value}"' : '${e.value}';
        return '"${e.key}":$val';
      })
      .join(',');
  return '{$entries}';
}

Dio _fakeDio(_FakeDioAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'));
  dio.httpClientAdapter = adapter;
  return dio;
}

Dio _errorDio() {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'));
  dio.httpClientAdapter = _ErrorDioAdapter();
  return dio;
}

// ── tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('DeviceIdentityService', () {
    test('registers and persists when storage is empty', () async {
      final storage = _FakeStorage();
      final adapter = _FakeDioAdapter(
        statusCode: 201,
        body: {'device_id': 'did-123', 'device_token': 'tok-abc'},
      );
      final svc = DeviceIdentityService(
        storage: storage,
        dio: _fakeDio(adapter),
      );

      final identity = await svc.init();

      expect(identity, isNotNull);
      expect(identity!.deviceId, 'did-123');
      expect(identity.deviceToken, 'tok-abc');
      expect(storage._data['device_id'], 'did-123');
      expect(storage._data['device_token'], 'tok-abc');
    });

    test('reuses stored identity without calling the api', () async {
      final storage = _FakeStorage();
      storage._data['device_id'] = 'existing-did';
      storage._data['device_token'] = 'existing-tok';

      final adapter = _FakeDioAdapter(
        statusCode: 201,
        body: {'device_id': 'new-did', 'device_token': 'new-tok'},
      );
      final svc = DeviceIdentityService(
        storage: storage,
        dio: _fakeDio(adapter),
      );

      final identity = await svc.init();

      expect(identity!.deviceId, 'existing-did');
      expect(identity.deviceToken, 'existing-tok');
      // No network call should have been made.
      expect(adapter.callCount, 0);
    });

    test('concurrent init calls share one registration request', () async {
      final storage = _FakeStorage();
      // Use a completer so we control when the response resolves.
      final completer = Completer<ResponseBody>();

      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'));
      int networkCalls = 0;
      dio.httpClientAdapter = _BlockingAdapter(completer, () => networkCalls++);

      final svc = DeviceIdentityService(storage: storage, dio: dio);

      // Fire two concurrent init calls.
      final f1 = svc.init();
      final f2 = svc.init();

      // Resolve the pending request.
      completer.complete(
        ResponseBody.fromString(
          '{"device_id":"did-c","device_token":"tok-c"}',
          201,
          headers: {
            'content-type': ['application/json'],
          },
        ),
      );

      final r1 = await f1;
      final r2 = await f2;

      expect(networkCalls, 1, reason: 'only one registration request allowed');
      expect(r1!.deviceId, 'did-c');
      expect(r2!.deviceId, 'did-c');
    });

    test(
      'cached identity returned synchronously after init succeeds',
      () async {
        final storage = _FakeStorage();
        final adapter = _FakeDioAdapter(
          statusCode: 201,
          body: {'device_id': 'did-d', 'device_token': 'tok-d'},
        );
        final svc = DeviceIdentityService(
          storage: storage,
          dio: _fakeDio(adapter),
        );

        await svc.init();

        expect(svc.cached, isNotNull);
        expect(svc.cached!.deviceId, 'did-d');
      },
    );

    test('cached is null before init completes', () async {
      final storage = _FakeStorage();
      final svc = DeviceIdentityService(storage: storage, dio: _errorDio());

      expect(svc.cached, isNull);
    });

    test(
      'registration failure returns null and leaves browsing available',
      () async {
        final svc = DeviceIdentityService(
          storage: _FakeStorage(),
          dio: _errorDio(),
        );

        final identity = await svc.init();
        expect(identity, isNull);
        expect(svc.cached, isNull);
      },
    );

    test('malformed response returns null without crashing', () async {
      final storage = _FakeStorage();
      final adapter = _FakeDioAdapter(
        statusCode: 201,
        body: {'unexpected': 'shape'},
      );
      final svc = DeviceIdentityService(
        storage: storage,
        dio: _fakeDio(adapter),
      );

      final identity = await svc.init();
      expect(identity, isNull);
    });

    test('resetFailedInit allows a retry after failure', () async {
      int callCount = 0;
      final storage = _FakeStorage();
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'));

      // First call: fail; second call: succeed.
      _CountingAdapter? adapter;
      adapter = _CountingAdapter(
        onCall: () {
          callCount++;
          if (callCount == 1) {
            throw DioException(
              requestOptions: RequestOptions(),
              message: 'fail',
            );
          }
          return ResponseBody.fromString(
            '{"device_id":"did-r","device_token":"tok-r"}',
            201,
            headers: {
              'content-type': ['application/json'],
            },
          );
        },
      );
      dio.httpClientAdapter = adapter;

      final svc = DeviceIdentityService(storage: storage, dio: dio);

      final first = await svc.init();
      expect(first, isNull);

      svc.resetFailedInit();

      final second = await svc.init();
      expect(second, isNotNull);
      expect(second!.deviceId, 'did-r');
    });

    test('persists only after a complete valid response', () async {
      final storage = _FakeStorage();
      final adapter = _FakeDioAdapter(
        statusCode: 201,
        body: {'unexpected': 'shape'},
      );
      final svc = DeviceIdentityService(
        storage: storage,
        dio: _fakeDio(adapter),
      );

      await svc.init();

      // Nothing should have been written to storage on a malformed response.
      expect(storage._data.containsKey('device_id'), isFalse);
      expect(storage._data.containsKey('device_token'), isFalse);
    });
  });
}

// ── adapter helpers ───────────────────────────────────────────────────────────

class _BlockingAdapter implements HttpClientAdapter {
  _BlockingAdapter(this._completer, this._onCall);

  final Completer<ResponseBody> _completer;
  final void Function() _onCall;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _onCall();
    return _completer.future;
  }

  @override
  void close({bool force = false}) {}
}

class _CountingAdapter implements HttpClientAdapter {
  _CountingAdapter({required this.onCall});

  final ResponseBody Function() onCall;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return onCall();
  }

  @override
  void close({bool force = false}) {}
}
