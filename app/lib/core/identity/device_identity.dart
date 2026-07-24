import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/env.dart';

// Storage keys for the persisted device credential.
const _keyDeviceId = 'device_id';
const _keyDeviceToken = 'device_token';

/// The non-secret portion of an anonymous device identity, plus the opaque
/// bearer secret needed to attach it to requests. Both are returned once by
/// the server and stored in secure storage; the raw token is never logged.
class DeviceIdentity {
  const DeviceIdentity({required this.deviceId, required this.deviceToken});

  final String deviceId;
  final String deviceToken;
}

/// A minimal key/value storage abstraction so [DeviceIdentityService] stays
/// testable without a real platform channel. The production implementation
/// wraps [FlutterSecureStorage]; tests supply an in-memory fake.
abstract class DeviceKeyValueStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// Production adapter that delegates to [FlutterSecureStorage].
class FlutterSecureKeyValueStorage implements DeviceKeyValueStorage {
  const FlutterSecureKeyValueStorage(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

/// Manages the anonymous device identity lifecycle:
///
/// - reads from secure storage on first access,
/// - calls `POST /v1/devices` when no credential is stored yet,
/// - persists both values only after a valid server response,
/// - ensures concurrent first-use calls in one process share one registration.
///
/// Uses its own [Dio] instance (not the intercepted api client) so that
/// registration never recursively waits for the credential it is creating.
class DeviceIdentityService {
  DeviceIdentityService({required this._storage, required this._dio});

  final DeviceKeyValueStorage _storage;
  final Dio _dio;

  // Cached result once initialization succeeds.
  DeviceIdentity? _cached;

  // Single in-flight initialization future; concurrent callers share this.
  Future<DeviceIdentity?>? _initFuture;

  /// Returns the current identity (from cache, storage, or a fresh
  /// registration). Concurrent calls in one isolate share a single in-flight
  /// registration. Returns `null` if registration or storage fails — read-only
  /// browsing must continue unaffected.
  Future<DeviceIdentity?> init() {
    if (_cached != null) return Future.value(_cached);
    _initFuture ??= _loadOrRegister().then(
      (id) {
        _cached = id;
        return id;
      },
      onError: (Object _) {
        // Clear the future so a controlled retry is possible later.
        _initFuture = null;
        return null;
      },
    );
    return _initFuture!;
  }

  /// Returns the cached identity without waiting for initialization. The
  /// [DeviceInterceptor] calls this synchronously on each request so it can
  /// attach the token when available without blocking the request pipeline.
  DeviceIdentity? get cached => _cached;

  /// Clears the in-flight future so the next [init] call retries. Does not
  /// clear the cached result — a successful identity is stable for the
  /// process lifetime. Exposed for future write-flow retry logic.
  void resetFailedInit() {
    if (_cached == null) _initFuture = null;
  }

  Future<DeviceIdentity?> _loadOrRegister() async {
    final storedId = await _storage.read(_keyDeviceId);
    final storedToken = await _storage.read(_keyDeviceToken);

    if (storedId != null && storedToken != null) {
      return DeviceIdentity(deviceId: storedId, deviceToken: storedToken);
    }

    // Register with the backend. Use its own Dio so there is no circular
    // dependency on the intercepted api client.
    final response = await _dio.post<Map<String, dynamic>>(
      '/v1/devices',
      data: {'platform': _currentPlatform()},
    );

    final body = response.data;
    if (body == null) return null;

    final deviceId = body['device_id'] as String?;
    final deviceToken = body['device_token'] as String?;
    if (deviceId == null || deviceToken == null) return null;

    // Persist only after a valid response so a partial write never
    // leaves the client with an orphaned id but no token.
    await _storage.write(_keyDeviceId, deviceId);
    await _storage.write(_keyDeviceToken, deviceToken);

    return DeviceIdentity(deviceId: deviceId, deviceToken: deviceToken);
  }

  static String _currentPlatform() {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'ios',
      _ => 'android',
    };
  }
}

/// Provides the [DeviceIdentityService] as a singleton. The service uses its
/// own [Dio] instance (not the intercepted api client) for registration.
final deviceIdentityServiceProvider = Provider<DeviceIdentityService>((ref) {
  return DeviceIdentityService(
    storage: const FlutterSecureKeyValueStorage(FlutterSecureStorage()),
    dio: Dio(
      BaseOptions(
        baseUrl: Env.apiBaseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ),
    ),
  );
});

/// Asynchronously initializes the device identity once per process. Returns
/// the [DeviceIdentity] on success or `null` when initialization fails.
/// Read-only browsing must remain available regardless of the result.
final deviceIdentityProvider = FutureProvider<DeviceIdentity?>((ref) async {
  return ref.watch(deviceIdentityServiceProvider).init();
});
