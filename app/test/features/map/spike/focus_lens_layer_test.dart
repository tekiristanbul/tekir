import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/map/spike/focus_lens.dart';
import 'package:app/features/map/spike/focus_lens_layer.dart';
import 'package:app/features/map/spike/map_projection.dart';

/// Issue #280, concept 1, at the widget level: the lens follows the
/// pointer while the glass is up, intercepts nothing while it is down,
/// hands the cat under it back on a tap, and answers the reduced-motion
/// preference by dropping the ramp rather than the lens.
void main() {
  const cats = [
    CatMarker(
      id: 'a',
      name: 'tekir',
      primaryPhoto: '',
      lat: 41.02561,
      lng: 28.97440,
    ),
    CatMarker(
      id: 'b',
      name: 'boncuk',
      primaryPhoto: '',
      lat: 41.02575,
      lng: 28.97455,
    ),
  ];

  const projection = MapProjection(
    center: LatLng(41.02561, 28.97440),
    zoom: 17,
    size: Size(390, 844),
  );

  Widget host({
    bool armed = true,
    bool reduceMotion = false,
    void Function(CatMarker)? onSelect,
  }) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: FocusLensLayer(
            armed: armed,
            cats: cats,
            projection: projection,
            onSelect: onSelect ?? (_) {},
            onZoom: (_) {},
          ),
        ),
      ),
    );
  }

  Size pinSize(WidgetTester tester, String name) =>
      tester.getSize(find.bySemanticsLabel(name).first);

  /// One frame to start the ramp, one with time on it to finish it.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('at rest every cat sits at its own size', (tester) async {
    await tester.pumpWidget(host());

    expect(pinSize(tester, 'tekir').width, closeTo(lensBasePin, 0.01));
    expect(pinSize(tester, 'boncuk').width, closeTo(lensBasePin, 0.01));
  });

  testWidgets('the pointer magnifies what is under it', (tester) async {
    await tester.pumpWidget(host());
    final tekir = tester.getCenter(find.bySemanticsLabel('tekir').first);

    final gesture = await tester.startGesture(tekir);
    await settle(tester);

    expect(pinSize(tester, 'tekir').width, greaterThan(lensBasePin * 1.5));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(pinSize(tester, 'tekir').width, closeTo(lensBasePin, 0.01));
  });

  testWidgets('a cat the focus has left comes back to its own size', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final tekir = tester.getCenter(find.bySemanticsLabel('tekir').first);

    final gesture = await tester.startGesture(tekir);
    await settle(tester);
    final magnified = pinSize(tester, 'tekir').width;

    // Moved past the lens's reach without lifting: this is the continuous
    // part of the concept, and a cat has to be released by the lens moving
    // on, not only by the pointer lifting.
    await gesture.moveTo(tekir + const Offset(lensRadius + 40, 0));
    await tester.pump(const Duration(milliseconds: 16));

    expect(pinSize(tester, 'tekir').width, lessThan(magnified));
    expect(pinSize(tester, 'tekir').width, closeTo(lensBasePin, 0.01));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('with the glass down the layer magnifies nothing', (
    tester,
  ) async {
    // The point of the arming control: with it off the layer takes no
    // pointer events at all, and the map underneath keeps its own
    // panning, flinging and pinching. A pointer landing on the map is the
    // map's, not the lens's.
    await tester.pumpWidget(host(armed: false));
    final tekir = tester.getCenter(find.bySemanticsLabel('tekir').first);

    final gesture = await tester.startGesture(tekir + const Offset(0, 120));
    await settle(tester);

    expect(pinSize(tester, 'tekir').width, closeTo(lensBasePin, 0.01));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('putting the glass down settles what it was holding', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final tekir = tester.getCenter(find.bySemanticsLabel('tekir').first);

    final gesture = await tester.startGesture(tekir);
    await settle(tester);
    expect(pinSize(tester, 'tekir').width, greaterThan(lensBasePin * 1.5));

    // Disarmed mid-press: nothing is left magnified behind the control.
    await tester.pumpWidget(host(armed: false));
    await tester.pumpAndSettle();

    expect(pinSize(tester, 'tekir').width, closeTo(lensBasePin, 0.01));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('reduced motion drops the ramp, not the lens', (tester) async {
    await tester.pumpWidget(host(reduceMotion: true));
    final tekir = tester.getCenter(find.bySemanticsLabel('tekir').first);

    final gesture = await tester.startGesture(tekir);
    // One frame, no time passing: with the ramp gated to zero the lens is
    // already fully applied, which is what "immediate scale and
    // displacement changes" means.
    await tester.pump();

    expect(pinSize(tester, 'tekir').width, greaterThan(lensBasePin * 1.5));

    await gesture.up();
    await tester.pump();
    expect(pinSize(tester, 'tekir').width, closeTo(lensBasePin, 0.01));
  });

  testWidgets('with motion allowed the first frame is still on its way', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final tekir = tester.getCenter(find.bySemanticsLabel('tekir').first);

    final gesture = await tester.startGesture(tekir);
    await tester.pump();

    // The contrast with the test above: engaging is a 200 ms ramp, so the
    // frame the pointer lands on has not grown anything yet.
    expect(pinSize(tester, 'tekir').width, closeTo(lensBasePin, 0.01));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('tapping a cat selects it, glass up or down', (tester) async {
    for (final armed in [true, false]) {
      final selected = <String>[];
      await tester.pumpWidget(
        host(
          armed: armed,
          reduceMotion: true,
          onSelect: (cat) => selected.add(cat.id),
        ),
      );

      await tester.tap(find.bySemanticsLabel('boncuk').first);
      await tester.pump();

      expect(selected, ['b'], reason: 'armed: $armed');
      await tester.pumpAndSettle();
    }
  });
}
