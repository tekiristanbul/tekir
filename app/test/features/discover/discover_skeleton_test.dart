import 'package:app/core/states/shimmer_sweep.dart';
import 'package:app/features/discover/ui/discover_skeleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _harness({bool reduceMotion = false}) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: const Scaffold(body: DiscoverListSkeleton()),
  );
}

void main() {
  group('DiscoverListSkeleton', () {
    testWidgets('renders six staggered shimmer rows', (tester) async {
      await tester.pumpWidget(_harness());
      expect(find.byType(ShimmerSweep), findsNWidgets(6));

      // The stagger and sweep keep animating while mounted.
      await tester.pump(const Duration(milliseconds: 800));
      expect(tester.hasRunningAnimations, isTrue);
    });

    testWidgets('rows keep the real cat row\'s height so nothing jumps', (
      tester,
    ) async {
      await tester.pumpWidget(_harness());
      // Real row: 12 px vertical padding around a 44 px photo (see
      // _DiscoverCatRow in discover_screen.dart).
      final row = tester.getSize(find.byType(ShimmerSweep).first);
      expect(row.height, 68);
    });

    testWidgets('reduced motion renders the settled frame, no shimmer', (
      tester,
    ) async {
      await tester.pumpWidget(_harness(reduceMotion: true));
      expect(find.byType(ShimmerSweep), findsNWidgets(6));

      // No sweep overlay and nothing animating: settles immediately.
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      expect(tester.hasRunningAnimations, isFalse);
    });
  });
}
