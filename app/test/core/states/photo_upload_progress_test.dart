import 'package:app/core/states/photo_upload_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _harness(double progress) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 200,
        height: 120,
        child: PhotoUploadProgress(progress: progress),
      ),
    ),
  );
}

void main() {
  group('PhotoUploadProgress', () {
    testWidgets('shows the percentage and a matching bar fill', (tester) async {
      await tester.pumpWidget(_harness(0.62));
      expect(find.text('%62'), findsOneWidget);

      final fill = tester.widget<FractionallySizedBox>(
        find.byType(FractionallySizedBox),
      );
      expect(fill.widthFactor, closeTo(0.62, 0.001));
    });

    testWidgets('clamps out-of-range progress', (tester) async {
      await tester.pumpWidget(_harness(1.4));
      expect(find.text('%100'), findsOneWidget);

      await tester.pumpWidget(_harness(-0.2));
      expect(find.text('%0'), findsOneWidget);
    });

    testWidgets('is static — no running animations', (tester) async {
      await tester.pumpWidget(_harness(0.4));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
