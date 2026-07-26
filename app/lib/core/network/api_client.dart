import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/env.dart';
import '../identity/device_identity.dart';
import '../identity/session_identity.dart';
import 'bearer_interceptor.dart';
import 'device_interceptor.dart';

/// Single entry point for backend calls. The [DeviceInterceptor] attaches
/// `X-Device-Token` and the [BearerInterceptor] attaches `Authorization:
/// Bearer` when their respective identities are available — separate
/// interceptors and headers, per docs/architecture/flutter.md, so a request
/// can carry either, both, or neither. Registration/refresh themselves use
/// separate [Dio] instances inside [DeviceIdentityService]/
/// [SessionIdentityService] to avoid a circular dependency.
///
/// `dio` is public so feature-level `data/` files (see
/// docs/architecture/flutter.md) can build their own calls on top of the
/// shared client.
class ApiClient {
  ApiClient({
    Dio? dio,
    DeviceIdentityService? identityService,
    SessionIdentityService? sessionService,
  }) : dio = _buildDio(dio, identityService, sessionService);

  final Dio dio;

  static Dio _buildDio(
    Dio? existing,
    DeviceIdentityService? deviceSvc,
    SessionIdentityService? sessionSvc,
  ) {
    final d =
        existing ??
        Dio(
          BaseOptions(
            baseUrl: Env.apiBaseUrl,
            connectTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 5),
          ),
        );
    if (deviceSvc != null) {
      d.interceptors.add(
        DeviceInterceptor(service: deviceSvc, apiBaseUrl: Env.apiBaseUrl),
      );
    }
    if (sessionSvc != null) {
      d.interceptors.add(
        BearerInterceptor(service: sessionSvc, apiBaseUrl: Env.apiBaseUrl),
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
  final deviceSvc = ref.watch(deviceIdentityServiceProvider);
  final sessionSvc = ref.watch(sessionIdentityServiceProvider);
  return ApiClient(identityService: deviceSvc, sessionService: sessionSvc);
});
