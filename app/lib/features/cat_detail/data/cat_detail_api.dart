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

/// Thrown when the update composer's attached photo or video exceeds the
/// server's size limit (issue #153) — mirrors [AddCatMediaTooLargeException]
/// for the standalone `POST /v1/media` upload this composer uses instead.
class UpdateMediaTooLargeException implements Exception {
  const UpdateMediaTooLargeException();
}

/// Thrown when the update composer's attached photo or video isn't a
/// supported media type (issue #153).
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

/// Thrown when `POST /v1/media`, `POST .../updates`, or `PATCH
/// .../updates/{update_id}` answers 422 — the submitted comment/help note
/// or attached photo/video was rejected by the pre-publication content
/// classifier (issue #241, docs/product/trust.md). Mirrors
/// [AddCatContentRejectedException]'s exact contract: a stable, recoverable
/// validation-class outcome, never a report to anyone — the caller's own
/// draft/media is left untouched so the ui can offer edit/replace/remove
/// and retry. Distinct from [UpdateServerException] (the classifier's own
/// failures — timeout, malformed output — surface as the existing generic
/// 500, unchanged) so a genuine rejection never gets a "try again shortly"
/// framing.
class UpdateContentRejectedException implements Exception {
  const UpdateContentRejectedException();
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

/// Thrown when `PATCH .../cover` answers 403 — the caller isn't the cat's
/// own owner (issue #156). Not collapsed into [CatNotFoundException]: the
/// cat's detail read already tells any caller, including a guest, whether
/// they own it via `is_owner`, so confirming "this exists, but isn't
/// yours" leaks nothing the caller couldn't already see.
class SetCoverForbiddenException implements Exception {
  const SetCoverForbiddenException();
}

/// Thrown when `PATCH .../cover` answers 400 — media_id isn't a
/// well-formed id, or isn't part of this cat's own media archive (issue
/// #156: only an existing gallery entry may be promoted to cover).
class SetCoverValidationException implements Exception {
  const SetCoverValidationException();
}

/// Thrown when `PATCH /v1/cats/{cat_id}` answers 403 — the caller isn't the
/// cat's own owner (issue #227). Not collapsed into [CatNotFoundException]:
/// the cat's detail read already tells any caller, including a guest,
/// whether they own it via `is_owner`, so confirming "this exists, but
/// isn't yours" leaks nothing the caller couldn't already see — mirrors
/// [SetCoverForbiddenException]'s exact reasoning.
class RenameCatForbiddenException implements Exception {
  const RenameCatForbiddenException();
}

/// Thrown when `PATCH /v1/cats/{cat_id}` answers 400 — name is empty once
/// trimmed (issue #227). The rename sheet already rejects this
/// client-side before ever calling this method (via [sanitizeCatName]);
/// this mainly guards against a stale client/server contract rather than a
/// routine path.
class RenameCatValidationException implements Exception {
  const RenameCatValidationException();
}

/// Thrown when `DELETE /v1/cats/{cat_id}` answers 403 — the caller isn't
/// the cat's own owner (issue #200/#228). Not collapsed into
/// [CatNotFoundException]: the cat's detail read already tells any caller,
/// including a guest, whether they own it via `is_owner`, so confirming
/// "this exists, but isn't yours" leaks nothing the caller couldn't
/// already see — mirrors [RenameCatForbiddenException]'s exact reasoning.
class DeleteCatForbiddenException implements Exception {
  const DeleteCatForbiddenException();
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

  /// Promotes an existing media-archive entry (`mediaId`, from
  /// `fetchMedia`'s own [CatMediaItem.id]) to catId's cover photo (issue
  /// #156). Only the cat's own owner may do this — the caller is
  /// responsible for making sure a session exists first (see [AuthGate]);
  /// the server re-checks ownership regardless of what the client's own
  /// `is_owner` believes. Returns the refreshed [CatDetail].
  Future<CatDetail> setCoverPhoto(String catId, String mediaId) async {
    try {
      final response = await _apiClient.dio.patch<Map<String, dynamic>>(
        '/v1/cats/$catId/cover',
        data: {'media_id': mediaId},
      );
      return CatDetail.fromJson(response.data!);
    } on DioException catch (e) {
      throw _mapSetCoverError(e);
    }
  }

  Exception _mapSetCoverError(DioException e) {
    final status = e.response?.statusCode;
    switch (status) {
      case 400:
        return const SetCoverValidationException();
      case 401:
        return const UpdateUnauthorizedException();
      case 403:
        return const SetCoverForbiddenException();
      case 404:
        return const CatNotFoundException();
    }
    if (status != null) return const UpdateServerException();
    return const UpdateNetworkException();
  }

