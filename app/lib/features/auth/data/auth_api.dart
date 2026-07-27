import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

/// The full session issued by a successful otp verification
/// (docs/architecture/api.md). [isNewAccount] tells the caller whether to
/// show the new-account minimum-profile (display name) step next — true
/// only the first time an account is created for that phone number, never
/// on a returning login.
class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
    required this.isNewAccount,
  });

  final String accessToken;
  final String refreshToken;
  final String userId;
  final bool isNewAccount;
}

/// Thrown when `POST /v1/auth/otp/request` or `.../otp/verify` answers 400 —
/// a malformed phone number.
class OtpInvalidPhoneException implements Exception {
  const OtpInvalidPhoneException();
}

/// Thrown when `POST /v1/auth/otp/request` answers 429 — a code was already
/// requested for this number more recently than the server's cooldown.
class OtpResendTooSoonException implements Exception {
  const OtpResendTooSoonException();
}

/// Thrown when `POST /v1/auth/otp/verify` answers 401 — no code was ever
/// requested for this number, or the presented code doesn't match. The two
/// collapse to one response server-side so a client can't distinguish
/// "you never asked" from "you guessed wrong".
class OtpInvalidCodeException implements Exception {
  const OtpInvalidCodeException();
}

/// Thrown when `POST /v1/auth/otp/verify` answers 401 for a *device* token
/// problem (missing, or one the server no longer recognizes) rather than a
/// wrong/expired code — distinguished from [OtpInvalidCodeException] by the
/// response body, since both share the same 401 status. This means the
/// locally-cached device credential is stale: the caller should drop it
/// (`DeviceIdentityService.invalidate`) so the next attempt registers a
/// fresh one, instead of replaying the same dead token forever.
class AuthDeviceTokenInvalidException implements Exception {
  const AuthDeviceTokenInvalidException();
}

/// Thrown when `POST /v1/auth/otp/verify` answers 410 — the most recently
/// issued code expired, or was already used once (replay).
class OtpExpiredCodeException implements Exception {
  const OtpExpiredCodeException();
}

/// Thrown when `POST /v1/auth/otp/verify` answers 429 — the code's guess
/// attempts are exhausted; a new code must be requested.
class OtpTooManyAttemptsException implements Exception {
  const OtpTooManyAttemptsException();
}

/// Thrown when `POST /v1/auth/otp/verify` answers 409 — this device is
/// already linked to a different account than the one being verified into.
class AuthDeviceConflictException implements Exception {
  const AuthDeviceConflictException();
}

/// Thrown when `PATCH /v1/me` (display name) answers 400 — empty or too
/// long.
class InvalidDisplayNameException implements Exception {
  const InvalidDisplayNameException();
}

/// Thrown for connection failures (offline, timeout) — distinct from
/// [AuthServerException] so the ui can suggest checking connectivity
/// rather than a generic "try again later".
class AuthNetworkException implements Exception {
  const AuthNetworkException();
}

/// Thrown for a 5xx or otherwise unmapped response — retryable, but not
/// attributable to the client's own connectivity.
class AuthServerException implements Exception {
  const AuthServerException();
}

class AuthApi {
  AuthApi(this._apiClient);

  final ApiClient _apiClient;

  /// Requests a new otp code for phone (already normalized/prefixed by the
  /// caller, matching the login screen's fixed "+90" input). The device's
  /// own `X-Device-Token` is attached automatically by the shared
  /// [ApiClient]'s [DeviceInterceptor] — no explicit device argument needed.
  Future<void> requestOtp(String phone) async {
    try {
      await _apiClient.dio.post<void>(
        '/v1/auth/otp/request',
        data: {'phone': phone},
      );
    } on DioException catch (e) {
      throw _mapRequestOtpError(e);
    }
  }

  /// Verifies phone+code, resolving-or-creating the account and linking
  /// this device to it server-side. Returns the full session on success.
  Future<AuthSession> verifyOtp({
    required String phone,
    required String code,
  }) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '/v1/auth/otp/verify',
        data: {'phone': phone, 'code': code},
      );
      final body = response.data;
      if (body == null) throw const AuthServerException();
      return AuthSession(
        accessToken: body['access_token'] as String,
        refreshToken: body['refresh_token'] as String,
        userId: body['user_id'] as String,
        isNewAccount: body['is_new_account'] as bool? ?? false,
      );
    } on DioException catch (e) {
      throw _mapVerifyOtpError(e);
    }
  }

  /// Sets the account's minimum-profile display name (issue #58's
  /// new-account step) — the caller only invokes this when the session
  /// [AuthSession.verifyOtp] just returned reports `isNewAccount`.
  /// Requires the shared [ApiClient]'s bearer interceptor to have a
  /// session cached (i.e. call this only after [SessionIdentityService.save]).
  Future<void> setDisplayName(String displayName) async {
    try {
      await _apiClient.dio.patch<void>(
        '/v1/me',
        data: {'display_name': displayName},
      );
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 400) throw const InvalidDisplayNameException();
      if (status != null) throw const AuthServerException();
      throw const AuthNetworkException();
    }
  }

  Exception _mapRequestOtpError(DioException e) {
    final status = e.response?.statusCode;
    return switch (status) {
      400 => const OtpInvalidPhoneException(),
      429 => const OtpResendTooSoonException(),
      null => const AuthNetworkException(),
      _ => const AuthServerException(),
    };
  }

  Exception _mapVerifyOtpError(DioException e) {
    final status = e.response?.statusCode;
    if (status == 401) {
      return _isDeviceTokenError(e)
          ? const AuthDeviceTokenInvalidException()
          : const OtpInvalidCodeException();
    }
    return switch (status) {
      400 => const OtpInvalidPhoneException(),
      410 => const OtpExpiredCodeException(),
      409 => const AuthDeviceConflictException(),
      429 => const OtpTooManyAttemptsException(),
      null => const AuthNetworkException(),
      _ => const AuthServerException(),
    };
  }

  /// `RequireDeviceToken` middleware (missing/unrecognized X-Device-Token)
  /// and `AuthHandler.VerifyOTP`'s own code-mismatch check both answer 401
  /// with no other status-code distinction — the only way to tell them
  /// apart is the response body's `error` text (see
  /// docs/architecture/api.md / backend/internal/handler/device_auth.go).
  bool _isDeviceTokenError(DioException e) {
    final body = e.response?.data;
    final message = body is Map ? body['error'] as String? : null;
    return message != null && message.contains('device token');
  }
}

final authApiProvider = Provider<AuthApi>(
  (ref) => AuthApi(ref.watch(apiClientProvider)),
);
