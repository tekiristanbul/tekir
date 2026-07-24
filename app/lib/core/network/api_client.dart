import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/env.dart';
import '../identity/device_identity.dart';
import 'device_interceptor.dart';

/// Single entry point for backend calls. The [DeviceInterceptor] attaches
/// `X-Device-Token` when a stored identity is available. Registration itself
/// uses a separate [Dio] instance inside [DeviceIdentityService] to avoid a
/// circular dependency.
///
/// `dio` is public so feature-level `data/` files (see
/// docs/architecture/flutter.md) can build their own calls on top of the
/// shared client.
class ApiClient {
  ApiClient({Dio? dio, DeviceIdentityService? identityService})
    : dio = _buildDio(dio, identityService);

  final Dio dio;

  static Dio _buildDio(Dio? existing, DeviceIdentityService? svc) {
    final d =
        existing ??
        Dio(
          BaseOptions(
            baseUrl: Env.apiBaseUrl,
            connectTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 5),
          ),
        );
    if (svc != null) {
      d.interceptors.add(
        DeviceInterceptor(service: svc, apiBaseUrl: Env.apiBaseUrl),
      );
    }
    return d;
  }

  /// Hits the api's liveness endpoint.
  Future<bool> checkHealth() async {
    final response = await dio.get<void>('/healthz');
    return response.statusCode == 200;
  }
}

final apiClientProvider = Provider<ApiClient>((ref) {
  final svc = ref.watch(deviceIdentityServiceProvider);
  return ApiClient(identityService: svc);
});
