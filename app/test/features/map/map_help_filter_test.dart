// Regression coverage for the "yardım gerekiyor" filter chip (issue #121
// visual-parity PR #123): the toggle itself, its `Semantics.toggled`
// state, and the selection-clearing behavior a reviewer flagged — turning
// the filter on while a non-`needsHelp` cat is selected must not leave a
// hidden marker's preview sheet still open.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/map/data/location_service.dart';
import 'package:app/features/map/ui/cat_preview_sheet.dart';
import 'package:app/features/map/ui/cats_map_notifier.dart';
import 'package:app/features/map/ui/map_screen.dart';

final _needsHelpAlert = ActiveAlert(
  createdAt: DateTime.utc(2026, 1, 1),
  expiresAt: DateTime.utc(2026, 1, 2),
);

final _needsHelpCat = CatMarker(
  id: '00000000-0000-4000-8000-000000000030',
  name: 'sarman',
  primaryPhoto: '',
  lat: 41.02561,
  lng: 28.97440,
  activeAlert: _needsHelpAlert,
);

const _healthyCat = CatMarker(
  id: '00000000-0000-4000-8000-000000000031',
  name: 'boncuk',
  primaryPhoto: '',
  lat: 41.02561,
  lng: 28.97440,
);

// Same rationale as map_marker_navigation_test.dart: GoogleMap's platform
// view throws MissingPluginException the moment the marker set becomes
// non-empty under `flutter test`. selectCat() only ever sets
// CatsMapState.selectedMarker, never CatsMapState.markers, so driving
// selection directly (as a real marker tap does under the hood) never
// populates that set and never touches the platform view.
class _EmptyCatsMapNotifier extends CatsMapNotifier {
  @override
  CatsMapState build() => const CatsMapState();
}

Widget _harness() {
  return ProviderScope(
    overrides: [
      initialLocationProvider.overrideWith(
        (ref) async =>
            const ResolvedLocation(center: istanbulFallback, isFallback: false),
      ),
      catsMapProvider.overrideWith(_EmptyCatsMapNotifier.new),
    ],
    child: const MaterialApp(home: MapScreen()),
  );
}

Future<void> _pumpMap(WidgetTester tester) async {
  await tester.pumpWidget(_harness());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

// showModalBottomSheet's own ModalBarrier is HitTestBehavior.opaque and
// covers the full screen (including the chip's own top-of-screen position)
// for as long as the preview sheet is open — confirmed by
// map_marker_navigation_test.dart's "dismissing the sheet (tapping outside
// it)" case, where a tap far from the sheet's own bounds still dismisses
// it. So a real geometric tester.tap() at the chip's on-screen position
// can never reach the chip's InkWell while a sheet is showing; it would
// just dismiss the sheet instead, which is not what these two tests are
// checking. Driving the InkWell's onTap directly exercises exactly the
// same handler (_toggleHelpFilter) a tap would, without depending on
// route-stacking/barrier geometry that isn't the point under test.
void _tapHelpFilterChip(WidgetTester tester) {
  tester
      .widget<InkWell>(
        find.ancestor(
          of: find.text('yardım gerekiyor'),
          matching: find.byType(InkWell),
        ),
      )
      .onTap!();
}

void main() {
  testWidgets(
    'the filter chip reports its on/off state via Semantics.toggled',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await _pumpMap(tester);

        final chip = find.bySemanticsLabel('yardım gerekiyor filtresi');
        expect(
          tester.getSemantics(chip).flagsCollection.isToggled.toBoolOrNull(),
          isFalse,
        );

        await tester.tap(chip);
        await tester.pumpAndSettle();

        expect(
          tester.getSemantics(chip).flagsCollection.isToggled.toBoolOrNull(),
          isTrue,
        );

        await tester.tap(chip);
        await tester.pumpAndSettle();

        expect(
          tester.getSemantics(chip).flagsCollection.isToggled.toBoolOrNull(),
          isFalse,
        );
      } finally {
        handle.dispose();
      }
    },
  );

  testWidgets(
    'turning the filter on clears the selection and closes the preview sheet '
    "for a cat that doesn't need help",
    (tester) async {
      await _pumpMap(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MapScreen)),
      );
      container.read(catsMapProvider.notifier).selectCat(_healthyCat);
      await tester.pumpAndSettle();
      expect(find.byType(CatPreviewSheet), findsOneWidget);

      _tapHelpFilterChip(tester);
      await tester.pumpAndSettle();

      expect(find.byType(CatPreviewSheet), findsNothing);
      expect(container.read(catsMapProvider).selectedMarker, isNull);
    },
  );

  testWidgets(
    'turning the filter on leaves the selection and sheet alone for a cat '
    'that does need help',
    (tester) async {
      await _pumpMap(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MapScreen)),
      );
      container.read(catsMapProvider.notifier).selectCat(_needsHelpCat);
      await tester.pumpAndSettle();
      expect(find.byType(CatPreviewSheet), findsOneWidget);

      _tapHelpFilterChip(tester);
      await tester.pumpAndSettle();

      expect(find.byType(CatPreviewSheet), findsOneWidget);
      expect(
        container.read(catsMapProvider).selectedMarker?.id,
        _needsHelpCat.id,
      );
    },
  );
}
