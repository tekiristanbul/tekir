import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/map/spike/focus_lens.dart';
import 'package:app/features/map/spike/focus_lens_layer.dart';
import 'package:app/features/map/spike/map_projection.dart';

/// Issue #280, concept 1, at the widget level: the lens follows the
/// pointer, hands the cat under it back to the caller on a tap, and
/// answers the reduced-motion preference by dropping the ramp rather than
/// the lens.
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
    required bool reduceMotion,
    void Function(CatMarker)? onSelect,
    void Function(Offset)? onPan,
  }) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: FocusLensLayer(
            cats: cats,
            projection: projection,
            onSelect: onSelect ?? (_) {},
            onPan: onPan ?? (_) {},
            onZoom: (_) {},
          ),
        ),
      ),
    );
  }

  Size pinSize(WidgetTester tester, String name) =>
      tester.getSize(find.bySemanticsLabel(name).first);

  /// Long enough for a press to have held still, plus the ramp.
  Future<void> holdStill(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('at rest every cat sits at its own size', (tester) async {
    await tester.pumpWidget(host(reduceMotion: false));

    expect(pinSize(tester, 'tekir').width, closeTo(lensBasePin, 0.01));
    expect(pinSize(tester, 'boncuk').width, closeTo(lensBasePin, 0.01));
  });

  testWidgets('a press that holds still brings the lens up', (tester) async {
    await tester.pumpWidget(host(reduceMotion: false));
    final tekir = tester.getCenter(find.bySemanticsLabel('tekir').first);

    final gesture = await tester.startGesture(tekir);
    await holdStill(tester);

    expect(pinSize(tester, 'tekir').width, greaterThan(lensBasePin * 1.5));

    // And lets go of it again.
    await gesture.up();
    await tester.pumpAndSettle();
    expect(pinSize(tester, 'tekir').width, closeTo(lensBasePin, 0.01));
  });

  testWidgets('a cat the focus has left comes back to its own size', (
    tester,
  ) async {
    await tester.pumpWidget(host(reduceMotion: false));
    final tekir = tester.getCenter(find.bySemanticsLabel('tekir').first);

    final gesture = await tester.startGesture(tekir);
    await holdStill(tester);
    final magnified = pinSize(tester, 'tekir').width;

    // Dragged well past the lens's reach, without lifting: this is the
    // continuous part of the concept, and the pin has to be released by
    // the lens moving on, not only by the finger lifting.
    await gesture.moveTo(tekir + const Offset(lensRadius + 40, 0));
    await tester.pump(const Duration(milliseconds: 16));

    expect(pinSize(tester, 'tekir').width, lessThan(magnified));
    expect(pinSize(tester, 'tekir').width, closeTo(lensBasePin, 0.01));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('reduced motion drops the ramp, not the lens', (tester) async {
    await tester.pumpWidget(host(reduceMotion: true));
    final tekir = tester.getCenter(find.bySemanticsLabel('tekir').first);

    final gesture = await tester.startGesture(tekir);
    // The hold still has to elapse — that is the gesture, not the motion —
    // but with the ramp gated to zero the lens is fully applied in the
    // frame it comes up, which is what "immediate scale and displacement
    // changes" means.
    await tester.pump(const Duration(milliseconds: 250));

    expect(pinSize(tester, 'tekir').width, greaterThan(lensBasePin * 1.5));

    await gesture.up();
    await tester.pump();
    expect(pinSize(tester, 'tekir').width, closeTo(lensBasePin, 0.01));
  });

  testWidgets('with motion allowed the lens is still on its way', (
    tester,
  ) async {
    await tester.pumpWidget(host(reduceMotion: false));
    final tekir = tester.getCenter(find.bySemanticsLabel('tekir').first);

    final gesture = await tester.startGesture(tekir);
    await tester.pump(const Duration(milliseconds: 250));

    // The contrast with the test above: engaging is a 200 ms ramp, so the
    // frame the lens comes up on has not grown anything yet.
    expect(pinSize(tester, 'tekir').width, closeTo(lensBasePin, 0.01));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a press that moves pans the map and never magnifies', (
    tester,
  ) async {
    final panned = <Offset>[];
    await tester.pumpWidget(host(reduceMotion: false, onPan: panned.add));
    final tekir = tester.getCenter(find.bySemanticsLabel('tekir').first);

    // Moving off before the hold elapses is a drag, and a drag belongs to
    // the map. Which of the two the reader meant cannot be read off the
    // device — trackpads, touch screens and mice all arrive the same way
    // on web — so the press itself has to decide.
    final gesture = await tester.startGesture(tekir);
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump(const Duration(milliseconds: 16));

    expect(panned, isNotEmpty);
    expect(panned.map((p) => p.dx).reduce((a, b) => a + b), closeTo(100, 0.01));
    expect(pinSize(tester, 'tekir').width, closeTo(lensBasePin, 0.01));

    // And holding past the hold time now does nothing either: this press
    // has already been decided.
    await tester.pump(const Duration(milliseconds: 400));
    expect(pinSize(tester, 'tekir').width, closeTo(lensBasePin, 0.01));

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('tapping a magnified cat selects that cat', (tester) async {
    final selected = <String>[];
    await tester.pumpWidget(
      host(reduceMotion: true, onSelect: (cat) => selected.add(cat.id)),
    );

    await tester.tap(find.bySemanticsLabel('boncuk').first);
    await tester.pump();

    expect(selected, ['b']);
  });
}
