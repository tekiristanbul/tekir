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

/// Thrown when `POST .../updates` answers 400 — an unlisted or duplicate
/// status, a body carrying neither a status nor the help flag, or a help
/// note beyond its 500-character cap (issue #101). The composition ui
/// already prevents each of those, so this mainly guards against a stale
/// client/server contract rather than a routine path.
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

/// Thrown when PATCH/DELETE `.../updates/{update_id}` answers 403 — the
/// update exists under this cat but isn't the caller's own (issue #80).
/// Not collapsed into [CatNotFoundException]: the full update history is
/// already public, so "exists but isn't yours" leaks nothing a guest
/// couldn't already see on the public timeline.
class UpdateCorrectionForbiddenException implements Exception {
  const UpdateCorrectionForbiddenException();
}

/// Thrown when PATCH/DELETE `.../updates/{update_id}` answers 404 — the
/// update id doesn't exist under this cat, or it's a needs-help update
/// (never a correctable resource here).
class UpdateCorrectionNotFoundException implements Exception {
  const UpdateCorrectionNotFoundException();
}

/// Thrown when PATCH/DELETE `.../updates/{update_id}` answers 410 — the
/// fixed 10-minute correction window (docs/product/updates.md) has closed.
class UpdateCorrectionExpiredException implements Exception {
  const UpdateCorrectionExpiredException();
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

  /// Submits an update (issue #43, moved onto authenticated accounts by
  /// issue #65; help folded in by issue #101): one or more of the fixed mvp
  /// statuses, the `yardıma ihtiyacı var` flag, or both, plus an optional
  /// free-text comment — which doubles as the help note when [needsHelp] is
  /// set. Attributed to the caller's authenticated account via the shared
  /// [ApiClient]'s `Authorization: Bearer` interceptor — the device token
  /// is attached too, when available, for installation association only.
  /// The caller is responsible for making sure a session exists first (see
  /// [AuthGate]) — this method does not trigger sign-in itself, so an
  /// unauthenticated call surfaces as a plain [UpdateUnauthorizedException]
  /// rather than a silent retry.
  ///
  /// idempotencyKey (issue #80 product-owner review, finding 4) must be the
  /// same value across retries of the same attempt — mirrors
  /// [AddCatApi.createCat]'s exact contract — so a rapid repeat "Gördüm" tap
  /// or a retried request can never create a second update row; the backend
  /// resolves a retried key to the original update instead of erroring.
  Future<CatUpdateEntry> createUpdate(
    String catId, {
    required List<String> statuses,
    bool needsHelp = false,
    String? comment,
    required String idempotencyKey,
  }) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '/v1/cats/$catId/updates',
        data: {
          'statuses': statuses,
          'needs_help': needsHelp,
          'comment': comment,
        },
        options: Options(headers: {'Idempotency-Key': idempotencyKey}),
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

  /// Corrects the caller's own update within its fixed 10-minute window
  /// (issue #80, extended by #101): statuses and/or comment, and —
  /// [clearNeedsHelp] — removal of the update's own help mark. The PATCH
  /// body is presence-aware (issue #105): `needs_help` is only ever sent as
  /// `false`, since the mark can never be added by an edit; when
  /// [clearNeedsHelp] is false the field is omitted so the server leaves
  /// the mark untouched. The caller is responsible for making sure a
  /// session exists first (see [AuthGate]) — this method does not trigger
  /// sign-in itself. Author identity and created_at are never alterable
  /// through this path.
  Future<CatUpdateEntry> correctUpdate(
    String catId,
    String updateId, {
    required List<String> statuses,
    String? comment,
    bool clearNeedsHelp = false,
  }) async {
    try {
      final response = await _apiClient.dio.patch<Map<String, dynamic>>(
        '/v1/cats/$catId/updates/$updateId',
        data: {
          'statuses': statuses,
          'comment': comment,
          if (clearNeedsHelp) 'needs_help': false,
        },
      );
      final body = response.data;
      if (body == null) throw const UpdateServerException();
      return CatUpdateEntry.fromJson(body);
    } on DioException catch (e) {
      throw _mapCorrectionError(e);
    }
  }

  /// Soft-deletes the caller's own ordinary update within its fixed
  /// 10-minute window (issue #80). A retry against an already-deleted row
  /// also succeeds (204) server-side — see the backend's idempotent-retry
  /// note — so this never throws for that case.
  Future<void> deleteUpdate(String catId, String updateId) async {
    try {
      await _apiClient.dio.delete<void>('/v1/cats/$catId/updates/$updateId');
    } on DioException catch (e) {
      throw _mapCorrectionError(e);
    }
  }

  Exception _mapCorrectionError(DioException e) {
    final status = e.response?.statusCode;
    switch (status) {
      case 400:
        return const UpdateValidationException();
      case 401:
        return const UpdateUnauthorizedException();
      case 403:
        return const UpdateCorrectionForbiddenException();
      case 404:
        return const UpdateCorrectionNotFoundException();
      case 410:
        return const UpdateCorrectionExpiredException();
    }
    if (status != null) return const UpdateServerException();
    return const UpdateNetworkException();
  }
}

final catDetailApiProvider = Provider<CatDetailApi>(
  (ref) => CatDetailApi(ref.watch(apiClientProvider)),
);
