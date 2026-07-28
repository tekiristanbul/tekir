import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/analytics.dart';
import '../config/env.dart';
import '../firebase/firebase_bootstrap.dart';
import '../network/api_client.dart';
import '../router/app_router.dart';
import 'push_messaging_backend.dart';

/// Validates the cat id a push data payload deep-links to. Only a
/// canonical uuid is ever navigated to — a malformed or hostile payload is
/// dropped instead of being pushed into the router.
final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// Owns the client side of needs-help push (issue #84): permission at the
/// approved opt-in point, token registration/refresh against
/// `PUT /v1/devices/me`, and foreground/background/terminated
/// message handling with deep-link + duplicate-open protection.
///
/// Instantiated disabled unless `NOTIFICATION_PROVIDER=fcm` *and* Firebase
/// initialized (see bootstrapFirebase) — under the local `fake` default the
/// opt-in sheet stays the pre-#84 local-only ui state and none of this
/// runs. Every provider call is best-effort: push is additive, so a
/// failure (no google services, network down, permission api missing on a
/// platform) is logged in debug and swallowed, never surfaced as an error
/// state (the in-app notifications screen remains the source of truth).
class PushNotificationsService {
  PushNotificationsService({
    required PushMessagingBackend this._backend,
    required AnalyticsService this._analytics,
    required Dio this._dio,
    required void Function(String catId) this._openCatDetail,
    this._vapidKey = '',
  }) : _enabled = true;

  /// The inert variant wired when push is configured off ([Env]'s `fake`
  /// default) or Firebase failed to initialize.
  PushNotificationsService.disabled()
    : _backend = null,
      _analytics = null,
      _dio = null,
      _openCatDetail = null,
      _vapidKey = '',
      _enabled = false;

  final PushMessagingBackend? _backend;
  final AnalyticsService? _analytics;
  final Dio? _dio;
  final void Function(String catId)? _openCatDetail;
  final String _vapidKey;
  final bool _enabled;

  bool _started = false;

  /// Duplicate-open protection: the same physical tap can surface through
  /// more than one callback (e.g. initial-message and opened-app on some
  /// platforms) — one navigation per message, not one per callback.
  String? _lastOpenedKey;

  bool get isEnabled => _enabled;

  /// Hooks message/token streams and syncs the token if permission was
  /// already granted in an earlier session. Called once at startup; safe
  /// no-op when disabled.
  Future<void> start() async {
    if (!_enabled || _started) return;
    _started = true;

    _backend!.onTokenRefresh.listen(_registerToken, onError: _debugLog);
    _backend.onForegroundMessage.listen((message) {
      _analytics!.log(
        AnalyticsEvent.notificationReceived(
          AnalyticsNotificationState.foreground,
        ),
      );
      // no navigation and no system banner in the foreground — the in-app
      // notifications surface covers it (docs/product/notifications.md).
    }, onError: _debugLog);
    _backend.onMessageOpened.listen(
      (message) => _handleOpen(message, AnalyticsNotificationState.background),
      onError: _debugLog,
    );

    try {
      final initial = await _backend.takeInitialMessage();
      if (initial != null) {
        _handleOpen(initial, AnalyticsNotificationState.terminated);
      }
    } catch (error) {
      _debugLog(error);
    }

    try {
      // re-registers on every start once permission exists: covers token
      // rotation while the app was dead and a device row re-registration
      // (the backend moves the token off the stale row — issue #84).
      if (await _backend.currentPermission() == PushPermissionStatus.granted) {
        await _registerCurrentToken();
      }
    } catch (error) {
      _debugLog(error);
    }
  }

  /// The approved opt-in action (notification_optin_sheet, shown only
  /// after a follow — docs/product/notifications.md): requests real
  /// permission and registers the token when granted. Never called on
  /// first launch. Returns whether permission is granted.
  Future<bool> requestPermissionAndRegister() async {
    if (!_enabled) return false;
    try {
      final status = await _backend!.requestPermission();
      final granted = status == PushPermissionStatus.granted;
      _analytics!.log(
        AnalyticsEvent.notificationPermissionResult(
          granted ? AnalyticsResult.success : AnalyticsResult.permissionDenied,
        ),
      );
      if (granted) await _registerCurrentToken();
      return granted;
    } catch (error) {
      _debugLog(error);
      return false;
    }
  }

  Future<void> _registerCurrentToken() async {
    try {
      final token = await _backend!.getToken(
        vapidKey: kIsWeb && _vapidKey.isNotEmpty ? _vapidKey : null,
      );
      if (token == null || token.isEmpty) return;
      await _registerToken(token);
    } catch (error) {
      _debugLog(error);
    }
  }

  Future<void> _registerToken(String token) async {
    try {
      await _dio!.put<void>('/v1/devices/me', data: {'push_token': token});
    } catch (error) {
      // best-effort: the next start()/refresh retries. The token itself is
      // never logged (issue #84's redaction constraint).
      _debugLog(error);
    }
  }

  void _handleOpen(PushMessage message, AnalyticsNotificationState state) {
    final catId = message.data['cat_id'];
    final key = message.messageId ?? message.data['update_id'];
    if (key != null) {
      if (key == _lastOpenedKey) return;
      _lastOpenedKey = key;
    }
    _analytics!.log(AnalyticsEvent.notificationOpened(state));

    if (catId != null && _uuidPattern.hasMatch(catId)) {
      _openCatDetail!(catId);
    }
  }

  void _debugLog(Object error) {
    if (!kDebugMode) return;
    if (error is DioException) {
      debugPrint('[push] dio:${error.type}');
      return;
    }
    debugPrint('[push] ${error.runtimeType}');
  }
}

final pushNotificationsServiceProvider = Provider<PushNotificationsService>((
  ref,
) {
  if (Env.notificationProvider != 'fcm' || !ref.watch(firebaseReadyProvider)) {
    return PushNotificationsService.disabled();
  }
  return PushNotificationsService(
    backend: FirebaseMessagingBackend(),
    analytics: ref.watch(analyticsProvider),
    dio: ref.watch(apiClientProvider).dio,
    // deep-link to the same cat detail surface the notifications screen
    // uses; the extra carries the bounded cat_opened source (issue #84).
    openCatDetail: (catId) =>
        appRouter.push('/cats/$catId', extra: AnalyticsSource.notification),
    vapidKey: Env.fcmVapidKey,
  );
});
