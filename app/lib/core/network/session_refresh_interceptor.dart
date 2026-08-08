import 'package:dio/dio.dart';

import 'package:app/core/identity/session_identity.dart';

/// Reacts to a 401 from the tekir api by refreshing the session once and
/// retrying the original request before letting the error surface (issue
/// #173). [SessionNotifier.refreshIfNeeded] (issue #155) only covers the
/// background-to-foreground transition — nothing previously refreshed
/// reactively when a request 401s while the app stays in the foreground
/// (e.g. the access token expires mid-session), so every caller downstream
/// had to map that 401 into its own "unauthorized, try again" error even
/// though a silent refresh-and-retry would have succeeded.
///
/// Marks the retried request via [RequestOptions.extra] so a request that
/// still 401s after a successful refresh — or one whose refresh itself
/// fails — surfaces the original error immediately instead of retrying
/// forever. Same same-origin guard as [DeviceInterceptor]/[BearerInterceptor]
/// — never attempts a refresh for a 401 from a third-party endpoint.
class SessionRefreshInterceptor extends Interceptor {
  SessionRefreshInterceptor({
    required this._dio,
    required this._service,
    required String apiBaseUrl,
  }) : _apiOrigin = _originOf(apiBaseUrl);

  final Dio _dio;
  final SessionIdentityService _service;
  final String _apiOrigin;

  static const _retriedKey = 'sessionRefreshRetried';

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    final staleToken = _service.cached?.accessToken;
    if (err.response?.statusCode != 401 ||
        options.extra[_retriedKey] == true ||
        !_isTekir(options) ||
        staleToken == null) {
      handler.next(err);
      return;
    }
    options.extra[_retriedKey] = true;

    // refreshIfExpired() only actually rotates when the local `exp` claim
    // agrees the token is stale — if it no-ops (same token back), retrying
    // would just replay the exact request that already 401ed, so give up
    // immediately instead of spending a doomed round trip.
    final refreshed = await _service.refreshIfExpired();
    if (refreshed == null || refreshed.accessToken == staleToken) {
      handler.next(err);
      return;
    }

    // A FormData body (e.g. CatDetailApi.uploadMedia, AddCatApi.createCat)
    // can only be finalized once — dio calls finalize() on send, so
    // replaying the same instance on retry throws a StateError instead of
    // reissuing the request. clone() rebuilds an equivalent, unfinalized
    // FormData for the retry.
    final body = options.data;
    if (body is FormData) {
      options.data = body.clone();
    }

    try {
      final response = await _dio.fetch<dynamic>(options);
      handler.resolve(response);
    } on DioException catch (retryError) {
      handler.next(retryError);
    }
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
