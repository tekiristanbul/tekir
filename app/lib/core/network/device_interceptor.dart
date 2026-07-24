import 'package:dio/dio.dart';

import 'package:app/core/identity/device_identity.dart';

/// Attaches the stored `X-Device-Token` to every outbound request that
/// targets the configured tekir API origin. If no identity is available yet
/// (initialization still in progress or failed), the header is omitted and
/// the request proceeds unauthenticated so public read routes continue to work.
///
/// The interceptor reads from [DeviceIdentityService.cached] synchronously to
/// avoid blocking the request pipeline — it never triggers registration.
/// Registration is a separate concern managed by [deviceIdentityProvider].
///
/// The token is only attached when the request destination matches the api
/// origin, preventing accidental credential leakage to third-party endpoints.
class DeviceInterceptor extends Interceptor {
  DeviceInterceptor({
    required DeviceIdentityService service,
    required String apiBaseUrl,
  }) : _service = service,
       _apiOrigin = _originOf(apiBaseUrl);

  final DeviceIdentityService _service;
  final String _apiOrigin;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (_isTekir(options) && _service.cached != null) {
      options.headers['X-Device-Token'] = _service.cached!.deviceToken;
    }
    handler.next(options);
  }

  /// Returns true when [options] targets the same scheme+host+port as the
  /// tekir api base url. Uses port 0 as a sentinel for "no explicit port".
  bool _isTekir(RequestOptions options) =>
      _originOf(options.uri.toString()) == _apiOrigin;

  /// Extracts the scheme+host+port origin from a URL string.
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
