import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import 'discover_cat.dart';

/// The two location-aware discover surfaces `GET /v1/cats/discover`'s
/// `filter` query param accepts (docs/architecture/api.md, issue #82). The
/// third discover surface (followed cats) isn't a value here at all — it
/// stays on `GET /v1/me/follows` via [FollowsApi], never this endpoint.
enum DiscoverFilter {
  nearby('nearby'),
  needsHelp('needs_help');

  const DiscoverFilter(this.wireValue);

  final String wireValue;
}

/// One nearest-first page of `GET /v1/cats/discover`. [nextCursor] is null
/// once the last page has been served.
class DiscoverPage {
  const DiscoverPage({required this.items, this.nextCursor});

  final List<DiscoverCat> items;
  final String? nextCursor;
}

/// Thrown when the server rejected `lat`/`lng` as outside the product's
/// istanbul boundary (`400 { error: "invalid area" }`) — distinct from a
/// generic server error so the screen can show a message that actually
/// explains what happened, rather than a bare "connection problem" retry
/// prompt for a location that will never resolve differently on retry.
class DiscoverAreaOutOfBoundsException implements Exception {
  const DiscoverAreaOutOfBoundsException();
}

/// Thrown for connection failures (offline, timeout).
class DiscoverNetworkException implements Exception {
  const DiscoverNetworkException();
}

/// Thrown for a 5xx, an invalid cursor, or any other unmapped response.
class DiscoverServerException implements Exception {
  const DiscoverServerException();
}

/// `GET /v1/cats/discover` (issue #82) — public, guest-readable, exactly
/// like [CatsApi.fetchInBounds]: no bearer is attached or required for
/// either filter.
class DiscoverApi {
  DiscoverApi(this._apiClient);

  final ApiClient _apiClient;

  Future<DiscoverPage> fetch({
    required DiscoverFilter filter,
    required double lat,
    required double lng,
    String? cursor,
  }) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '/v1/cats/discover',
        queryParameters: {
          'lat': lat,
          'lng': lng,
          'filter': filter.wireValue,
          'cursor': ?cursor,
        },
      );
      final body = response.data ?? const <String, dynamic>{};
      final items = (body['items'] as List<dynamic>? ?? const [])
          .map((e) => DiscoverCat.fromJson(e as Map<String, dynamic>))
          .toList();
      return DiscoverPage(
        items: items,
        nextCursor: body['next_cursor'] as String?,
      );
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Exception _mapError(DioException e) {
    final status = e.response?.statusCode;
    if (status == 400) {
      final data = e.response?.data;
      if (data is Map && data['error'] == 'invalid area') {
        return const DiscoverAreaOutOfBoundsException();
      }
    }
    if (status != null) return const DiscoverServerException();
    return const DiscoverNetworkException();
  }
}

final discoverApiProvider = Provider<DiscoverApi>(
  (ref) => DiscoverApi(ref.watch(apiClientProvider)),
);
