import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/device_identity.dart';
import 'package:app/core/identity/session_identity.dart';

// A fixed device identity, for SessionNotifier.logout's own test group
// below — mirrors the plain-fake convention used throughout this test
// suite rather than standing up a real DeviceIdentityService.
class _FixedDeviceIdentityService implements DeviceIdentityService {
  _FixedDeviceIdentityService(this._cached);

  final DeviceIdentity? _cached;

  @override
  DeviceIdentity? get cached => _cached;

  @override
  Future<DeviceIdentity?> init() async => _cached;

  @override
  void resetFailedInit() {}

  @override
  Future<void> invalidate() async {}
}

// ── fake storage ─────────────────────────────────────────────────────────────

class _FakeStorage implements DeviceKeyValueStorage {
  final _data = <String, String>{};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

// ── fake Dio adapters ──────────────────────────────────────────────────────────

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

class _ErrorAdapter implements HttpClientAdapter {
  int callCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
    throw DioException(
      requestOptions: options,
      response: Response(requestOptions: options, statusCode: 401),
    );
  }

  @override
  void close({bool force = false}) {}
}

class _NoStoreAdapter implements HttpClientAdapter {
  int callCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
    return ResponseBody.fromString('', 204);
  }

  @override
  void close({bool force = false}) {}
}

// Captures the request headers of the last call — used to verify the
// X-Device-Token header logout() attaches (issue #80 product-owner
// review, finding 5).
class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return ResponseBody.fromString('', 204);
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'));
  dio.httpClientAdapter = adapter;
  return dio;
}

// ── tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('SessionIdentityService.restore', () {
    test('returns null (guest) when nothing is stored', () async {
      final svc = SessionIdentityService(
        storage: _FakeStorage(),
        dio: _dioWith(_ErrorAdapter()),
      );

      final identity = await svc.restore();

      expect(identity, isNull);
      expect(svc.cached, isNull);
    });

    test('rotates a stored refresh token into a fresh session', () async {
      final storage = _FakeStorage();
      storage.write('session_refresh_token', 'old-refresh');
      storage.write('session_user_id', 'user-1');
      final adapter = _FixedRefreshAdapter(
        accessToken: 'new-access',
        refreshToken: 'new-refresh',
      );
      final svc = SessionIdentityService(
        storage: storage,
        dio: _dioWith(adapter),
      );

      final identity = await svc.restore();

      expect(identity, isNotNull);
      expect(identity!.accessToken, 'new-access');
      expect(identity.refreshToken, 'new-refresh');
      expect(identity.userId, 'user-1');
      expect(await storage.read('session_refresh_token'), 'new-refresh');
    });

    test(
      'an expired/revoked refresh token clears storage and returns null',
      () async {
        final storage = _FakeStorage();
        storage.write('session_refresh_token', 'dead-refresh');
        storage.write('session_user_id', 'user-1');
        final svc = SessionIdentityService(
          storage: storage,
          dio: _dioWith(_ErrorAdapter()),
        );

        final identity = await svc.restore();

        expect(identity, isNull);
        expect(await storage.read('session_refresh_token'), isNull);
        expect(await storage.read('session_user_id'), isNull);
      },
    );

    test('concurrent restore calls share one in-flight request', () async {
      final storage = _FakeStorage();
      storage.write('session_refresh_token', 'old-refresh');
      storage.write('session_user_id', 'user-1');
      final adapter = _FixedRefreshAdapter(
        accessToken: 'new-access',
        refreshToken: 'new-refresh',
      );
      final svc = SessionIdentityService(
        storage: storage,
        dio: _dioWith(adapter),
      );

      final results = await Future.wait([
        svc.restore(),
        svc.restore(),
        svc.restore(),
      ]);

      expect(adapter.callCount, 1);
      for (final r in results) {
        expect(r?.accessToken, 'new-access');
      }
    });

    test('cached is null before restore completes, then set after', () async {
      final storage = _FakeStorage();
      storage.write('session_refresh_token', 'old-refresh');
      storage.write('session_user_id', 'user-1');
      final svc = SessionIdentityService(
        storage: storage,
        dio: _dioWith(
          _FixedRefreshAdapter(accessToken: 'a', refreshToken: 'b'),
        ),
      );

      expect(svc.cached, isNull);
      await svc.restore();
      expect(svc.cached, isNotNull);
    });
  });

  group('SessionIdentityService.save', () {
    test('persists and makes the session immediately available', () async {
      final storage = _FakeStorage();
      final svc = SessionIdentityService(
        storage: storage,
        dio: _dioWith(_ErrorAdapter()),
      );

      await svc.save(
        const SessionIdentity(
          accessToken: 'at',
          refreshToken: 'rt',
          userId: 'user-9',
        ),
      );

      expect(svc.cached?.accessToken, 'at');
      expect(await storage.read('session_access_token'), 'at');
      expect(await storage.read('session_refresh_token'), 'rt');
      expect(await storage.read('session_user_id'), 'user-9');
    });
  });

  group('SessionIdentityService.logout', () {
    test(
      'clears local state immediately even if the server call fails',
      () async {
        final storage = _FakeStorage();
        final svc = SessionIdentityService(
          storage: storage,
          dio: _dioWith(_ErrorAdapter()),
        );
        await svc.save(
          const SessionIdentity(
            accessToken: 'at',
            refreshToken: 'rt',
            userId: 'u',
          ),
        );

        await svc.logout();

        expect(svc.cached, isNull);
        expect(await storage.read('session_access_token'), isNull);
        expect(await storage.read('session_refresh_token'), isNull);
        expect(await storage.read('session_user_id'), isNull);
      },
    );

    test('is a no-op when nothing was ever saved', () async {
      final svc = SessionIdentityService(
        storage: _FakeStorage(),
        dio: _dioWith(_NoStoreAdapter()),
      );

      await svc.logout();

      expect(svc.cached, isNull);
    });

    test('never touches the device identity storage keys', () async {
      final storage = _FakeStorage();
      storage.write('device_id', 'device-1');
      storage.write('device_token', 'device-token-1');
      final svc = SessionIdentityService(
        storage: storage,
        dio: _dioWith(_NoStoreAdapter()),
      );
      await svc.save(
        const SessionIdentity(
          accessToken: 'at',
          refreshToken: 'rt',
          userId: 'u',
        ),
      );

      await svc.logout();

      expect(await storage.read('device_id'), 'device-1');
      expect(await storage.read('device_token'), 'device-token-1');
    });

    test(
      'sends X-Device-Token when a device token is passed, so the backend '
      'can unlink this installation from the account being logged out of',
      () async {
        final adapter = _CapturingAdapter();
        final svc = SessionIdentityService(
          storage: _FakeStorage(),
          dio: _dioWith(adapter),
        );
        await svc.save(
          const SessionIdentity(
            accessToken: 'at',
            refreshToken: 'rt',
            userId: 'u',
          ),
        );

        await svc.logout(deviceToken: 'device-token-1');

        expect(
          adapter.lastRequest?.headers['X-Device-Token'],
          'device-token-1',
        );
      },
    );

    test('sends no X-Device-Token when no device token is passed (still '
        'succeeds — the backend leaves the device link untouched)', () async {
      final adapter = _CapturingAdapter();
      final svc = SessionIdentityService(
        storage: _FakeStorage(),
        dio: _dioWith(adapter),
      );
      await svc.save(
        const SessionIdentity(
          accessToken: 'at',
          refreshToken: 'rt',
          userId: 'u',
        ),
      );

      await svc.logout();

      expect(
        adapter.lastRequest?.headers.containsKey('X-Device-Token'),
        isFalse,
      );
      expect(svc.cached, isNull);
    });
  });

  group('SessionNotifier.logout', () {
    test('passes the installation\'s cached device token through to '
        'SessionIdentityService.logout', () async {
      final adapter = _CapturingAdapter();
      final container = ProviderContainer(
        overrides: [
          sessionIdentityServiceProvider.overrideWithValue(
            SessionIdentityService(
              storage: _FakeStorage(),
              dio: _dioWith(adapter),
            ),
          ),
          deviceIdentityServiceProvider.overrideWithValue(
            _FixedDeviceIdentityService(
              const DeviceIdentity(
                deviceId: 'device-1',
                deviceToken: 'device-token-1',
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container
          .read(sessionProvider.notifier)
          .save(
            const SessionIdentity(
              accessToken: 'at',
              refreshToken: 'rt',
              userId: 'u',
            ),
          );

      await container.read(sessionProvider.notifier).logout();

      expect(adapter.lastRequest?.headers['X-Device-Token'], 'device-token-1');
      expect(container.read(sessionProvider).value, isNull);
    });

    test('never invalidates the device identity — only the account link is '
        'affected, server-side', () async {
      final device = _FixedDeviceIdentityService(
        const DeviceIdentity(deviceId: 'device-1', deviceToken: 'tok-1'),
      );
      final container = ProviderContainer(
        overrides: [
          sessionIdentityServiceProvider.overrideWithValue(
            SessionIdentityService(
              storage: _FakeStorage(),
              dio: _dioWith(_NoStoreAdapter()),
            ),
          ),
          deviceIdentityServiceProvider.overrideWithValue(device),
        ],
      );
      addTearDown(container.dispose);
      await container
          .read(sessionProvider.notifier)
          .save(
            const SessionIdentity(
              accessToken: 'at',
              refreshToken: 'rt',
              userId: 'u',
            ),
          );

      await container.read(sessionProvider.notifier).logout();

      expect(device.cached?.deviceToken, 'tok-1');
    });
  });
}
