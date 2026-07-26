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
}

final accountApiProvider = Provider<AccountApi>(
  (ref) => AccountApi(ref.watch(apiClientProvider)),
);
