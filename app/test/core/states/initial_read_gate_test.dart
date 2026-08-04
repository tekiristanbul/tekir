import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/core/states/initial_read_gate.dart';

Widget _harness({required bool reading}) {
  return MaterialApp(
    home: InitialReadGate(
      reading: reading,
      builder: (context, phase) => Text(phase.name),
    ),
  );
}

void main() {
  group('InitialReadGate', () {
    testWidgets('shows nothing loading-related before 400 ms', (tester) async {
      await tester.pumpWidget(_harness(reading: true));
      expect(find.text('hidden'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 399));
      expect(find.text('hidden'), findsOneWidget);
    });

    testWidgets('advances through skeleton, status, and timeout phases', (
      tester,
    ) async {
      await tester.pumpWidget(_harness(reading: true));

      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('skeleton'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1200));
      expect(find.text('skeletonWithStatus'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 4400));
      expect(find.text('timedOut'), findsOneWidget);
    });

    testWidgets('a read finishing within 400 ms never shows a skeleton', (
      tester,
    ) async {
      await tester.pumpWidget(_harness(reading: true));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.pumpWidget(_harness(reading: false));
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('hidden'), findsOneWidget);
    });

    testWidgets('a retry restarts the clock from hidden', (tester) async {
      await tester.pumpWidget(_harness(reading: true));
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('timedOut'), findsOneWidget);

      await tester.pumpWidget(_harness(reading: false));
      await tester.pumpWidget(_harness(reading: true));
      expect(find.text('hidden'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 399));
      expect(find.text('hidden'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('skeleton'), findsOneWidget);
    });
  });
}
