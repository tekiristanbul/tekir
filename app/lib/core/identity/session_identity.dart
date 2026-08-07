import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/env.dart';
import 'device_identity.dart';

// Storage keys for the persisted authenticated session. Distinct from the
// device identity's keys (device_id/device_token) — a session is an
// account credential, not an installation credential, and the two must be
// cleared independently (logout drops only these; it never touches the
// device identity).
const _keyAccessToken = 'session_access_token';
const _keyRefreshToken = 'session_refresh_token';
const _keyUserId = 'session_user_id';

/// An authenticated account session (issue #58): the short-lived jwt
/// [accessToken], the long-lived, rotating [refreshToken], and the
/// account's [userId]. All three are returned once by the server —
/// `refresh_token` and `access_token` are never logged.
class SessionIdentity {
  const SessionIdentity({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
  });

  final String accessToken;
  final String refreshToken;
  final String userId;
}

/// Manages the authenticated session lifecycle:
///
/// - restores a previously issued session by rotating the stored refresh
///   token on app start ([restore]),
/// - persists a fresh session after a successful otp verification ([save]),
/// - revokes and clears the session on logout ([logout]) — the device
///   identity itself is never touched by any of these.
///
/// Uses its own [Dio] instance (not the intercepted api client) so that
/// refreshing never recursively depends on the [BearerInterceptor] it is
/// refreshing the credential for — mirrors [DeviceIdentityService].
class SessionIdentityService {
  SessionIdentityService({required this._storage, required this._dio});

  final DeviceKeyValueStorage _storage;
  final Dio _dio;

  SessionIdentity? _cached;
  Future<SessionIdentity?>? _restoreFuture;
  Future<SessionIdentity?>? _refreshFuture;

  /// Returns the cached session without waiting for restoration. The
  /// [BearerInterceptor] calls this synchronously on each request so it can
  /// attach the token when available without blocking the request pipeline.
  SessionIdentity? get cached => _cached;

  /// Attempts to restore a previously authenticated session by rotating the
  /// stored refresh token. Concurrent calls in one isolate share a single
  /// in-flight restoration. Returns `null` (guest) if nothing was stored or
  /// the stored refresh token is no longer valid — in the latter case, any
  /// stored session data is cleared so the app falls back to the guest
  /// state safely rather than retrying a dead credential forever.
  Future<SessionIdentity?> restore() {
    if (_cached != null) return Future.value(_cached);
    _restoreFuture ??= _restore().then(
      (id) {
        _cached = id;
        if (id == null) _restoreFuture = null;
        return id;
      },
      onError: (Object _) {
        _restoreFuture = null;
        return null;
      },
    );
    return _restoreFuture!;
  }

  Future<SessionIdentity?> _restore() async {
    final refreshToken = await _storage.read(_keyRefreshToken);
    final userId = await _storage.read(_keyUserId);
    if (refreshToken == null || userId == null) return null;
    return _rotate(refreshToken: refreshToken, userId: userId);
  }

  /// Rotates the session's tokens if the cached access token has expired
  /// (issue #155) — call when the app returns to the foreground, since
  /// access tokens are short-lived (backend default 15m: [[api]]) and
  /// nothing else proactively refreshes one mid-session. A no-op for a
  /// guest (nothing cached) or a still-fresh token. Concurrent calls share
  /// one in-flight rotation, mirroring [restore]. A failed rotation
  /// (expired/revoked refresh token) clears the session so the app falls
  /// back to the guest state instead of replaying a dead credential.
  Future<SessionIdentity?> refreshIfExpired() {
    final current = _cached;
    if (current == null || !_isAccessTokenExpired(current.accessToken)) {
      return Future.value(current);
    }
    _refreshFuture ??=
        _rotate(
          refreshToken: current.refreshToken,
          userId: current.userId,
        ).then(
          (id) {
            _cached = id;
            _refreshFuture = null;
            return id;
          },
          onError: (Object _) {
            // An unexpected (non-DioException) failure, e.g. a local storage
            // write error — leave the still-cached, if stale, session alone
            // rather than forcing a sign-out over a transient local problem.
            _refreshFuture = null;
            return current;
          },
        );
    return _refreshFuture!;
  }

