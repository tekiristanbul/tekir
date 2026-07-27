import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import 'badge.dart';

/// Thrown when `GET /v1/me/badges` answers 401 — an authenticated account
/// is required (badge progress is inherently account-owned state).
class BadgesUnauthorizedException implements Exception {
  const BadgesUnauthorizedException();
}

/// Thrown for connection failures (offline, timeout).
class BadgesNetworkException implements Exception {
  const BadgesNetworkException();
}

/// Thrown for a 5xx or otherwise unmapped response.
class BadgesServerException implements Exception {
  const BadgesServerException();
}

/// The authenticated account's own badge progress (issue #80):
/// `Authorization: Bearer` is attached automatically by the shared
/// [ApiClient]'s interceptor once a session is cached.
class BadgesApi {
  BadgesApi(this._apiClient);

  final ApiClient _apiClient;

  Future<List<BadgeStatus>> fetch() async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '/v1/me/badges',
      );
      final items = response.data!['items'] as List<dynamic>;
      return items
          .map((e) => BadgeStatus.fromJson(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Exception _mapError(DioException e) {
    final status = e.response?.statusCode;
    if (status == 401) return const BadgesUnauthorizedException();
    if (status != null) return const BadgesServerException();
    return const BadgesNetworkException();
  }
}

final badgesApiProvider = Provider<BadgesApi>(
  (ref) => BadgesApi(ref.watch(apiClientProvider)),
);
