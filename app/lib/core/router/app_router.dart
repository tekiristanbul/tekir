import 'package:go_router/go_router.dart';

import '../analytics/analytics.dart';
import '../../features/account/ui/account_screen.dart';
import '../../features/add_cat/ui/add_cat_screen.dart';
import '../../features/auth/ui/login_screen.dart';
import '../../features/badges/ui/badge_detail_screen.dart';
import '../../features/badges/ui/badges_screen.dart';
import '../../features/cat_detail/ui/cat_detail_screen.dart';
import '../../features/discover/ui/discover_screen.dart';
import '../../features/map/ui/map_screen.dart';
import '../../features/notifications/ui/notifications_screen.dart';
import '../../features/profile/ui/profile_screen.dart';
import 'app_shell.dart';

/// The 3 root tabs (Harita/Keşfet/Profil, issue #80 product-owner review,
/// finding 1) live inside a [StatefulShellRoute.indexedStack] wrapped by
/// [AppShell] — this matches the approved prototype's exact IA
/// (prototype/app.js:153-167's bottomNav) and keeps each branch's own
/// navigation state alive (via IndexedStack) when switching tabs. Every
/// other route (cat detail, login, account, add-cat, notifications,
/// badges) stays a plain top-level route, pushed on top of the shell — the
/// shell's chrome (nav bar + add-cat fab) disappears the moment one of
/// those is pushed, exactly like the prototype's per-screen bottomNav
/// visibility.
///
/// `/login` and `/account` are reachable directly (e.g. via `context.push`),
/// but no route here redirects or guards based on auth state — public
/// browsing must keep working unauthenticated, so gating happens only at
/// the point of a specific action, via [AuthGate], never by a router
/// redirect (see auth_gate.dart).
final appRouter = GoRouter(
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          AppShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/', builder: (context, state) => const MapScreen()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/discover',
              builder: (context, state) => const DiscoverScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/profile',
              builder: (context, state) => const ProfileScreen(),
            ),
          ],
        ),
      ],
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
