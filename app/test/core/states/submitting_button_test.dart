import 'package:app/core/states/submitting_button.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _harness({
  required bool submitting,
  VoidCallback? onPressed,
  bool reduceMotion = false,
}) {
  return MaterialApp(
    theme: AppTheme.light,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: Scaffold(
      body: SubmittingButton(
        label: 'haritaya ekle',
        submittingLabel: 'haritaya ekleniyor',
        submitting: submitting,
        onPressed: onPressed,
      ),
    ),
  );
}

void main() {
  group('SubmittingButton', () {
    testWidgets('invokes onPressed when idle', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _harness(submitting: false, onPressed: () => taps++),
      );
      await tester.tap(find.text('haritaya ekle'));
      expect(taps, 1);
    });

    testWidgets('ignores taps while submitting', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _harness(submitting: true, onPressed: () => taps++),
      );
      await tester.tap(find.text('haritaya ekleniyor'));
      expect(taps, 0);
    });

    testWidgets('swaps to the submitting label and spinner in place', (
      tester,
    ) async {
      await tester.pumpWidget(_harness(submitting: false, onPressed: () {}));
      expect(find.text('haritaya ekle'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.pumpWidget(_harness(submitting: true, onPressed: () {}));
      // Same-frame feedback: no extra pump between state and visuals.
      expect(find.text('haritaya ekleniyor'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('darkens one tone while submitting, never greys out', (
      tester,
    ) async {
      await tester.pumpWidget(_harness(submitting: true, onPressed: () {}));
      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      final material = tester.widget<Material>(
        find.descendant(
          of: find.byType(ElevatedButton),
          matching: find.byType(Material),
        ),
      );
      expect(button.enabled, isFalse);
      expect(material.color, AppColors.primaryStrong);
    });

    testWidgets('keeps the 44 px minimum tap target', (tester) async {
      await tester.pumpWidget(_harness(submitting: false, onPressed: () {}));
      final size = tester.getSize(find.byType(ElevatedButton));
      expect(size.height, greaterThanOrEqualTo(kTapMin));
    });

    testWidgets('reduced motion renders a static arc, not a spinning one', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(submitting: true, onPressed: () {}, reduceMotion: true),
      );
      final indicator = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(indicator.value, isNotNull);
      // A determinate arc leaves no animation running.
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
    });
  });
}
