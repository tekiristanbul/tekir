import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/env.dart';
import '../identity/device_identity.dart';
import '../identity/session_identity.dart';
import 'bearer_interceptor.dart';
import 'device_interceptor.dart';
import 'session_refresh_interceptor.dart';

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

  /// The read budget for a request that uploads media. The shared
  /// [BaseOptions.receiveTimeout] is sized for a plain read; a media write
  /// keeps the connection open while the backend decodes the image,
  /// normalizes its orientation, re-encodes it, stores it, and (once issue
  /// #241 ships) has it classified — all inside the same request.
  ///
  /// This is not a comfort setting. At the previous shared 5s the backend
  /// logged `POST /v1/cats` failing at 5.1s with the client already gone
  /// ("context canceled"), while a successful create on the same device
  /// took 3.3s: creating a cat was a coin flip decided by photo size and
  /// signal strength.
  static const Duration mediaUploadTimeout = Duration(seconds: 60);

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
            // A read answers in well under a second; anything slower is a
            // network the user is better off being told about.
            receiveTimeout: const Duration(seconds: 10),
            sendTimeout: const Duration(seconds: 30),
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
      // Reacts to a 401 the way BearerInterceptor's own doc defers to:
      // refreshing is a separate concern, handled here rather than in the
      // header-attaching interceptor itself (issue #173).
      d.interceptors.add(
        SessionRefreshInterceptor(
          dio: d,
          service: sessionSvc,
          apiBaseUrl: Env.apiBaseUrl,
        ),
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
