import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/map/data/marker_tier.dart';
import 'package:app/features/map/ui/cluster_picker_sheet.dart';

// primaryPhoto is empty on every fixture: a real url would fire a network
// request the moment CachedNetworkImage mounts.
CatMarker _cat(String id, {String? name, ActiveAlert? alert}) => CatMarker(
  id: id,
  name: name ?? id,
  primaryPhoto: '',
  lat: 41.0250,
  lng: 28.9740,
  activeAlert: alert,
);

CatCluster _cluster(List<CatMarker> cats) =>
    CatCluster(id: 'cluster:0:0', lat: 41.0250, lng: 28.9740, cats: cats);

Future<List<CatMarker>> _pump(
  WidgetTester tester,
  CatCluster cluster, {
  double textScale = 1.0,
}) async {
  final picked = <CatMarker>[];
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        disableAnimations: true,
        textScaler: TextScaler.linear(textScale),
      ),
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ClusterPickerSheet(cluster: cluster, onPick: picked.add),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return picked;
}

void main() {
  testWidgets('names every cat in the group, and how many there are', (
    tester,
  ) async {
    await _pump(
      tester,
      _cluster([_cat('a', name: 'tekir'), _cat('b', name: 'boncuk')]),
    );

    expect(find.text('aynı yerde 2 kedi'), findsOneWidget);
    expect(find.text('tekir'), findsOneWidget);
    expect(find.text('boncuk'), findsOneWidget);
  });

  testWidgets('picking one hands that cat back', (tester) async {
    final picked = await _pump(
      tester,
      _cluster([_cat('a', name: 'tekir'), _cat('b', name: 'boncuk')]),
    );

    await tester.tap(find.text('boncuk'));
    await tester.pumpAndSettle();

    expect(picked.map((c) => c.id), ['b']);
  });

  testWidgets('a cat needing help says so here too', (tester) async {
    final now = DateTime.now();
    await _pump(
      tester,
      _cluster([
        _cat('a', name: 'tekir'),
        _cat(
          'b',
          name: 'boncuk',
          alert: ActiveAlert(
            createdAt: now,
            expiresAt: now.add(const Duration(hours: 2)),
          ),
        ),
      ]),
    );

    // Carried by a badge shape as well as the ring colour, like everywhere
    // else in the app.
    expect(find.byIcon(Icons.priority_high), findsOneWidget);
    expect(find.textContaining('yardım gerekiyor'), findsOneWidget);
  });

  testWidgets('no distance is shown: every cat here is in the same place', (
    tester,
  ) async {
    await _pump(
      tester,
      _cluster([_cat('a', name: 'tekir'), _cat('b', name: 'boncuk')]),
    );

    expect(find.textContaining(' m'), findsNothing);
  });

  testWidgets('a large group scrolls instead of overflowing', (tester) async {
    await _pump(
      tester,
      _cluster([for (var i = 0; i < 25; i++) _cat('$i', name: 'kedi $i')]),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(ListView), findsOneWidget);
  });

  testWidgets('survives a large system text scale', (tester) async {
    await _pump(
      tester,
      _cluster([_cat('a', name: 'tekir'), _cat('b', name: 'boncuk')]),
      textScale: 2.0,
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('every row is at least 44 logical px', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await _pump(
        tester,
        _cluster([_cat('a', name: 'tekir'), _cat('b', name: 'boncuk')]),
      );

      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    } finally {
      handle.dispose();
    }
  });
}
