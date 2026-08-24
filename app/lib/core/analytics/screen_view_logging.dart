import 'package:go_router/go_router.dart';

import 'analytics.dart';

/// Maps a concrete route path onto the approved [AnalyticsScreen]
/// vocabulary, or null for anything unrecognized.
///
/// [AnalyticsScreen.discover] has no entry here since issue #284: the
/// discover surfaces moved into the search panel over the map, which is not
/// a route of its own. The panel emits that screen_view itself, so the
/// event's meaning is unchanged — only the thing that emits it moved. Only the route *shape*
/// is inspected — path parameters (cat ids, badge ids) are never carried
/// into the event (issue #84's raw-id constraint).
AnalyticsScreen? analyticsScreenForPath(String path) {
  if (path == '/') return AnalyticsScreen.map;
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
/// the router delegate — covering pushes and pops alike, so no screen has
/// to instrument itself (the search panel is the one exception; see
/// [analyticsScreenForPath]). Consecutive duplicates
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
