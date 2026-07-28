import 'package:go_router/go_router.dart';

import 'analytics.dart';

/// Maps a concrete route path onto the approved [AnalyticsScreen]
/// vocabulary, or null for anything unrecognized. Only the route *shape*
/// is inspected — path parameters (cat ids, badge ids) are never carried
/// into the event (issue #84's raw-id constraint).
AnalyticsScreen? analyticsScreenForPath(String path) {
  if (path == '/') return AnalyticsScreen.map;
  if (path == '/discover') return AnalyticsScreen.discover;
  if (path == '/profile') return AnalyticsScreen.profile;
  if (path == '/login') return AnalyticsScreen.login;
  if (path == '/account') return AnalyticsScreen.account;
  if (path == '/add-cat') return AnalyticsScreen.addCat;
  if (path == '/notifications') return AnalyticsScreen.notifications;
  if (path == '/badges') return AnalyticsScreen.badges;
  if (path.startsWith('/badges/')) return AnalyticsScreen.badgeDetail;
  if (path.startsWith('/cats/')) return AnalyticsScreen.catDetail;
  return null;
}

/// Emits one `screen_view` per navigation change, from a single listener on
/// the router delegate — covering pushes, pops, and shell tab switches
/// alike, so no screen has to instrument itself. Consecutive duplicates
/// (e.g. a rebuild without a location change) are suppressed.
void attachScreenViewLogging(GoRouter router, AnalyticsService analytics) {
  String? lastPath;
  void emit() {
    final path = router.routerDelegate.currentConfiguration.uri.path;
    if (path == lastPath) return;
    lastPath = path;
    final screen = analyticsScreenForPath(path);
    if (screen != null) analytics.log(AnalyticsEvent.screenView(screen));
  }

  emit(); // the initial location is a view too.
  router.routerDelegate.addListener(emit);
}