  Future<SessionIdentity?> _rotate({
    required String refreshToken,
    required String userId,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/v1/auth/refresh',
        data: {'refresh_token': refreshToken},
      );
      final body = response.data;
      final accessToken = body?['access_token'] as String?;
      final newRefreshToken = body?['refresh_token'] as String?;
      if (accessToken == null || newRefreshToken == null) {
        await _clear();
        return null;
      }

      await _persist(
        accessToken: accessToken,
        refreshToken: newRefreshToken,
        userId: userId,
      );
      return SessionIdentity(
        accessToken: accessToken,
        refreshToken: newRefreshToken,
        userId: userId,
      );
    } on DioException {
      // An expired, revoked, or otherwise-invalid refresh token: fall back
      // to the guest state rather than replaying a dead credential.
      await _clear();
      return null;
    }
  }

  /// Persists a fresh session after a successful otp verification
  /// (features/auth) and makes it immediately available via [cached].
  Future<void> save(SessionIdentity identity) async {
    await _persist(
      accessToken: identity.accessToken,
      refreshToken: identity.refreshToken,
      userId: identity.userId,
    );
    _cached = identity;
    _restoreFuture = Future.value(identity);
  }

  /// Logs out: clears local session state immediately (so the ui reflects
  /// the guest state right away regardless of network conditions), then
  /// best-effort revokes the refresh token server-side. The installation's
  /// device identity is never touched — logging out ends the account
  /// session, not the app's own device registration.
  ///
  /// [deviceToken], when the caller has one cached, is sent as
  /// `X-Device-Token` (issue #80 product-owner review, finding 5) so the
  /// backend can unlink this installation from the account being logged
  /// out of — the fix for the "device already linked to another account"
  /// bug that used to permanently block signing into a different account
  /// on the same device. Best-effort like the revoke itself: a missing or
  /// stale token just means the backend leaves the link alone (a no-op,
  /// never an error), and logout still succeeds either way.
  ///
  /// `POST /v1/auth/logout` requires `Authorization: Bearer` server-side
  /// (see [[api]]) — this class deliberately uses its own bare [Dio], not
  /// the shared, [BearerInterceptor]-equipped [ApiClient] (so refreshing
  /// never recursively depends on the interceptor it's refreshing the
  /// credential for), so the access token has to be attached here
  /// explicitly, exactly like [BearerInterceptor] itself does. Read before
  /// [_cached] is cleared below (falling back to storage, mirroring
  /// [refreshToken]'s own fallback), since without it every logout call
  /// silently 401s and the try/catch below swallows it — the local session
  /// still clears correctly, but neither the server-side revoke nor the
  /// device unlink above ever actually happens.
  Future<void> logout({String? deviceToken}) async {
    final refreshToken =
        _cached?.refreshToken ?? await _storage.read(_keyRefreshToken);
    final accessToken =
        _cached?.accessToken ?? await _storage.read(_keyAccessToken);
    _cached = null;
    _restoreFuture = null;
    await _clear();

    if (refreshToken == null) return;
    try {
      await _dio.post<void>(
        '/v1/auth/logout',
        data: {'refresh_token': refreshToken},
        options: Options(
          headers: {
            if (accessToken != null) 'Authorization': 'Bearer $accessToken',
            'X-Device-Token': ?deviceToken,
          },
        ),
      );
    } catch (_) {
      // Best-effort — local session is already cleared either way, and a
      // stale server-side refresh-token row poses no risk once the client
      // no longer holds a copy of it.
    }
  }

  Future<void> _persist({
    required String accessToken,
    required String refreshToken,
    required String userId,
  }) async {
    await _storage.write(_keyAccessToken, accessToken);
    await _storage.write(_keyRefreshToken, refreshToken);
    await _storage.write(_keyUserId, userId);
  }

  Future<void> _clear() async {
    await _storage.delete(_keyAccessToken);
    await _storage.delete(_keyRefreshToken);
    await _storage.delete(_keyUserId);
  }
}

/// Reads (without verifying — the server is the only party that needs to
/// trust it) the `exp` claim out of an access token jwt's payload segment,
/// treating anything malformed as already expired. A 30s leeway means a
/// token that's about to expire gets rotated proactively rather than
/// possibly failing the very request it's attached to.
bool _isAccessTokenExpired(String accessToken) {
  final parts = accessToken.split('.');
  if (parts.length != 3) return true;
  try {
    final payload =
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
            as Map<String, dynamic>;
    final exp = payload['exp'];
    if (exp is! int) return true;
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      exp * 1000,
      isUtc: true,
    );
    return !expiresAt
        .subtract(const Duration(seconds: 30))
        .isAfter(DateTime.now().toUtc());
  } catch (_) {
    return true;
  }
}

/// Provides the [SessionIdentityService] as a singleton, mirroring
/// [deviceIdentityServiceProvider]'s construction exactly.
final sessionIdentityServiceProvider = Provider<SessionIdentityService>((ref) {
  return SessionIdentityService(
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

/// Reactive session state: restores once on first watch, then updates
/// immediately on [save]/[logout] — unlike a plain `FutureProvider`, ui
/// watching [sessionProvider] rebuilds the moment a login or logout
/// happens, not only on the next app restart. [SessionIdentityService]
/// itself stays the source of truth for storage/network; this notifier is
/// the reactive Riverpod-facing wrapper around it.
class SessionNotifier extends AsyncNotifier<SessionIdentity?> {
  @override
  Future<SessionIdentity?> build() {
    return ref.watch(sessionIdentityServiceProvider).restore();
  }

  /// Persists a fresh session after a successful otp verification
  /// (features/auth) and updates state immediately.
  Future<void> save(SessionIdentity identity) async {
    await ref.read(sessionIdentityServiceProvider).save(identity);
    state = AsyncData(identity);
  }

  /// Rotates the session's tokens if the access token expired while the
  /// app was backgrounded (issue #155) — call when the app resumes to the
  /// foreground. A no-op for a guest or an already-fresh token. Never
  /// transitions state through `AsyncLoading`, so resuming never flashes a
  /// loading state over screens already showing the previous session's
  /// data; a failed rotation still lands here as `AsyncData(null)`, moving
  /// the app to the guest state exactly like a normal logout would.
  Future<void> refreshIfNeeded() async {
    final refreshed = await ref
        .read(sessionIdentityServiceProvider)
        .refreshIfExpired();
    state = AsyncData(refreshed);
  }

  /// Logs out and updates state immediately, regardless of whether the
  /// best-effort server-side revoke succeeds. Passes the installation's own
  /// cached device token through (issue #80 product-owner review, finding
  /// 5) so the backend can unlink it from this account — never calls
  /// [DeviceIdentityService.invalidate]: the installation's device
  /// identity itself must survive a logout unchanged, only its account
  /// link is affected, server-side.
  Future<void> logout() async {
    final deviceToken = ref
        .read(deviceIdentityServiceProvider)
        .cached
        ?.deviceToken;
    await ref
        .read(sessionIdentityServiceProvider)
        .logout(deviceToken: deviceToken);
    state = const AsyncData(null);
  }
}

final sessionProvider =
    AsyncNotifierProvider<SessionNotifier, SessionIdentity?>(
      SessionNotifier.new,
    );
