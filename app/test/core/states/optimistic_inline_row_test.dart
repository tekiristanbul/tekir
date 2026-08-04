import 'package:app/core/states/optimistic_inline_row.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _harness({required InlineSaveStatus status, bool reduceMotion = false}) {
  return MaterialApp(
    theme: AppTheme.light,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: Scaffold(
      body: OptimisticInlineRow(
        label: status == InlineSaveStatus.saving
            ? 'su verdin · kaydediliyor'
            : 'su verdin · gönderilemedi',
        status: status,
      ),
    ),
  );
}

Container _rowContainer(WidgetTester tester) {
  return tester.widget<Container>(
    find.ancestor(of: find.byType(Row), matching: find.byType(Container)),
  );
}

void main() {
  group('OptimisticInlineRow', () {
    testWidgets('saving shows the label with an inline spinner on sand', (
      tester,
    ) async {
      await tester.pumpWidget(_harness(status: InlineSaveStatus.saving));
      expect(find.text('su verdin · kaydediliyor'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      final decoration = _rowContainer(tester).decoration! as BoxDecoration;
      expect(decoration.color, AppColors.surfaceAlt);
    });

    testWidgets('failure turns to the help palette and never disappears', (
      tester,
    ) async {
      await tester.pumpWidget(_harness(status: InlineSaveStatus.saving));
      await tester.pumpWidget(_harness(status: InlineSaveStatus.failed));

      expect(find.text('su verdin · gönderilemedi'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      final decoration = _rowContainer(tester).decoration! as BoxDecoration;
      expect(decoration.color, AppColors.helpSoft);
    });

    testWidgets('reduced motion renders a static arc', (tester) async {
      await tester.pumpWidget(
        _harness(status: InlineSaveStatus.saving, reduceMotion: true),
      );
      final indicator = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(indicator.value, isNotNull);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
    });
  });
}
