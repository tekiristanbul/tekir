import 'package:flutter/foundation.dart' show kReleaseMode;

/// Build-time environment configuration.
///
/// Override with `--dart-define=API_BASE_URL=https://...` at build/run time
/// (scripts/run_web.sh forwards the values found in app/.env.local).
class Env {
  /// Distinct from any real url, so an explicit
  /// `--dart-define=API_BASE_URL=http://localhost:8080` isn't mistaken for
  /// "unset" (issue #128 review).
  static const _unsetSentinel = '__unset__';

  static const _rawApiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: _unsetSentinel,
  );

  /// The `localhost` default only ever applies to debug/profile runs, where
  /// it points at a backend reachable from the same machine (issue #128). A
  /// release build that never received an explicit `API_BASE_URL` would
  /// otherwise launch normally, render the map, and silently fail to load
  /// any backend-backed content. Fail fast instead, with a diagnostic that
  /// names the fix.
  static final apiBaseUrl = resolveApiBaseUrl(
    raw: _rawApiBaseUrl == _unsetSentinel ? null : _rawApiBaseUrl,
    isRelease: kReleaseMode,
  );

  /// Extracted from [apiBaseUrl] so both branches are unit-testable —
  /// `kReleaseMode` is a compile-time const `flutter test` can't flip.
  /// `raw` is null when `API_BASE_URL` wasn't provided at build/run time.
  static String resolveApiBaseUrl({
    required String? raw,
    required bool isRelease,
  }) {
    if (raw != null) return raw;
    if (isRelease) {
      throw StateError(
        'API_BASE_URL was not provided. Release builds must set it '
        'explicitly, e.g. '
        '--dart-define=API_BASE_URL=https://app.tekir.istanbul/api. '
        'See DEVELOPMENT.md > "api base url".',
      );
    }
    return 'http://localhost:8080';
  }

  /// `none` | `firebase` (issue #84). Local/test default is `none`; the
  /// production 0.1 build sets `firebase` explicitly. Selection logic lives
  /// in core/analytics/analytics.dart.
  static const analyticsProvider = String.fromEnvironment(
    'ANALYTICS_PROVIDER',
    defaultValue: 'none',
  );

  /// `fake` | `fcm` — the client-side mirror of the backend's
  /// NOTIFICATION_PROVIDER vocabulary (issue #84). Under `fcm` the app
  /// initializes Firebase Messaging, requests real notification permission
  /// at the approved opt-in point, and registers its token; under the
  /// `fake` default the opt-in flow stays local-only ui state, matching
  /// the backend's fake sender.
  static const notificationProvider = String.fromEnvironment(
    'NOTIFICATION_PROVIDER',
    defaultValue: 'fake',
  );

  /// Web push only: the Firebase web push certificate key pair (vapid) from
  /// the Firebase console. Ignored on ios/android; without it, web token
  /// registration is skipped.
  static const fcmVapidKey = String.fromEnvironment(
    'FCM_VAPID_KEY',
    defaultValue: '',
  );

  static const _knownAnalyticsProviders = {'none', 'firebase'};
  static const _knownNotificationProviders = {'fake', 'fcm'};

  /// Diagnostics for [analyticsProvider]/[notificationProvider] (issue
  /// #131). Unlike [apiBaseUrl], an invalid value here must not fail
  /// startup — analytics.dart and push_notifications.dart already treat
  /// anything but an exact known value as the safe default, because
  /// analytics/push may never block the product (issue #84). That silent
  /// fallback would otherwise hide a typo'd `--dart-define` indefinitely,
  /// so surface it here instead.
  static List<String> unrecognizedProviderWarnings() =>
      unrecognizedProviderWarningsFor(
        analyticsProvider: analyticsProvider,
        notificationProvider: notificationProvider,
      );

  /// Extracted from [unrecognizedProviderWarnings] so it's unit-testable —
  /// [analyticsProvider]/[notificationProvider] are compile-time consts
  /// `flutter test` can't override, same reasoning as
  /// [resolveApiBaseUrl].
  static List<String> unrecognizedProviderWarningsFor({
    required String analyticsProvider,
    required String notificationProvider,
  }) {
    final warnings = <String>[];
    if (!_knownAnalyticsProviders.contains(analyticsProvider)) {
      warnings.add(
        'ANALYTICS_PROVIDER="$analyticsProvider" is not recognized '
        '(expected one of: ${_knownAnalyticsProviders.join(', ')}). '
        'Falling back to "none" — analytics is disabled. See '
        'DEVELOPMENT.md > "firebase (push + analytics, issue #84)".',
      );
    }
    if (!_knownNotificationProviders.contains(notificationProvider)) {
      warnings.add(
        'NOTIFICATION_PROVIDER="$notificationProvider" is not recognized '
        '(expected one of: ${_knownNotificationProviders.join(', ')}). '
        'Falling back to "fake" — push notifications are disabled. See '
        'DEVELOPMENT.md > "firebase (push + analytics, issue #84)".',
      );
    }
    return warnings;
  }
}
