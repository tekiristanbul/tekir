import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/map/ui/cat_pin.dart';

void main() {
  testWidgets('CatPin calls onTap when tapped', (tester) async {
    var tapped = false;
    const cat = CatMarker(
      id: 'cat-1',
      primaryPhoto: '',
      lat: 41.0256,
      lng: 28.9744,
      needsHelp: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: CatPin(cat: cat, onTap: () => tapped = true),
      ),
    );
    await tester.tap(find.byType(CatPin));

    expect(tapped, isTrue);
  });

  testWidgets('CatClusterPin renders the marker count', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CatClusterPin(count: 5)));

    expect(find.text('5'), findsOneWidget);
  });
}
