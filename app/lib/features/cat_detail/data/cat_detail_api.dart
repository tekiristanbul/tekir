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
}

final catDetailApiProvider = Provider<CatDetailApi>(
  (ref) => CatDetailApi(ref.watch(apiClientProvider)),
);
