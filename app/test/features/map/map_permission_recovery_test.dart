// Regression coverage for issue #262: the state 06 `konum iznini aç` cta
// used to just invalidate initialLocationProvider, which re-runs
// LocationService.resolveInitialCenter — and that only ever re-requests
// permission when it's still `denied`. Once iOS reports `deniedForever`
// (its mapping for both an explicit prior denial and OS `restricted`),
// that path is a silent no-op, so the button visibly did nothing. These
// tests drive the fix instead: the cta now calls into
// LocationService.recoverPermission (unit-tested separately in
// location_service_test.dart) before refreshing state, and app resume
// (covering the settings-app round trip, which has no in-app callback)
// refreshes it too.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/map/data/location_service.dart';
import 'package:app/features/map/ui/cats_map_notifier.dart';
import 'package:app/features/map/ui/map_screen.dart';

class _FixedCatsMapNotifier extends CatsMapNotifier {
  @override
  CatsMapState build() => const CatsMapState();
}

class _RecordingLocationService extends LocationService {
  int recoverCalls = 0;
  void Function()? onRecover;

  @override
  Future<void> recoverPermission() async {
    recoverCalls++;
    onRecover?.call();
  }
}

Widget _harness({
  required LocationService locationService,
  required bool Function() permissionDenied,
}) {
  return ProviderScope(
    overrides: [
      locationServiceProvider.overrideWithValue(locationService),
      initialLocationProvider.overrideWith(
        (ref) async => ResolvedLocation(
          center: istanbulFallback,
          isFallback: permissionDenied(),
          permissionDenied: permissionDenied(),
        ),
      ),
      catsMapProvider.overrideWith(_FixedCatsMapNotifier.new),
    ],
    child: const MaterialApp(home: MapScreen()),
  );
}

void main() {
  group('state 06 cta recovery', () {
    testWidgets('tapping the cta calls LocationService.recoverPermission and '
        'refreshes state on a grant', (tester) async {
      var permissionDenied = true;
      final locationService = _RecordingLocationService()
        ..onRecover = () => permissionDenied = false;

      await tester.pumpWidget(
        _harness(
          locationService: locationService,
          permissionDenied: () => permissionDenied,
        ),
      );
      await tester.pump();

      expect(find.text('konum iznini aç'), findsOneWidget);

      await tester.tap(find.text('konum iznini aç'));
      await tester.pump();
      await tester.pump();

      expect(locationService.recoverCalls, 1);
      expect(find.text('konum iznini aç'), findsNothing);
    });

    testWidgets(
      'the cta stays deterministic (recoverPermission runs) even when '
      'denial persists',
      (tester) async {
        final locationService = _RecordingLocationService();

        await tester.pumpWidget(
          _harness(
            locationService: locationService,
            permissionDenied: () => true,
          ),
        );
        await tester.pump();

        await tester.tap(find.text('konum iznini aç'));
        await tester.pump();
        await tester.pump();

        expect(locationService.recoverCalls, 1);
        // state 06 stays exactly as designed — no dead-end, but no
        // redesign either (previous-attempt review feedback).
        expect(find.text('konum iznini aç'), findsOneWidget);
      },
    );
  });

  group('app resume refresh', () {
    testWidgets('resuming the app (e.g. returning from settings) re-checks '
        'permission/location state without a restart', (tester) async {
      var permissionDenied = true;
      final locationService = _RecordingLocationService();

      await tester.pumpWidget(
        _harness(
          locationService: locationService,
          permissionDenied: () => permissionDenied,
        ),
      );
      await tester.pump();

      expect(find.text('konum iznini aç'), findsOneWidget);

      // simulates the user having granted permission in the settings
      // app and switching back — no in-app callback exists for this,
      // only the lifecycle transition.
      permissionDenied = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();

      expect(find.text('konum iznini aç'), findsNothing);
    });
  });
}
