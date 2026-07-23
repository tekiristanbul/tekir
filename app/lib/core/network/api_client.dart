import 'package:dio/dio.dart';

import '../config/env.dart';

/// Single entry point for backend calls. Auth headers (X-Device-Token,
/// Authorization: Bearer) are added here via an interceptor once device
/// identity and login exist — out of scope for the bootstrap workspace.
class ApiClient {
  ApiClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: Env.apiBaseUrl,
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 5),
            ),
          );

  final Dio _dio;

  /// Hits the api's liveness endpoint. Used by the placeholder home screen
  /// to prove the app can reach the local api.
  Future<bool> checkHealth() async {
    final response = await _dio.get<void>('/healthz');
    return response.statusCode == 200;
  }
}
