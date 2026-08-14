import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

/// Thrown when a blocks call answers 401 — the bearer session is missing,
/// expired, or otherwise invalid (issue #234: blocking requires an account,
/// same as reporting or following).
class BlockUnauthorizedException implements Exception {
  const BlockUnauthorizedException();
}

/// Thrown when the account being blocked no longer exists.
class BlockTargetNotFoundException implements Exception {
  const BlockTargetNotFoundException();
}

/// Thrown for a rejected request — a malformed account id, or an attempt to
/// block yourself. The UI never offers either, so this is only reachable
/// through a stale client or a genuine race.
class BlockValidationException implements Exception {
  const BlockValidationException();
}

/// Thrown for connection failures (offline, timeout).
class BlockNetworkException implements Exception {
  const BlockNetworkException();
}

/// Thrown for a 5xx or otherwise unmapped response.
class BlockServerException implements Exception {
  const BlockServerException();
}

/// One entry of the caller's own block list.
class BlockedAccount {
  const BlockedAccount({
    required this.userId,
    required this.displayName,
    required this.createdAt,
  });

  final String userId;
  final String? displayName;
  final DateTime createdAt;

  factory BlockedAccount.fromJson(Map<String, dynamic> json) {
    return BlockedAccount(
      userId: json['user_id'] as String,
      displayName: json['display_name'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

/// Account-to-account blocking (issue #234). The blocker is always the
/// bearer session — attached by the shared [ApiClient]'s interceptor — and
/// is never sent in a request body. Blocking is visibility only: the server
/// hides the blocked account's cats from this caller's reads and deletes
/// nothing, and the blocked account is never notified.
class BlocksApi {
  BlocksApi(this._apiClient);

  final ApiClient _apiClient;

  Future<void> block(String userId) async {
    try {
      await _apiClient.dio.post<void>(
        '/v1/me/blocks',
        data: {'blocked_user_id': userId},
      );
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Future<void> unblock(String userId) async {
    try {
      await _apiClient.dio.delete<void>('/v1/me/blocks/$userId');
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Future<List<BlockedAccount>> listBlocked() async {
    try {
      final response = await _apiClient.dio.get<List<dynamic>>('/v1/me/blocks');
      final data = response.data ?? const [];
      return data
          .map((e) => BlockedAccount.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Exception _mapError(DioException e) {
    final status = e.response?.statusCode;
    switch (status) {
      case 400:
        return const BlockValidationException();
      case 401:
        return const BlockUnauthorizedException();
      case 404:
        return const BlockTargetNotFoundException();
    }
    if (status != null) return const BlockServerException();
    return const BlockNetworkException();
  }
}

final blocksApiProvider = Provider<BlocksApi>(
  (ref) => BlocksApi(ref.watch(apiClientProvider)),
);
