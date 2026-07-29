import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/router/app_router.dart';
import 'package:app/features/discover/data/discover_location_service.dart';
import 'package:app/features/map/data/location_service.dart';
import 'package:app/features/map/ui/cats_map_notifier.dart';
import 'package:app/features/map/ui/map_screen.dart';
import 'package:app/features/discover/ui/discover_screen.dart';
import 'package:app/features/profile/ui/profile_screen.dart';
import 'package:app/features/cat_detail/data/cat_detail.dart';
import 'package:app/features/cat_detail/ui/cat_detail_notifier.dart';
import 'package:app/features/cat_detail/ui/cat_detail_screen.dart';

// Discover's nearby tab resolves location and fetches on mount (issue #82);
// these shell-navigation tests only care about the shell's own chrome, so a
// permission-denied stub keeps them off the real Geolocator platform
// channel and off a real network call entirely (resolve() failing
// short-circuits before any fetch is ever attempted).
class _DeniedDiscoverLocationService extends DiscoverLocationService {
  @override
  Future<DiscoverLocationOutcome> resolve() async =>
      const DiscoverLocationPermissionDenied();
}

const _catId = '00000000-0000-4000-8000-000000000010';

class _EmptyCatsMapNotifier extends CatsMapNotifier {
  @override
  CatsMapState build() => const CatsMapState(hasLoadedOnce: true);
}

// A guest session (never restored) — these tests are about the shell's
// chrome/navigation, not any authenticated feature.
class _GuestSessionIdentityService implements SessionIdentityService {
  @override
  SessionIdentity? get cached => null;

  @override
  Future<SessionIdentity?> restore() async => null;

  @override
  Future<void> save(SessionIdentity identity) async {}

  @override
  Future<void> logout({String? deviceToken}) async {}
}

class _FixedCatDetailNotifier extends CatDetailNotifier {
  _FixedCatDetailNotifier(super.catId, this._state);

  final CatDetailState _state;

  @override
  CatDetailState build() => _state;

  @override
  Future<void> load() async {}
}

Future<void> _pumpShell(WidgetTester tester) async {
  // appRouter is a module-level singleton shared across test files in this
  // isolate — reset location so an earlier test's navigation never leaks
  // into this one (mirrors map_marker_navigation_test.dart).
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
        catsMapProvider.overrideWith(_EmptyCatsMapNotifier.new),
        sessionIdentityServiceProvider.overrideWithValue(
          _GuestSessionIdentityService(),
        ),
        discoverLocationServiceProvider.overrideWithValue(
          _DeniedDiscoverLocationService(),
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
                areaLabel: null,
                primaryPhoto: null,
                createdAt: DateTime.utc(2026, 1, 1),
                lastUpdateAt: null,
              ),
              hasLoadedOnce: true,
            ),
          ),
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
    'the bottom nav shows the 3 approved-prototype tabs plus the add-cat fab on the map',
    (tester) async {
      await _pumpShell(tester);

      expect(find.byType(MapScreen), findsOneWidget);
      expect(find.text('Harita'), findsOneWidget);
      expect(find.text('Keşfet'), findsOneWidget);
      expect(find.text('Profil'), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);
    },
  );

  testWidgets('tapping Keşfet switches to the discover tab, nav bar stays', (
    tester,
  ) async {
    await _pumpShell(tester);

    await tester.tap(find.text('Keşfet'));
    await tester.pumpAndSettle();

    expect(find.byType(DiscoverScreen), findsOneWidget);
    expect(find.byType(MapScreen), findsNothing);
    expect(find.text('Harita'), findsOneWidget);
    expect(find.text('Profil'), findsOneWidget);
    // add-cat fab is map-only — on other tabs it floated over content.
    expect(find.byIcon(Icons.add), findsNothing);
  });

  testWidgets('tapping Profil switches to the profile tab, nav bar stays', (
    tester,
  ) async {
    await _pumpShell(tester);

    await tester.tap(find.text('Profil'));
    await tester.pumpAndSettle();

    expect(find.byType(ProfileScreen), findsOneWidget);
    expect(find.text('Harita'), findsOneWidget);
    expect(find.text('Keşfet'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsNothing);
  });

  testWidgets(
    'a pushed route (cat detail) covers the shell — no bottom nav, no fab',
    (tester) async {
      await _pumpShell(tester);
      appRouter.go('/cats/$_catId');
      await tester.pumpAndSettle();

      expect(find.byType(CatDetailScreen), findsOneWidget);
      expect(find.text('Harita'), findsNothing);
      expect(find.text('Keşfet'), findsNothing);
      expect(find.text('Profil'), findsNothing);
    },
  );
}
