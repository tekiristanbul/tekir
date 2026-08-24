import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/map/ui/selection_halo.dart';

Future<void> _pumpHalo(
  WidgetTester tester, {
  bool reducedMotion = false,
}) async {
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(disableAnimations: reducedMotion),
      child: const Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [SelectionHalo(center: Offset(200, 400), radius: 43)],
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the ring turns and the pulse runs while a cat is selected', (
    tester,
  ) async {
    await _pumpHalo(tester);

    final before = tester.widget<CustomPaint>(find.byType(CustomPaint)).painter;
    await tester.pump(const Duration(milliseconds: 600));
    final after = tester.widget<CustomPaint>(find.byType(CustomPaint)).painter;

    // The painter is rebuilt with new values every frame; if nothing were
    // animating it would be handed the same ones.
    expect(before!.shouldRepaint(after!), isTrue);
  });

  testWidgets('it keeps turning across rebuilds that move it', (tester) async {
    // The halo is rebuilt on every frame of a camera movement, with a new
    // centre each time. It used to re-decide whether to animate on every one
    // of those rebuilds, and stopped: the ring turned once and sat still.
    await _pumpHalo(tester);

    var last = tester.widget<CustomPaint>(find.byType(CustomPaint)).painter!;
    for (var i = 1; i <= 12; i++) {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Stack(
              children: [
                SelectionHalo(center: Offset(200 + i * 3, 400), radius: 43),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      final now = tester.widget<CustomPaint>(find.byType(CustomPaint)).painter!;
      expect(
        last.shouldRepaint(now),
        isTrue,
        reason: 'the halo stopped animating after rebuild $i',
      );
      last = now;
    }
  });

  testWidgets('reduced motion holds it still rather than removing it', (
    tester,
  ) async {
    await _pumpHalo(tester, reducedMotion: true);

    // Still on screen: the halo marks which cat is selected, and reduced
    // motion drops the travel, never the mark.
    expect(find.byType(SelectionHalo), findsOneWidget);

    final before = tester.widget<CustomPaint>(find.byType(CustomPaint)).painter;
    await tester.pump(const Duration(milliseconds: 600));
    final after = tester.widget<CustomPaint>(find.byType(CustomPaint)).painter;

    expect(before!.shouldRepaint(after!), isFalse);
  });

  testWidgets('it settles, so a still halo never hangs a pumpAndSettle', (
    tester,
  ) async {
    await _pumpHalo(tester, reducedMotion: true);

    await tester.pumpAndSettle();
  });

  testWidgets('it carries nothing to assistive technology', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpHalo(tester, reducedMotion: true);

    // The halo is decoration: which cat is selected is already carried by
    // the marker's own rendering and by the sheet that opened with it.
    expect(tester.getSemantics(find.byType(SelectionHalo)).childrenCount, 0);
    handle.dispose();
  });

  testWidgets('it never intercepts a tap meant for the map', (tester) async {
    var tappedThrough = false;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => tappedThrough = true,
                ),
              ),
              const SelectionHalo(center: Offset(200, 400), radius: 43),
            ],
          ),
        ),
      ),
    );

    await tester.tapAt(const Offset(200, 400));
    await tester.pump();

    expect(tappedThrough, isTrue);
  });
}
