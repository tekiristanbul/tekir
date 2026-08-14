import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

/// Thrown when `POST /v1/reports` answers 401 — the bearer session is
/// missing, expired, or otherwise invalid (issue #233: reporting requires
/// an authenticated account, same as following or posting an update).
class ReportUnauthorizedException implements Exception {
  const ReportUnauthorizedException();
}

/// Thrown when the reported cat/update/media no longer exists — mirrors
/// [FollowCatNotFoundException]'s shape.
class ReportTargetNotFoundException implements Exception {
  const ReportTargetNotFoundException();
}

/// Thrown for a rejected report body (an invalid reason, or "diğer"
/// submitted without a note) — the sheet itself already prevents both
/// client-side, so this is only reachable through a genuine race or a
/// stale client.
class ReportValidationException implements Exception {
  const ReportValidationException();
}

/// Thrown for connection failures (offline, timeout).
class ReportNetworkException implements Exception {
  const ReportNetworkException();
}

/// Thrown for a 5xx or otherwise unmapped response.
class ReportServerException implements Exception {
  const ReportServerException();
}

/// User-generated content reporting (issue #233): a single `POST
/// /v1/reports` behind the bearer session — attached automatically by the
/// shared [ApiClient]'s interceptor, never handled by this class itself.
/// The server derives the reporter from the session and is the sole
/// authority on duplicate/retry idempotency; this class only submits and
/// maps the response.
class ReportsApi {
  ReportsApi(this._apiClient);

  final ApiClient _apiClient;

  Future<void> submitReport({
    required String targetType,
    required String targetId,
    required String reason,
    String? note,
  }) async {
    try {
      await _apiClient.dio.post<Map<String, dynamic>>(
        '/v1/reports',
        data: {
          'target_type': targetType,
          'target_id': targetId,
          'reason': reason,
          'note': note,
        },
      );
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Exception _mapError(DioException e) {
    final status = e.response?.statusCode;
    switch (status) {
      case 400:
        return const ReportValidationException();
      case 401:
        return const ReportUnauthorizedException();
      case 404:
        return const ReportTargetNotFoundException();
    }
    if (status != null) return const ReportServerException();
    return const ReportNetworkException();
  }
}

final reportsApiProvider = Provider<ReportsApi>(
  (ref) => ReportsApi(ref.watch(apiClientProvider)),
);
