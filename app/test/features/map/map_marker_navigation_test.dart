import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:app/core/router/app_router.dart';
import 'package:app/features/cat_detail/data/cat_detail.dart';
import 'package:app/features/cat_detail/ui/cat_detail_notifier.dart';
import 'package:app/features/cat_detail/ui/cat_detail_screen.dart';
import 'package:app/features/map/data/location_service.dart';
import 'package:app/features/map/ui/cats_map_notifier.dart';
import 'package:app/features/map/ui/map_screen.dart';

const _catId = '00000000-0000-4000-8000-000000000010';

// GoogleMap is a real platform view under google_maps_flutter; the moment
// MapScreen's marker set becomes non-empty, mounting it under `flutter
// test` throws MissingPluginException (no platform_views channel
// implementation in the test harness) — confirmed by hand, not something a
// widget test can drive around. That's exactly why this project's existing
// map tests (test/widget_test.dart) only ever exercise the empty/loading
// states and never populate real markers. `_onCatSelected` itself is a
// one-line `context.push('/cats/${cat.id}')` (see map_screen.dart); what
// this test actually verifies — and can verify, without a platform view —
// is that calling exactly that navigation, through the app's real
// appRouter, lands on the correct cat and renders it.
class _FixedCatDetailNotifier extends CatDetailNotifier {
  _FixedCatDetailNotifier(super.catId, this._state);

  final CatDetailState _state;

  @override
  CatDetailState build() => _state;

  @override
  Future<void> load() async {}
}

void main() {
  testWidgets(
    'pushing a cat-detail route (as a marker tap does) opens that cat\'s detail view',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            initialLocationProvider.overrideWith(
              (ref) async => const ResolvedLocation(
                center: istanbulFallback,
                isFallback: false,
              ),
            ),
            catDetailProvider(_catId).overrideWith(
              () => _FixedCatDetailNotifier(
                _catId,
                CatDetailState(
                  detail: CatDetail(
                    id: _catId,
                    name: 'tekir',
                    lat: 41.0256,
                    lng: 28.9744,
                    primaryPhoto: null,
                    traits: const [],
                    createdAt: DateTime.utc(2026, 1, 1),
                    lastUpdateAt: null,
                  ),
                  hasLoadedOnce: true,
                ),
              ),
            ),
            // empty markers only: mounting MapScreen must not itself reach
            // into the marker-rebuild/platform-view path.
            catsMapProvider.overrideWith(_EmptyCatsMapNotifier.new),
          ],
          child: MaterialApp.router(routerConfig: appRouter),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(MapScreen), findsOneWidget);

      // exactly what MapScreen._onCatSelected does on a marker tap.
      GoRouter.of(tester.element(find.byType(MapScreen))).push('/cats/$_catId');
      await tester.pumpAndSettle();

      expect(find.byType(CatDetailScreen), findsOneWidget);
      expect(find.text('tekir'), findsWidgets);
    },
  );
}

class _EmptyCatsMapNotifier extends CatsMapNotifier {
  @override
  CatsMapState build() => const CatsMapState(hasLoadedOnce: true);
}
