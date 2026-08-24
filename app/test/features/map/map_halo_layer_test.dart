import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/map/ui/map_halo_layer.dart';

Future<void> _pump(
  WidgetTester tester, {
  List<Offset> helpCentres = const [],
  Offset? selectedCentre,
  bool reducedMotion = false,
}) async {
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(disableAnimations: reducedMotion),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            MapHaloLayer(
              helpCentres: helpCentres,
              selectedCentre: selectedCentre,
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

MapHaloPainter _painter(WidgetTester tester) =>
    tester.widget<CustomPaint>(find.byType(CustomPaint)).painter
        as MapHaloPainter;

/// Where a ring is at [progress] through its cycle, as a multiple of the
/// marker's own radius.
double _ringScaleAt(double progress) =>
    MapHaloPainter.debugPulseScaleAt(progress);

void main() {
  group('what pulses', () {
    testWidgets('a cat waiting for help pulses on its own', (tester) async {
      await _pump(tester, helpCentres: const [Offset(200, 400)]);

      final before = _painter(tester);
      await tester.pump(const Duration(milliseconds: 600));

      expect(before.shouldRepaint(_painter(tester)), isTrue);
    });

    testWidgets('help and selection keep their own rhythms', (tester) async {
      // The design gives them the same shape and different periods, so the
      // two never read as the same event even on the same cat.
      expect(MapHaloLayer.helpPeriod, isNot(MapHaloLayer.selectionPeriod));
      expect(
        MapHaloLayer.helpPeriod,
        greaterThan(MapHaloLayer.selectionPeriod),
      );
    });

    testWidgets('several cats waiting for help share one set of tickers', (
      tester,
    ) async {
      await _pump(
        tester,
        helpCentres: const [
          Offset(100, 100),
          Offset(200, 200),
          Offset(300, 300),
        ],
      );

      // One layer, one painter — a dozen help marks cost what one does.
      expect(find.byType(CustomPaint), findsOneWidget);
      expect(_painter(tester).helpCentres, hasLength(3));
    });
  });

  group('reduced motion', () {
    testWidgets('draws no pulse at all', (tester) async {
      await _pump(
        tester,
        helpCentres: const [Offset(200, 400)],
        selectedCentre: const Offset(200, 400),
        reducedMotion: true,
      );

      final painter = _painter(tester);
      // The ring at rest lives in the marker bitmap, at every resolution
      // and whatever the motion preference — so dropping the pulse here
      // drops the travel and nothing else.
      expect(painter.helpPulse, isNull);
      expect(painter.selectionPulse, isNull);
      expect(painter.turn, 0);
    });

    testWidgets('and settles, so it never hangs a pumpAndSettle', (
      tester,
    ) async {
      await _pump(
        tester,
        helpCentres: const [Offset(200, 400)],
        reducedMotion: true,
      );

      await tester.pumpAndSettle();
    });

    testWidgets('holds still across time', (tester) async {
      await _pump(
        tester,
        helpCentres: const [Offset(200, 400)],
        reducedMotion: true,
      );

      final before = _painter(tester);
      await tester.pump(const Duration(milliseconds: 800));

      expect(before.shouldRepaint(_painter(tester)), isFalse);
    });
  });

  testWidgets('it keeps animating across rebuilds that move it', (
    tester,
  ) async {
    // The layer is rebuilt on every frame of a camera movement, with new
    // centres each time. Deciding whether to animate on each of those
    // rebuilds stopped it: the ring turned once and sat still.
    await _pump(tester, selectedCentre: const Offset(200, 400));

    var last = _painter(tester);
    for (var i = 1; i <= 10; i++) {
      await _pump(tester, selectedCentre: Offset(200 + i * 4, 400));
      await tester.pump(const Duration(milliseconds: 400));
      final now = _painter(tester);
      expect(
        last.shouldRepaint(now),
        isTrue,
        reason: 'the halo stopped animating after rebuild $i',
      );
      last = now;
    }
  });

  group('the pulse leaves from behind the cat', () {
    test('it never starts inside the marker it belongs to', () {
      // The artboard can start its ring at half radius, because there the
      // cat's face is drawn over it. Here every flutter layer is above the
      // map's platform view, so a ring that started inside would cross the
      // photo instead of appearing from behind it.
      expect(_ringScaleAt(0), greaterThanOrEqualTo(1.0));
    });

    test('and only ever grows outward', () {
      var previous = _ringScaleAt(0);
      for (final progress in [0.2, 0.4, 0.6, 0.8, 1.0]) {
        final scale = _ringScaleAt(progress);
        expect(scale, greaterThan(previous));
        previous = scale;
      }
    });
  });

  group('the selected cat keeps its mark', () {
    testWidgets('a moment with nothing to draw does not restart it', (
      tester,
    ) async {
      await _pump(tester, selectedCentre: const Offset(200, 400));
      await tester.pump(const Duration(milliseconds: 3000));
      final mid = _painter(tester).turn;
      expect(mid, greaterThan(0));

      // The cat is panned out of view and back — the layer has nothing to
      // draw in between. Mounted only when it had work, this restarted
      // every controller from zero.
      await _pump(tester);
      await tester.pump(const Duration(milliseconds: 100));
      await _pump(tester, selectedCentre: const Offset(200, 400));

      expect(_painter(tester).turn, greaterThanOrEqualTo(mid));
    });

    testWidgets('the ring is drawn even between two pulses', (tester) async {
      await _pump(tester, selectedCentre: const Offset(200, 400));

      // Past the point the pulse has faded to nothing: without a resting
      // mark the cat would be unmarked here, which reads as the animation
      // having ended.
      await tester.pump(
        MapHaloLayer.selectionPeriod * MapHaloPainter.debugPulseFadesBy,
      );
      await tester.pump(const Duration(milliseconds: 80));

      final painter = _painter(tester);
      expect(painter.selectedCentre, isNotNull);
      expect(painter.turn, greaterThan(0));
    });
  });

  testWidgets('it carries nothing to assistive technology', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      helpCentres: const [Offset(200, 400)],
      reducedMotion: true,
    );

    expect(tester.getSemantics(find.byType(MapHaloLayer)).childrenCount, 0);
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
              const MapHaloLayer(
                helpCentres: [Offset(200, 400)],
                selectedCentre: Offset(200, 400),
              ),
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
