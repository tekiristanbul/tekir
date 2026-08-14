import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

/// `GET /v1/me`'s response shape (docs/architecture/api.md). Deliberately
/// has no phone number or display name — the endpoint never returns them
/// (phone numbers are never public, even to their own owner via this
/// device/account-status endpoint; see docs/product/privacy.md), so the
/// account screen can only reflect verified-or-not, not the number itself.
class AccountInfo {
  const AccountInfo({
    required this.deviceId,
    required this.userId,
    required this.phoneVerified,
  });

  final String deviceId;
  final String? userId;
  final bool phoneVerified;
}

class AccountNetworkException implements Exception {
  const AccountNetworkException();
}

/// Thrown when `DELETE /v1/me` answers 401 — the session is missing or
/// expired, so there is nothing to delete under this identity.
class AccountUnauthorizedException implements Exception {
  const AccountUnauthorizedException();
}

class AccountServerException implements Exception {
  const AccountServerException();
}

class AccountApi {
  AccountApi(this._apiClient);

  final ApiClient _apiClient;

  Future<AccountInfo> fetchMe() async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>('/v1/me');
      final body = response.data;
      if (body == null) throw const AccountServerException();
      return AccountInfo(
        deviceId: body['device_id'] as String,
        userId: body['user_id'] as String?,
        phoneVerified: body['phone_verified'] as bool? ?? false,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode != null) throw const AccountServerException();
      throw const AccountNetworkException();
    }
  }

  /// Terminal account deletion (issue #242, apple guideline 5.1.1(v)).
  /// Returns normally only when the server confirms — the caller clears the
  /// local session on that confirmation and never before, so a failure
  /// leaves the user signed in to an account that still exists. Retrying a
  /// call whose response was lost is safe: the server treats deleting an
  /// already-deleted account as success.
  Future<void> deleteAccount() async {
    try {
      await _apiClient.dio.delete<void>('/v1/me');
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401) throw const AccountUnauthorizedException();
      if (status != null) throw const AccountServerException();
      throw const AccountNetworkException();
    }
  }
}

final accountApiProvider = Provider<AccountApi>(
  (ref) => AccountApi(ref.watch(apiClientProvider)),
);
