import 'package:go_router/go_router.dart';

import '../../features/home/home_screen.dart';

/// Single placeholder route for the bootstrap workspace. Tabs (map /
/// discover / notifications / account) and modal routes land with the
/// real screens (docs/architecture/flutter.md).
final appRouter = GoRouter(
  routes: [GoRoute(path: '/', builder: (context, state) => const HomeScreen())],
);
