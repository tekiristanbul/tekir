import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';

import 'analytics.dart';

/// Sends one event to Google Analytics for Firebase — kept injectable so
/// tests never need a live Firebase app.
typedef AnalyticsEventSink =
    Future<void> Function(String name, Map<String, Object> params);

/// The `firebase` analytics adapter (issue #84): forwards [AnalyticsEvent]s
/// to Google Analytics for Firebase. The only place in the app that touches
/// a Firebase Analytics type.
///
/// Every failure — Firebase not initialized (e.g. `flutterfire configure`
/// hasn't run), a platform-channel error, an offline queue problem — is
/// swallowed after a debug print: an analytics outage must never surface to
/// the user or block an action (issue #84).
///
/// No user id is ever set, and no user properties are registered — 0.1
/// measures anonymous, bounded behavior only (issue #84's privacy
/// constraints; ad ids, audiences, and personalization stay disabled in the
/// Firebase project configuration).
class FirebaseAnalyticsService implements AnalyticsService {
  FirebaseAnalyticsService({this._sink});

  final AnalyticsEventSink? _sink;

  @override
  void log(AnalyticsEvent event) {
    final sink =
        _sink ??
        (name, params) =>
            FirebaseAnalytics.instance.logEvent(name: name, parameters: params);
    // Deliberately unawaited fire-and-forget; the catch covers both sync
    // and async failures.
    Future<void>(() => sink(event.name, Map.of(event.params))).catchError((
      Object error,
    ) {
      if (kDebugMode) {
        debugPrint('[analytics:firebase] drop ${event.name}: $error');
      }
    });
  }
}
