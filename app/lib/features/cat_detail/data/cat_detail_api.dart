import 'dart:typed_data';

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

/// Thrown when the update composer's attached photo exceeds the server's
/// size limit (issue #153) — mirrors [AddCatMediaTooLargeException] for
/// the standalone `POST /v1/media` upload this composer uses instead.
class UpdateMediaTooLargeException implements Exception {
  const UpdateMediaTooLargeException();
}

/// Thrown when the update composer's attached photo isn't a supported
/// image type (issue #153).
class UpdateMediaUnsupportedException implements Exception {
  const UpdateMediaUnsupportedException();
}

/// Thrown when `POST .../updates` answers 404 with `media not found` —
/// the media id the composer uploaded moments earlier no longer resolves
/// (deleted, or somehow not owned by the caller). Distinct from
/// [CatNotFoundException], which shares the same 404 status: the two are
/// told apart by the response body's `error` field (see
/// `_mapCreateUpdateError`).
class UpdateMediaNotFoundException implements Exception {
  const UpdateMediaNotFoundException();
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
      queryParameters: {'cursor': cursor},
    );
    return UpdatesPage.fromJson(response.data!);
  }

  /// Fetches catId's photo archive, newest-first (issue #121's
  /// media-archive parity gap) — backs the cat-profile "medya" tab.
  Future<List<CatMediaItem>> fetchMedia(String catId) async {
    try {
      final response = await _apiClient.dio.get<List<dynamic>>(
        '/v1/cats/$catId/media',
      );
      return (response.data ?? const [])
          .map((e) => CatMediaItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        throw const CatNotFoundException();
      }
      rethrow;
    }
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
  ///
  /// mediaId (issue #153) is the id [uploadMedia] returned for an optional
  /// photo attached in the composer — the composer uploads the photo
  /// first, then references it here; this method never accepts raw media
  /// bytes itself.
  Future<CatUpdateEntry> createUpdate(
    String catId, {
    required List<String> statuses,
    bool needsHelp = false,
    String? comment,
    required String idempotencyKey,
    String? mediaId,
  }) async {
    try {
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '/v1/cats/$catId/updates',
        data: {
          'statuses': statuses,
          'needs_help': needsHelp,
          'comment': comment,
          'media_id': mediaId,
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
        final body = e.response?.data;
        if (body is Map<String, dynamic> && body['error'] == 'media not found') {
          return const UpdateMediaNotFoundException();
        }
        return const CatNotFoundException();
    }
    if (status != null) return const UpdateServerException();
    return const UpdateNetworkException();
  }

  /// Uploads a photo standalone via `POST /v1/media` (issue #153's optional
  /// update-composer attachment), returning the created media's id for
  /// [createUpdate]'s `mediaId`. photoBytes/photoFilename come from the
  /// picked image the same way [AddCatApi.createCat] reads them (`XFile.
  /// readAsBytes`, never a raw file path — see that method's own doc for
  /// why). idempotencyKey must be the same value across retries of the same
  /// upload attempt, mirroring every other multipart write in this app.
  /// [onSendProgress] reports raw request-body bytes leaving the device,
  /// driving the composer's own upload-percentage overlay.
  Future<String> uploadMedia({
    required Uint8List photoBytes,
    required String photoFilename,
    required String idempotencyKey,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    try {
      final formData = FormData.fromMap({
        'file': MultipartFile.fromBytes(photoBytes, filename: photoFilename),
      });
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '/v1/media',
        data: formData,
        options: Options(headers: {'Idempotency-Key': idempotencyKey}),
        onSendProgress: onSendProgress,
      );
      final body = response.data;
      if (body == null) throw const UpdateServerException();
      return body['media_id'] as String;
    } on DioException catch (e) {
      throw _mapUploadMediaError(e);
    }
  }

  Exception _mapUploadMediaError(DioException e) {
    final status = e.response?.statusCode;
    switch (status) {
      case 400:
        return const UpdateValidationException();
      case 401:
        return const UpdateUnauthorizedException();
      case 413:
        return const UpdateMediaTooLargeException();
      case 415:
        return const UpdateMediaUnsupportedException();
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
