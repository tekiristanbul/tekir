import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/network/api_client.dart';
import 'cat_marker.dart';

class CatsApi {
  CatsApi(this._apiClient);

  final ApiClient _apiClient;

  /// Fetches the cats inside [bounds]. bbox order matches docs/architecture/api.md:
  /// `min_lng,min_lat,max_lng,max_lat`.
  Future<List<CatMarker>> fetchInBounds(LatLngBounds bounds) async {
    final bbox =
        '${bounds.southwest.longitude},${bounds.southwest.latitude},'
        '${bounds.northeast.longitude},${bounds.northeast.latitude}';
    final response = await _apiClient.dio.get<List<dynamic>>(
      '/v1/cats',
      queryParameters: {'bbox': bbox},
    );

    final data = response.data ?? const [];
    return data
        .map((e) => CatMarker.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

final catsApiProvider = Provider<CatsApi>(
  (ref) => CatsApi(ref.watch(apiClientProvider)),
);
