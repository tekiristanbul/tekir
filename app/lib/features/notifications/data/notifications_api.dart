import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import 'notification.dart';

/// Thrown when a notifications call answers 401 — the bearer session is
/// missing, expired, or otherwise invalid (an authenticated account is
/// required — an inbox is inherently account-owned state).
class NotificationsUnauthorizedException implements Exception {
  const NotificationsUnauthorizedException();
}

/// Thrown for connection failures (offline, timeout).
class NotificationsNetworkException implements Exception {
  const NotificationsNetworkException();
}

/// Thrown for a 5xx or otherwise unmapped response.
class NotificationsServerException implements Exception {
  const NotificationsServerException();
}

/// The authenticated account's own notification inbox (issue #78):
/// `Authorization: Bearer` is attached automatically by the shared
/// [ApiClient]'s interceptor once a session is cached, never handled by
/// this class itself.
class NotificationsApi {
  NotificationsApi(this._apiClient);

  final ApiClient _apiClient;

  /// Fetches one newest-first page of the caller's own notifications.
  /// cursor is the opaque next_cursor from a previous page; omit it for
  /// the first page.
  Future<NotificationsPage> fetch({String? cursor}) async {
    try {
      final response = await _apiClient.dio.get<Map<String, dynamic>>(
        '/v1/me/notifications',
        queryParameters: {'cursor': ?cursor},
      );
      return NotificationsPage.fromJson(response.data!);
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Future<void> markRead(String id) async {
    try {
      await _apiClient.dio.post<void>('/v1/me/notifications/$id/read');
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Exception _mapError(DioException e) {
    final status = e.response?.statusCode;
    if (status == 401) return const NotificationsUnauthorizedException();
    if (status != null) return const NotificationsServerException();
    return const NotificationsNetworkException();
  }
}

final notificationsApiProvider = Provider<NotificationsApi>(
  (ref) => NotificationsApi(ref.watch(apiClientProvider)),
);
