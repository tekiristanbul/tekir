import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/router/app_router.dart';
import 'package:app/features/cat_detail/data/cat_detail.dart';
import 'package:app/features/cat_detail/ui/cat_detail_notifier.dart';
import 'package:app/features/cat_detail/ui/cat_detail_screen.dart';
import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/map/data/location_service.dart';
import 'package:app/features/map/ui/cat_preview_sheet.dart';
import 'package:app/features/map/ui/cats_map_notifier.dart';
import 'package:app/features/map/ui/map_screen.dart';

const _catId = '00000000-0000-4000-8000-000000000010';

const _marker = CatMarker(
  id: _catId,
  name: 'tekir',
  primaryPhoto: '',
  lat: 41.02561,
  lng: 28.97440,
  areaLabel: 'Galata Kulesi çevresi, Beyoğlu',
);

// GoogleMap is a real platform view under google_maps_flutter; the moment
// MapScreen's marker set becomes non-empty, mounting it under `flutter
// test` throws MissingPluginException (no platform_views channel
// implementation in the test harness) — confirmed by hand, not something a
// widget test can drive around. That's exactly why this project's existing
// map tests (test/widget_test.dart) only ever exercise the empty/loading
// states and never populate real markers. What these tests actually drive
// — and can drive, without a platform view — is exactly what a real marker
// tap does under the hood: CatsMapNotifier.selectCat(marker), which
// MapScreen listens to and reacts to the same way regardless of what
// triggered it (see map_screen.dart's ref.listen(catsMapProvider, ...)).
class _FixedCatDetailNotifier extends CatDetailNotifier {
  _FixedCatDetailNotifier(super.catId, this._state);

  final CatDetailState _state;

  @override
  CatDetailState build() => _state;

  @override
  Future<void> load() async {}
}

class _EmptyCatsMapNotifier extends CatsMapNotifier {
  @override
  CatsMapState build() => const CatsMapState(hasLoadedOnce: true);
}

// A guest session (never restored) — these tests are about navigation, not
// the follow feature (issue #65); this just keeps CatDetailScreen's
// FollowButton from ever reaching a real network call when it mounts.
class _GuestSessionIdentityService implements SessionIdentityService {
  @override
  SessionIdentity? get cached => null;

  @override
  Future<SessionIdentity?> restore() async => null;

  @override
  Future<void> save(SessionIdentity identity) async {}

  @override
  Future<void> logout() async {}
}

Future<void> _pumpMap(WidgetTester tester) async {
  // appRouter is a module-level singleton (app_router.dart), so its
  // location persists across tests within this same file/isolate unless
  // reset — without this, a test that navigated to /cats/:id would leave
  // later tests seeing CatDetailScreen instead of a fresh MapScreen.
  appRouter.go('/');
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
                lat: 41.02561,
                lng: 28.97440,
                areaLabel: 'Galata Kulesi çevresi, Beyoğlu',
                primaryPhoto: null,
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
        sessionIdentityServiceProvider.overrideWithValue(
          _GuestSessionIdentityService(),
        ),
      ],
      child: MaterialApp.router(routerConfig: appRouter),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets(
    'selecting a cat (as a marker tap does) opens the preview sheet over the map — not the detail screen directly',
    (tester) async {
      await _pumpMap(tester);
      expect(find.byType(MapScreen), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MapScreen)),
      );
      container.read(catsMapProvider.notifier).selectCat(_marker);
      await tester.pumpAndSettle();

      expect(find.byType(CatPreviewSheet), findsOneWidget);
      expect(find.byType(CatDetailScreen), findsNothing);
      expect(find.text('tekir'), findsWidgets);
      expect(find.text('Galata Kulesi çevresi, Beyoğlu'), findsOneWidget);
      expect(find.text('Detaya git'), findsOneWidget);
    },
  );

  testWidgets(
    'the sheet\'s "Detaya git" action opens that cat\'s detail view',
    (tester) async {
      await _pumpMap(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MapScreen)),
      );
      container.read(catsMapProvider.notifier).selectCat(_marker);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Detaya git'));
      await tester.pumpAndSettle();

      expect(find.byType(CatDetailScreen), findsOneWidget);
      expect(find.text('tekir'), findsWidgets);
    },
  );

  testWidgets(
    'dismissing the sheet (tapping outside it) clears the selection and leaves the user on the map',
    (tester) async {
      await _pumpMap(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MapScreen)),
      );
      container.read(catsMapProvider.notifier).selectCat(_marker);
      await tester.pumpAndSettle();
      expect(find.byType(CatPreviewSheet), findsOneWidget);

      // taps the modal barrier above the sheet — the area of the screen the
      // sheet itself doesn't cover — exactly like tapping the map outside
      // the sheet in prototype/app.js's closeSheet.
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      expect(find.byType(CatPreviewSheet), findsNothing);
      expect(find.byType(MapScreen), findsOneWidget);
      expect(container.read(catsMapProvider).selectedMarker, isNull);
    },
  );

  testWidgets('the back action on the detail screen returns to the map', (
    tester,
  ) async {
    await _pumpMap(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MapScreen)),
    );
    container.read(catsMapProvider.notifier).selectCat(_marker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detaya git'));
    await tester.pumpAndSettle();
    expect(find.byType(CatDetailScreen), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();

    expect(find.byType(MapScreen), findsOneWidget);
    expect(find.byType(CatDetailScreen), findsNothing);
  });

  testWidgets(
    'the back action falls back to the map when reached via go(), with nothing to pop',
    (tester) async {
      // Mirrors add-cat's success navigation (context.go('/cats/:id')),
      // which replaces the whole stack instead of pushing onto it — unlike
      // every other path to this screen in this file, there is nothing to
      // pop here.
      await _pumpMap(tester);
      appRouter.go('/cats/$_catId');
      await tester.pumpAndSettle();
      expect(find.byType(CatDetailScreen), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();

      expect(find.byType(MapScreen), findsOneWidget);
      expect(find.byType(CatDetailScreen), findsNothing);
    },
  );
}
