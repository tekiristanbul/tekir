/// Build-time environment configuration.
///
/// Override with `--dart-define=API_BASE_URL=https://...` at build/run time
/// (scripts/run_web.sh forwards the values found in app/.env.local).
class Env {
  static const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8080',
  );

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
}
