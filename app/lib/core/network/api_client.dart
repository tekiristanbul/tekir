import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/env.dart';

/// Single entry point for backend calls. Auth headers (X-Device-Token,
/// Authorization: Bearer) are added here via an interceptor once device
/// identity and login exist — out of scope for the bootstrap workspace.
/// `dio` is public so feature-level `data/` files (see docs/architecture/flutter.md)
/// can build their own calls on top of the shared client.
class ApiClient {
  ApiClient({Dio? dio})
    : dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: Env.apiBaseUrl,
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 5),
            ),
          );

  final Dio dio;

  /// Hits the api's liveness endpoint.
  Future<bool> checkHealth() async {
    final response = await dio.get<void>('/healthz');
    return response.statusCode == 200;
  }
}

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());
