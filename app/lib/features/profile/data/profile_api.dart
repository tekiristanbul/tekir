import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import 'profile.dart';

/// Thrown when `GET /v1/me/profile` answers 401 — an authenticated account
/// is required (the profile is inherently the caller's own account-owned
/// state; this mvp slice never exposes another account's profile).
class ProfileUnauthorizedException implements Exception {
  const ProfileUnauthorizedException();
}

/// Thrown for connection failures (offline, timeout).
class ProfileNetworkException implements Exception {
  const ProfileNetworkException();
}

/// Thrown for a 5xx or otherwise unmapped response.
class ProfileServerException implements Exception {
  const ProfileServerException();
}

/// The authenticated account's own minimal profile surface (issue #80):
/// `Authorization: Bearer` is attached automatically by the shared
/// [ApiClient]'s interceptor once a session is cached.
class ProfileApi {
  ProfileApi(this._apiClient);

  final ApiClient _apiClient;

  Future<Profile> fetch() async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '/v1/me/profile',
      );
      return Profile.fromJson(response.data!);
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Exception _mapError(DioException e) {
    final status = e.response?.statusCode;
    if (status == 401) return const ProfileUnauthorizedException();
    if (status != null) return const ProfileServerException();
    return const ProfileNetworkException();
  }
}

final profileApiProvider = Provider<ProfileApi>(
  (ref) => ProfileApi(ref.watch(apiClientProvider)),
);
