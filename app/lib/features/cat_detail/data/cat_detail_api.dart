import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import 'cat_detail.dart';

/// Thrown when the backend answers 404 for a cat id — distinct from a
/// generic network/server failure so the ui can show a dedicated
/// not-found state instead of the retry-a-transient-error banner.
class CatNotFoundException implements Exception {
  const CatNotFoundException();
}

/// Thrown when `POST .../updates` answers 400 — an empty, unlisted, or
/// duplicate status set, or a comment-only body. The composition ui
/// already prevents submitting an empty selection, so this mainly guards
/// against a stale client/server contract rather than a routine path.
class UpdateValidationException implements Exception {
  const UpdateValidationException();
}

/// Thrown when `POST .../updates` answers 401 — the caller's bearer session
/// is missing, expired, or invalid (issue #65: an authenticated account is
/// required to post an update; the device token is optional association
/// only). `CatUpdateComposerNotifier._submit` already checks
/// `sessionIdentityServiceProvider.cached` before calling this api, so this
/// exception should only surface if the server rejects a session that
/// looked valid locally (e.g. revoked mid-flight). Its current recovery —
/// invalidating the device identity — targets a separately stale device
/// credential and does not clear the account session.
class UpdateUnauthorizedException implements Exception {
  const UpdateUnauthorizedException();
}

/// Thrown for connection failures (offline, timeout) submitting an update —
/// distinct from [UpdateServerException] so the ui can suggest checking
/// connectivity rather than a generic "try again later".
class UpdateNetworkException implements Exception {
  const UpdateNetworkException();
}

/// Thrown for a 5xx or otherwise unmapped response submitting an update —
/// retryable, but not attributable to the client's own connectivity.
class UpdateServerException implements Exception {
  const UpdateServerException();
}

class CatDetailApi {
  CatDetailApi(this._apiClient);

  final ApiClient _apiClient;

  Future<CatDetail> fetchDetail(String catId) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '/v1/cats/$catId',
      );
      return CatDetail.fromJson(response.data!);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        throw const CatNotFoundException();
      }
      rethrow;
    }
  }

  /// Fetches one newest-first page of catId's update history. cursor is the
  /// opaque next_cursor from a previous page; omit it for the first page.
  Future<UpdatesPage> fetchUpdates(String catId, {String? cursor}) async {
    final response = await _apiClient.dio.get<Map<String, dynamic>>(
      '/v1/cats/$catId/updates',
      queryParameters: {'cursor': ?cursor},
    );
    return UpdatesPage.fromJson(response.data!);
  }

  /// Submits an ordinary status update (issue #43, moved onto authenticated
  /// accounts by issue #65): one or more of the fixed mvp statuses plus an
  /// optional free-text comment, attributed to the caller's authenticated
  /// account via the shared [ApiClient]'s `Authorization: Bearer`
  /// interceptor — the device token is attached too, when available, for
  /// installation association only. The caller is responsible for making
  /// sure a session exists first (see [AuthGate]) — this method does not
  /// trigger sign-in itself, so an unauthenticated call surfaces as a plain
  /// [UpdateUnauthorizedException] rather than a silent retry.
  Future<CatUpdateEntry> createUpdate(
    String catId, {
    required List<String> statuses,
    String? comment,
  }) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '/v1/cats/$catId/updates',
        data: {'statuses': statuses, 'comment': comment},
      );
      final body = response.data;
      if (body == null) throw const UpdateServerException();
      return CatUpdateEntry.fromJson(body);
    } on DioException catch (e) {
      throw _mapCreateUpdateError(e);
    }
  }

  Exception _mapCreateUpdateError(DioException e) {
    final status = e.response?.statusCode;
    switch (status) {
      case 400:
        return const UpdateValidationException();
      case 401:
        return const UpdateUnauthorizedException();
      case 404:
        return const CatNotFoundException();
    }
    if (status != null) return const UpdateServerException();
    return const UpdateNetworkException();
  }
}

final catDetailApiProvider = Provider<CatDetailApi>(
  (ref) => CatDetailApi(ref.watch(apiClientProvider)),
);
