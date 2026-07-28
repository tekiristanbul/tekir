import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/env.dart';
import '../firebase/firebase_bootstrap.dart';
import 'analytics_events.dart';
import 'firebase_analytics_service.dart';

export 'analytics_events.dart';

/// Application-owned analytics contract (issue #84). Exactly one
/// implementation runs per process, selected by `ANALYTICS_PROVIDER`:
/// [NoopAnalyticsService] for `none` (the local/test default) and
/// [FirebaseAnalyticsService] for `firebase`. Product code only ever sees
/// this interface and [AnalyticsEvent] — no Firebase type leaks past the
/// adapter.
///
/// [log] is fire-and-forget and must never throw or block: analytics is
/// strictly additive, and an analytics failure must never break a user
/// action (issue #84's explicit constraint).
abstract class AnalyticsService {
  void log(AnalyticsEvent event);
}

/// The `none` provider: swallows every event. The local/test default, so
/// development and CI never emit product analytics (issue #84's
/// debug-vs-production separation). In debug builds each event is printed,
/// which doubles as the local way to eyeball the emitted vocabulary.
class NoopAnalyticsService implements AnalyticsService {
  const NoopAnalyticsService();

  @override
  void log(AnalyticsEvent event) {
    if (kDebugMode) {
      debugPrint('[analytics:none] ${event.name} ${event.params}');
    }
  }
}

/// Selects the analytics implementation from [Env.analyticsProvider].
/// Anything other than an exact `firebase` with an initialized Firebase app
/// — including a typo or a failed bootstrap — resolves to noop: unlike the
/// backend's fail-closed provider selection, the client must keep running
/// without analytics rather than refuse to start, because analytics may
/// never block the product (issue #84).
final analyticsProvider = Provider<AnalyticsService>((ref) {
  if (Env.analyticsProvider == 'firebase' && ref.watch(firebaseReadyProvider)) {
    return FirebaseAnalyticsService();
  }
  return const NoopAnalyticsService();
});
