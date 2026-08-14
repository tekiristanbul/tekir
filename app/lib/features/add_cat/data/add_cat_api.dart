import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../cat_detail/data/cat_detail.dart';

/// Thrown when a nearby/create call answers 401 — the bearer session is
/// missing, expired, or otherwise invalid. The add-cat flow only reaches
/// this api after [AuthGate] already required a session, so this should
/// only surface if that session went stale mid-flow (e.g. revoked
/// elsewhere), not on a routine path.
class AddCatUnauthorizedException implements Exception {
  const AddCatUnauthorizedException();
}

/// Thrown when `POST /v1/cats` answers 400 — a malformed area, a missing
/// photo, or a photo that decoded to something unusable. The details step
/// already requires a photo and a resolved location before enabling save,
/// so this is a defensive fallback for a stale client/server contract more
/// than a routine path.
class AddCatValidationException implements Exception {
  const AddCatValidationException();
}

/// Thrown when the submitted photo exceeds the server's size limit.
class AddCatMediaTooLargeException implements Exception {
  const AddCatMediaTooLargeException();
}

/// Thrown when the submitted photo isn't a supported image type.
class AddCatUnsupportedMediaException implements Exception {
  const AddCatUnsupportedMediaException();
}

/// Thrown when `POST /v1/cats` answers 422 — the submitted name or photo
/// was rejected by the pre-publication content classifier (issue #241,
/// docs/product/trust.md). A stable, recoverable validation-class outcome,
/// not a report to anyone: the caller's own name and photo are left
/// exactly as entered so the ui can offer edit/replace/remove and retry.
/// Distinct from [AddCatServerException] (the classifier's own failures —
/// timeout, malformed output — surface as the existing generic 500,
/// unchanged) so a genuine rejection never gets a "try again shortly"
/// framing.
class AddCatContentRejectedException implements Exception {
  const AddCatContentRejectedException();
}

/// Thrown for connection failures (offline, timeout).
class AddCatNetworkException implements Exception {
  const AddCatNetworkException();
}

/// Thrown for a 5xx or otherwise unmapped response.
class AddCatServerException implements Exception {
  const AddCatServerException();
}

/// One nearby existing cat the add-cat flow shows before final submission
/// (docs/product/cats.md/trust.md: advisory only, never blocks creation on
/// its own) — the same shape `GET /v1/cats/nearby` and `POST /v1/cats`'s
/// `409 { candidates }` both use (docs/architecture/api.md).
class DuplicateCandidate {
  const DuplicateCandidate({
    required this.id,
    required this.name,
    required this.primaryPhoto,
  });

  final String id;
  final String name;
  final String primaryPhoto;

  factory DuplicateCandidate.fromJson(Map<String, dynamic> json) {
    return DuplicateCandidate(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      primaryPhoto: json['primary_photo'] as String? ?? '',
    );
  }
}

/// Thrown when `POST /v1/cats` answers 409: nearby matches exist and the
/// caller hasn't yet confirmed the cat is different. Advisory, never a
/// dead end — carries the candidates so the caller can show them and retry
/// with `confirmedNew: true` to always proceed regardless.
class AddCatDuplicateCandidatesException implements Exception {
  const AddCatDuplicateCandidatesException(this.candidates);
  final List<DuplicateCandidate> candidates;
}

/// Cat creation and its non-blocking duplicate-candidate check (issue #70).
/// Ownership is always resolved from the caller's authenticated session by
/// the shared [ApiClient]'s bearer interceptor — this class never handles
/// that itself, and never triggers sign-in (see [AuthGate]).
class AddCatApi {
  AddCatApi(this._apiClient);

  final ApiClient _apiClient;

  /// Fetches cats within the standard 50m duplicate-check radius of (lat,
  /// lng) — public, so the check itself runs even before the caller signs
  /// in (docs/architecture/api.md: `GET /v1/cats/nearby` needs no bearer).
  Future<List<DuplicateCandidate>> fetchNearby({
    required double lat,
    required double lng,
  }) async {
    try {
      final response = await _apiClient.dio.get<List<dynamic>>(
        '/v1/cats/nearby',
        queryParameters: {'lat': lat, 'lng': lng, 'radius': 50},
      );
      final body = response.data ?? const [];
      return body
          .map((e) => DuplicateCandidate.fromJson(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  /// Creates a new cat with its required initial photo. photoBytes/
  /// photoFilename come from the picked image (read via `XFile.readAsBytes`,
  /// never a raw file path — `dart:io`'s `File`/`MultipartFile.fromFile`
  /// aren't available on the flutter web target this app also ships, see
  /// docs/architecture/flutter.md). idempotencyKey must be the same value
  /// across retries of the same attempt so a retried submission can never
  /// create a duplicate cat (issue #70). [onSendProgress] reports raw
  /// request-body bytes as the multipart upload (dominated by the photo)
  /// leaves the device — the ui's photo-upload percentage
  /// (docs/design/app-states.md, mutation affordances) derives from it.
  Future<CatDetail> createCat({
    required double lat,
    required double lng,
    String? name,
    required bool confirmedNew,
    required Uint8List photoBytes,
    required String photoFilename,
    required String idempotencyKey,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    try {
      final formData = FormData.fromMap({
        'lat': lat.toString(),
        'lng': lng.toString(),
        if (name != null && name.isNotEmpty) 'name': name,
        // docs/architecture/api.md: confirmed_new is "true"/absent — never
        // sent as the literal string "false", matching that contract.
        if (confirmedNew) 'confirmed_new': 'true',
        'photo': MultipartFile.fromBytes(photoBytes, filename: photoFilename),
      });
      final response = await _apiClient.dio.post<Map<String, dynamic>>(
        '/v1/cats',
        data: formData,
        options: Options(headers: {'Idempotency-Key': idempotencyKey}),
        onSendProgress: onSendProgress,
      );
      final body = response.data;
      if (body == null) throw const AddCatServerException();
      return CatDetail.fromJson(body['cat'] as Map<String, dynamic>);
    } on DioException catch (e) {
      throw _mapCreateError(e);
    }
  }

  Exception _mapError(DioException e) {
    final status = e.response?.statusCode;
    if (status == 401) return const AddCatUnauthorizedException();
    if (status != null) return const AddCatServerException();
    return const AddCatNetworkException();
  }

  Exception _mapCreateError(DioException e) {
    final status = e.response?.statusCode;
    switch (status) {
      case 401:
        return const AddCatUnauthorizedException();
      case 400:
        return const AddCatValidationException();
      case 409:
        final body = e.response?.data as Map<String, dynamic>?;
        final rawCandidates = body?['candidates'] as List<dynamic>? ?? const [];
        return AddCatDuplicateCandidatesException(
          rawCandidates
              .map(
                (c) => DuplicateCandidate.fromJson(c as Map<String, dynamic>),
              )
              .toList(),
        );
      case 413:
        return const AddCatMediaTooLargeException();
      case 415:
        return const AddCatUnsupportedMediaException();
      case 422:
        return const AddCatContentRejectedException();
    }
    if (status != null) return const AddCatServerException();
    return const AddCatNetworkException();
  }
}

final addCatApiProvider = Provider<AddCatApi>(
  (ref) => AddCatApi(ref.watch(apiClientProvider)),
);
