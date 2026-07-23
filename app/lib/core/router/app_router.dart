import 'package:go_router/go_router.dart';

import '../../features/cat_detail/ui/cat_detail_screen.dart';
import '../../features/map/ui/map_screen.dart';

/// Map is the first screen (docs/product/map.md). Remaining tabs (discover /
/// notifications / account) and modal routes land with the real screens
/// (docs/architecture/flutter.md).
final appRouter = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (context, state) => const MapScreen()),
    GoRoute(
      path: '/cats/:id',
      builder: (context, state) =>
          CatDetailScreen(catId: state.pathParameters['id']!),
    ),
  ],
);