  /// Renames catId (issue #227) — a recovery path for a naming mistake made
  /// at creation time. Only the cat's own owner may do this — the caller is
  /// responsible for making sure a session exists first (see [AuthGate]);
  /// the server re-checks ownership regardless of what the client's own
  /// `is_owner` believes. name is sent as-is (the rename sheet trims and
  /// rejects empty input before ever calling this); the server trims again
  /// regardless. Returns the refreshed [CatDetail], same shape
  /// [setCoverPhoto] already gives the caller who just made a change.
  Future<CatDetail> renameCat(String catId, String name) async {
    try {
      final response = await _apiClient.dio.patch<Map<String, dynamic>>(
        '/v1/cats/$catId',
        data: {'name': name},
      );
      return CatDetail.fromJson(response.data!);
    } on DioException catch (e) {
      throw _mapRenameCatError(e);
    }
  }

  Exception _mapRenameCatError(DioException e) {
    final status = e.response?.statusCode;
    switch (status) {
      case 400:
        return const RenameCatValidationException();
      case 401:
        return const UpdateUnauthorizedException();
      case 403:
        return const RenameCatForbiddenException();
      case 404:
        return const CatNotFoundException();
    }
    if (status != null) return const UpdateServerException();
    return const UpdateNetworkException();
  }

  /// Deletes catId permanently, from the caller's perspective (issue #228)
  /// — the one recovery path for a cat added by mistake, per #200's
  /// terminal soft delete: no restore exists. Only the cat's own owner
  /// may do this — the caller is responsible for making sure a session
  /// exists first (see [AuthGate]); the server re-checks ownership
  /// regardless of what the client's own `is_owner` believes. A retry
  /// against an already-deleted cat also succeeds (204) server-side — see
  /// the backend's idempotent-retry note — so this never throws for that
  /// case.
  Future<void> deleteCat(String catId) async {
    try {
      await _apiClient.dio.delete<void>('/v1/cats/$catId');
    } on DioException catch (e) {
      throw _mapDeleteCatError(e);
    }
  }

  Exception _mapDeleteCatError(DioException e) {
    final status = e.response?.statusCode;
    switch (status) {
      case 401:
        return const UpdateUnauthorizedException();
      case 403:
        return const DeleteCatForbiddenException();
      case 404:
        return const CatNotFoundException();
    }
    if (status != null) return const UpdateServerException();
    return const UpdateNetworkException();
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
  /// photo or video attached in the composer — the composer uploads the
  /// media first, then references it here; this method never accepts raw
  /// media bytes itself.
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
        if (body is Map<String, dynamic> &&
            body['error'] == 'media not found') {
          return const UpdateMediaNotFoundException();
        }
        return const CatNotFoundException();
      case 422:
        return const UpdateContentRejectedException();
    }
    if (status != null) return const UpdateServerException();
    return const UpdateNetworkException();
  }

  /// Uploads a photo or (issue #153's video support) short video standalone
  /// via `POST /v1/media` (issue #153's optional update-composer
  /// attachment), returning the created media's id for [createUpdate]'s
  /// `mediaId`. mediaBytes/mediaFilename come from the picked file the same
  /// way [AddCatApi.createCat] reads its photo (`XFile.readAsBytes`, never
  /// a raw file path — see that method's own doc for why). idempotencyKey
  /// must be the same value across retries of the same upload attempt,
  /// mirroring every other multipart write in this app. [onSendProgress]
  /// reports raw request-body bytes leaving the device, driving the
  /// composer's own upload-percentage overlay. The server tells a photo and
  /// a video apart by the multipart body's own content, never by this
  /// filename. [muted] (issue #194) is the composer's own mute/unmute
  /// toggle state, sent unconditionally regardless of media type — the
  /// server defaults it true on its own when omitted, but the composer
  /// always has an explicit value to send.
  Future<String> uploadMedia({
    required Uint8List mediaBytes,
    required String mediaFilename,
    required String idempotencyKey,
    required bool muted,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    try {
      final formData = FormData.fromMap({
        'file': MultipartFile.fromBytes(mediaBytes, filename: mediaFilename),
        'muted': muted.toString(),
      });
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '/v1/media',
        data: formData,
        options: Options(
          headers: {'Idempotency-Key': idempotencyKey},
          receiveTimeout: ApiClient.mediaUploadTimeout,
        ),
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
      case 422:
        return const UpdateContentRejectedException();
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
      case 422:
        return const UpdateContentRejectedException();
    }
    if (status != null) return const UpdateServerException();
    return const UpdateNetworkException();
  }
}

final catDetailApiProvider = Provider<CatDetailApi>(
  (ref) => CatDetailApi(ref.watch(apiClientProvider)),
);
