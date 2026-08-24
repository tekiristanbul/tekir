import 'package:go_router/go_router.dart';

import '../analytics/analytics.dart';
import '../../features/account/ui/account_screen.dart';
import '../../features/blocks/ui/blocked_accounts_screen.dart';
import '../../features/add_cat/ui/add_cat_screen.dart';
import '../../features/auth/ui/login_screen.dart';
import '../../features/badges/ui/badge_detail_screen.dart';
import '../../features/badges/ui/badges_screen.dart';
import '../../features/cat_detail/ui/cat_detail_screen.dart';
import '../../features/map/ui/map_screen.dart';
import '../../features/notifications/ui/notifications_screen.dart';
import '../../features/profile/ui/profile_screen.dart';

/// The map is the application (issue #284, approved design artboard 01).
///
/// There is no shell and no tab bar. `/` is the map, full height, and every
/// other screen is a plain route pushed over it — including the profile,
/// which used to be a peer tab and is now what the top strip's avatar
/// opens. The keşfet tab is gone entirely: its three surfaces live in the
/// search panel the strip's search pill opens
/// (features/discover/ui/cat_search_panel.dart), which is not a route of
/// its own but a surface over the map, so picking a cat can hand it back to
/// the map instead of navigating away from it.
///
/// `/login` and `/account` are reachable directly (e.g. via `context.push`),
/// but no route here redirects or guards based on auth state — public
/// browsing must keep working unauthenticated, so gating happens only at
/// the point of a specific action, via [AuthGate], never by a router
/// redirect (see auth_gate.dart).
final appRouter = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (context, state) => const MapScreen()),
    GoRoute(
      path: '/profile',
      builder: (context, state) => const ProfileScreen(),
    ),
    GoRoute(
      path: '/cats/:id',
      // extra optionally carries the bounded cat_opened source (issue #84)
      // from the pushing surface; anything else — including a deep link's
      // absent extra — degrades to "no source", never a guessed one.
      builder: (context, state) => CatDetailScreen(
        catId: state.pathParameters['id']!,
        openSource: state.extra is AnalyticsSource
            ? state.extra as AnalyticsSource
            : null,
      ),
    ),
    GoRoute(
      path: '/login',
      builder: (context, state) =>
          LoginScreen(contextText: state.extra as String?),
    ),
    GoRoute(
      path: '/account',
      builder: (context, state) => const AccountScreen(),
    ),
    GoRoute(
      path: '/account/blocked',
      builder: (context, state) => const BlockedAccountsScreen(),
    ),
    GoRoute(
      path: '/add-cat',
      builder: (context, state) => const AddCatScreen(),
    ),
    GoRoute(
      path: '/notifications',
      builder: (context, state) => const NotificationsScreen(),
    ),
    GoRoute(path: '/badges', builder: (context, state) => const BadgesScreen()),
    GoRoute(
      path: '/badges/:id',
      builder: (context, state) =>
          BadgeDetailScreen(badgeId: state.pathParameters['id']!),
    ),
  ],
);
