import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../map/data/cat_marker.dart';

/// Thrown when a follow/unfollow/list call answers 404 — the cat no longer
/// exists. Mirrors [CatNotFoundException] from cat_detail (kept local here
/// so this feature slice has no data-layer dependency on cat_detail).
class FollowCatNotFoundException implements Exception {
  const FollowCatNotFoundException();
}

/// Thrown when a follow/unfollow/list call answers 401 — the bearer session
/// is missing, expired, or otherwise invalid (issue #65: following requires
/// an authenticated account). [FollowsNotifier] treats this as the account
/// session having gone stale, not a device-identity problem.
class FollowUnauthorizedException implements Exception {
  const FollowUnauthorizedException();
}

/// Thrown for connection failures (offline, timeout).
class FollowNetworkException implements Exception {
  const FollowNetworkException();
}

/// Thrown for a 5xx or otherwise unmapped response.
class FollowServerException implements Exception {
  const FollowServerException();
}

/// Account-owned cat follows (issue #65, superseding #44's device-only
/// contract): follow/unfollow/list all require the caller to already have
/// a bearer session — attached automatically by the shared [ApiClient]'s
/// interceptor once one is cached, never handled by this class itself.
class FollowsApi {
  FollowsApi(this._apiClient);

  final ApiClient _apiClient;

  Future<void> follow(String catId) async {
    try {
      await _apiClient.dio.post<void>('/v1/cats/$catId/follow');
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Future<void> unfollow(String catId) async {
    try {
      await _apiClient.dio.delete<void>('/v1/cats/$catId/follow');
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  /// Fetches the authenticated account's followed cats
  /// (`GET /v1/me/follows`), in the same summary shape the map already
  /// knows how to render — reused via [CatMarker] rather than a bespoke
  /// follows-only model.
  Future<List<CatMarker>> fetchFollows() async {
    try {
      final response = await _apiClient.dio.get<List<dynamic>>(
        '/v1/me/follows',
      );
      final body = response.data ?? const [];
      return body
          .map((e) => CatMarker.fromJson(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Exception _mapError(DioException e) {
    final status = e.response?.statusCode;
    switch (status) {
      case 401:
        return const FollowUnauthorizedException();
      case 404:
        return const FollowCatNotFoundException();
    }
    if (status != null) return const FollowServerException();
    return const FollowNetworkException();
  }
}

final followsApiProvider = Provider<FollowsApi>(
  (ref) => FollowsApi(ref.watch(apiClientProvider)),
);
