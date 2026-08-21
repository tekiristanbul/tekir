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
  }) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: FocusLensLayer(
            cats: cats,
            projection: projection,
            onSelect: onSelect ?? (_) {},
            onPan: (_) {},
            onZoom: (_) {},
          ),
        ),
      ),
    );
  }

  Size pinSize(WidgetTester tester, String name) =>
      tester.getSize(find.bySemanticsLabel(name).first);

  testWidgets('at rest every cat sits at its own size', (tester) async {
    await tester.pumpWidget(host(reduceMotion: false));

    expect(pinSize(tester, 'tekir').width, closeTo(lensBasePin, 0.01));
    expect(pinSize(tester, 'boncuk').width, closeTo(lensBasePin, 0.01));
  });

  testWidgets('the pointer magnifies what is under it', (tester) async {
    await tester.pumpWidget(host(reduceMotion: false));
    final tekir = tester.getCenter(find.bySemanticsLabel('tekir').first);

    final gesture = await tester.startGesture(tekir);
    // Two frames: the first starts the ramp, the second is the first one
    // with time on it.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
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
    // One frame, no time passing: with the ramp gated to zero the lens is
    // already fully applied, which is what "immediate scale and
    // displacement changes" means.
    await tester.pump();

    expect(pinSize(tester, 'tekir').width, greaterThan(lensBasePin * 1.5));

    await gesture.up();
    await tester.pump();
    expect(pinSize(tester, 'tekir').width, closeTo(lensBasePin, 0.01));
  });

  testWidgets('with motion allowed the same frame is still on its way', (
    tester,
  ) async {
    await tester.pumpWidget(host(reduceMotion: false));
    final tekir = tester.getCenter(find.bySemanticsLabel('tekir').first);

    final gesture = await tester.startGesture(tekir);
    await tester.pump();

    // The contrast with the test above: engaging is a 200 ms ramp, so at
    // t=0 nothing has grown yet.
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
