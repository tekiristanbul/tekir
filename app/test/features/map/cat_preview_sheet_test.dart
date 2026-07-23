import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/map/ui/cat_preview_sheet.dart';

// primaryPhoto is deliberately empty on every fixture here: a real url
// would fire an actual network request the moment CachedNetworkImage
// mounts, which these widget tests must not depend on. The missing-photo
// test below covers that exact code path (the empty-url branch in
// _PreviewPhoto) directly.
const _cat = CatMarker(
  id: 'cat-1',
  name: 'tekir',
  primaryPhoto: '',
  lat: 41.02561,
  lng: 28.97440,
  needsHelp: false,
);

Future<void> _pump(
  WidgetTester tester,
  CatMarker cat, {
  VoidCallback? onOpenDetail,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: CatPreviewSheet(cat: cat, onOpenDetail: onOpenDetail ?? () {}),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'missing photo falls back to a branded placeholder, not a broken image',
    (tester) async {
      await _pump(tester, _cat);

      expect(find.text('tekir'), findsOneWidget);
      expect(find.byIcon(Icons.pets), findsOneWidget);
    },
  );

  testWidgets('shows the human-readable area label when present', (
    tester,
  ) async {
    await _pump(
      tester,
      const CatMarker(
        id: 'cat-1',
        name: 'tekir',
        primaryPhoto: '',
        lat: 41.02561,
        lng: 28.97440,
        areaLabel: 'Moda Sahili, Kadıköy',
        needsHelp: false,
      ),
    );

    expect(find.text('Moda Sahili, Kadıköy'), findsOneWidget);
  });

  testWidgets('shows a clear needs-help mark when active', (tester) async {
    await _pump(
      tester,
      const CatMarker(
        id: 'cat-1',
        name: 'tekir',
        primaryPhoto: '',
        lat: 41.02561,
        lng: 28.97440,
        needsHelp: true,
      ),
    );

    expect(find.text('yardım gerekiyor'), findsOneWidget);
  });

  testWidgets('does not show a needs-help mark when inactive', (tester) async {
    await _pump(tester, _cat);

    expect(find.text('yardım gerekiyor'), findsNothing);
  });

  testWidgets('tapping "Detaya git" triggers onOpenDetail', (tester) async {
    var tapped = false;
    await _pump(tester, _cat, onOpenDetail: () => tapped = true);

    await tester.tap(find.text('Detaya git'));
    await tester.pump();

    expect(tapped, isTrue);
  });
}
