import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/analytics/analytics.dart';

/// The full required 0.1 event-name vocabulary from issue #84 — kept
/// verbatim here so a rename in the contract file fails a test instead of
/// silently splitting the funnel in the analytics backend.
const requiredEventNames = {
  'onboarding_completed',
  'location_permission_result',
  'screen_view',
  'cat_opened',
  'auth_gate_shown',
  'auth_completed',
  'auth_failed',
  'follow_created',
  'follow_removed',
  'ordinary_update_created',
  'needs_help_created',
  'cat_created',
  'discover_view_selected',
  'notification_permission_result',
  'notification_received',
  'notification_opened',
};

/// Every constructable event, one instance per constructor, exercising
/// every enum parameter with a representative value.
List<AnalyticsEvent> allEvents() => [
  const AnalyticsEvent.onboardingCompleted(),
  AnalyticsEvent.locationPermissionResult(AnalyticsResult.permissionDenied),
  AnalyticsEvent.screenView(AnalyticsScreen.catDetail),
  AnalyticsEvent.catOpened(AnalyticsSource.discoverNeedsHelp),
  AnalyticsEvent.authGateShown(AnalyticsAuthIntent.ordinaryUpdate),
  AnalyticsEvent.authCompleted(AnalyticsAuthIntent.follow),
  AnalyticsEvent.authFailed(AnalyticsAuthIntent.addCat, AnalyticsResult.cancelled),
  AnalyticsEvent.followCreated(AnalyticsSource.map),
  AnalyticsEvent.followRemoved(null),
  AnalyticsEvent.ordinaryUpdateCreated(AnalyticsUpdateStatus.waterProvided),
  AnalyticsEvent.needsHelpCreated(AnalyticsNeedsHelpCategory.trapped),
  const AnalyticsEvent.catCreated(),
  AnalyticsEvent.discoverViewSelected(AnalyticsDiscoverView.following),
  AnalyticsEvent.notificationPermissionResult(AnalyticsResult.success),
  AnalyticsEvent.notificationReceived(AnalyticsNotificationState.foreground),
  AnalyticsEvent.notificationOpened(AnalyticsNotificationState.terminated),
];

/// The complete set of parameter values the enums can ever produce — the
/// closed vocabulary issue #84 requires.
Set<String> allowedParamValues() => {
  for (final v in AnalyticsSource.values) v.wire,
  for (final v in AnalyticsScreen.values) v.wire,
  for (final v in AnalyticsDiscoverView.values) v.wire,
  for (final v in AnalyticsAuthIntent.values) v.wire,
  for (final v in AnalyticsResult.values) v.wire,
  for (final v in AnalyticsUpdateStatus.values) v.wire,
  for (final v in AnalyticsNeedsHelpCategory.values) v.wire,
  for (final v in AnalyticsNotificationState.values) v.wire,
};

const allowedParamKeys = {
  'source',
  'screen_name',
  'discover_view',
  'auth_intent',
  'result',
  'update_status',
  'needs_help_category',
  'notification_state',
};

void main() {
  test('every required 0.1 event name is constructable, and nothing else', () {
    final names = allEvents().map((e) => e.name).toSet();
    expect(names, requiredEventNames);
  });

  test('every parameter key and value stays inside the bounded vocabulary', () {
    // Issue #84's privacy constraint, verified structurally: no event can
    // carry a phone number, display name, comment, cat name, coordinate,
    // token, or raw id, because every value must be one of the enums' wire
    // strings and every key one of the approved parameter names.
    for (final event in allEvents()) {
      for (final entry in event.params.entries) {
        expect(allowedParamKeys, contains(entry.key), reason: event.name);
        expect(
          allowedParamValues(),
          contains(entry.value),
          reason: '${event.name}.${entry.key}',
        );
      }
    }
  });

  test('a null follow source omits the parameter instead of guessing', () {
    expect(AnalyticsEvent.followCreated(null).params, isEmpty);
    expect(AnalyticsEvent.followRemoved(null).params, isEmpty);
    expect(AnalyticsEvent.followCreated(AnalyticsSource.notification).params, {
      'source': 'notification',
    });
  });

  test('needs-help categories clamp unknown ids to unknown', () {
    expect(
      AnalyticsNeedsHelpCategory.fromId('injured_or_sick'),
      AnalyticsNeedsHelpCategory.injuredOrSick,
    );
    expect(
      AnalyticsNeedsHelpCategory.fromId('free text from somewhere'),
      AnalyticsNeedsHelpCategory.unknown,
    );
    // 'unknown' itself is not a product category id — only the clamp target.
    expect(
      AnalyticsNeedsHelpCategory.fromId('unknown'),
      AnalyticsNeedsHelpCategory.unknown,
    );
  });

  test('noop service swallows events without error', () {
    const NoopAnalyticsService().log(const AnalyticsEvent.catCreated());
  });
}
