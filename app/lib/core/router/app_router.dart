import 'package:go_router/go_router.dart';

import '../../features/account/ui/account_screen.dart';
import '../../features/add_cat/ui/add_cat_screen.dart';
import '../../features/auth/ui/login_screen.dart';
import '../../features/cat_detail/ui/cat_detail_screen.dart';
import '../../features/map/ui/map_screen.dart';

/// Map is the first screen (docs/product/map.md). Remaining tabs (discover /
/// notifications) and modal contribution routes land with the real screens
/// (docs/architecture/flutter.md).
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
      path: '/cats/:id',
      builder: (context, state) =>
          CatDetailScreen(catId: state.pathParameters['id']!),
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
  ],
);
