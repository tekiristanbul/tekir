import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../cat_detail/data/cat_detail.dart';
import '../../cat_detail/data/cat_detail_api.dart' show CatNotFoundException;

/// Thrown when `POST .../needs-help` answers 400 — an unrecognized or
/// missing category. The picker already prevents submitting without a
/// selection, so this mainly guards against a stale client/server contract
/// rather than a routine path (mirrors [UpdateValidationException]).
class NeedsHelpValidationException implements Exception {
  const NeedsHelpValidationException();
}

/// Thrown when `POST .../needs-help` answers 401 — the caller's bearer
/// session is missing, expired, or invalid. Needs-help creation requires an
/// authenticated account (issue #78); [NeedsHelpNotifier.submit] already
/// checks the cached session before calling this api, so this should only
/// surface if the server rejects a session that looked valid locally.
class NeedsHelpUnauthorizedException implements Exception {
  const NeedsHelpUnauthorizedException();
}

/// Thrown for connection failures (offline, timeout) submitting a
/// needs-help report — distinct from [NeedsHelpServerException] so the ui
/// can suggest checking connectivity rather than a generic "try again".
class NeedsHelpNetworkException implements Exception {
  const NeedsHelpNetworkException();
}

/// Thrown for a 5xx or otherwise unmapped response — retryable, but not
/// attributable to the client's own connectivity.
class NeedsHelpServerException implements Exception {
  const NeedsHelpServerException();
}

class NeedsHelpApi {
  NeedsHelpApi(this._apiClient);

  final ApiClient _apiClient;

  /// Submits a needs-help report (issue #78): a fixed category plus an
  /// optional free-text comment, attributed to the caller's authenticated
  /// account via the shared [ApiClient]'s `Authorization: Bearer`
  /// interceptor. The caller is responsible for making sure a session
  /// exists first (see `AuthGate`) — this method does not trigger sign-in
  /// itself. expires_at/active are always server-computed; never accepted
  /// from the caller.
  Future<CatUpdateEntry> create(
    String catId, {
    required String category,
    String? comment,
  }) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '/v1/cats/$catId/needs-help',
        data: {'category': category, 'comment': comment},
      );
      final body = response.data;
      if (body == null) throw const NeedsHelpServerException();
      return CatUpdateEntry.fromJson(body);
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Exception _mapError(DioException e) {
    final status = e.response?.statusCode;
    switch (status) {
      case 400:
        return const NeedsHelpValidationException();
      case 401:
        return const NeedsHelpUnauthorizedException();
      case 404:
        return const CatNotFoundException();
    }
    if (status != null) return const NeedsHelpServerException();
    return const NeedsHelpNetworkException();
  }
}

final needsHelpApiProvider = Provider<NeedsHelpApi>(
  (ref) => NeedsHelpApi(ref.watch(apiClientProvider)),
);
