import 'package:dio/dio.dart';

import 'package:app/core/identity/session_identity.dart';

/// Attaches the stored `Authorization: Bearer` access token to every
/// outbound request that targets the configured tekir API origin. If no
/// session is available yet (never logged in, still restoring, or
/// expired), the header is omitted and the request proceeds as a guest —
/// mirrors [DeviceInterceptor] exactly, including the same same-origin
/// guard, except it attaches a bearer token instead of a device token
/// (docs/architecture/flutter.md: "device and bearer credentials use
/// separate interceptors and headers").
///
/// The interceptor reads from [SessionIdentityService.cached] synchronously
/// to avoid blocking the request pipeline — it never triggers a refresh.
/// Refreshing is a separate concern managed by [sessionIdentityProvider]
/// and [SessionIdentityService.restore].
class BearerInterceptor extends Interceptor {
  BearerInterceptor({required this._service, required String apiBaseUrl})
    : _apiOrigin = _originOf(apiBaseUrl);

  final SessionIdentityService _service;
  final String _apiOrigin;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (_isTekir(options) && _service.cached != null) {
      options.headers['Authorization'] =
          'Bearer ${_service.cached!.accessToken}';
    }
    handler.next(options);
  }

  bool _isTekir(RequestOptions options) =>
      _originOf(options.uri.toString()) == _apiOrigin;

  static String _originOf(String url) {
    try {
      final uri = Uri.parse(url);
      final port = uri.hasPort ? uri.port : 0;
      return '${uri.scheme}://${uri.host}:$port';
    } catch (_) {
      return '';
    }
  }
}
