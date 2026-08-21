import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/map/spike/carry_route.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:app/features/map/spike/focus_lens_layer.dart';
import 'package:app/features/map/spike/map_projection.dart';

/// Frame evidence for issue #280, written into
/// `docs/design/screenshots/`.
///
/// A browser screenshot can show a concept's start and end; it cannot show
/// the middle, which for two of these three concepts is the concept. These
/// captures pump the real widgets at fixed points through their own
/// animations, so the comparison is of frames rather than of descriptions.
///
/// Regenerate with:
///
///     flutter test --update-goldens --dart-define=CAPTURE_FRAMES=true \
///       test/features/map/spike/spike_frames_test.dart
///
/// Skipped otherwise — ci has no captured frames to compare against and no
/// reason to render them. The photos are deliberately empty so the drawn
/// placeholder stands in for a network image: the geometry and the timing
/// are what these frames are evidence of.
const _capturing = bool.fromEnvironment('CAPTURE_FRAMES');

/// The app's own faces plus the icon font, loaded into the test binary so
/// the captures read as tekir rather than as rows of placeholder boxes.
///
/// Must be called inside `tester.runAsync` — [FontLoader.load] never
/// completes on the fake async clock a widget test runs on, which cost
/// seven minutes of a hung run to find. The icon font comes from the
/// flutter cache: it is not one of the app's declared assets, but Icons.pets
/// is what a pin with no photo draws.
Future<void> loadCaptureFonts() async {
  final iconFont = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? ''}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  final families = {
    'Fraunces': File('assets/fonts/Fraunces-Variable.ttf'),
    'Work Sans': File('assets/fonts/WorkSans-Variable.ttf'),
    if (iconFont.existsSync()) 'MaterialIcons': iconFont,
  };
  for (final family in families.entries) {
    final bytes = await family.value.readAsBytes();
    await (FontLoader(
      family.key,
    )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
  }
}

void main() {
  const cats = [
    CatMarker(
      id: '00000000-0000-4000-8000-000000000010',
      name: 'tekir',
      primaryPhoto: '',
      lat: 41.02561,
      lng: 28.97440,
    ),
    CatMarker(
      id: '00000000-0000-4000-8000-000000000011',
      name: 'boncuk',
      primaryPhoto: '',
      lat: 41.02575,
      lng: 28.97455,
    ),
    CatMarker(
      id: '00000000-0000-4000-8000-000000000012',
      name: 'duman',
      primaryPhoto: '',
      lat: 41.02548,
      lng: 28.97430,
    ),
    CatMarker(
      id: '00000000-0000-4000-8000-000000000013',
      name: 'pamuk',
      primaryPhoto: '',
      lat: 41.02590,
      lng: 28.97465,
    ),
    CatMarker(
      id: '00000000-0000-4000-8000-000000000014',
      name: 'sarman',
      primaryPhoto: '',
      lat: 41.02530,
      lng: 28.97410,
    ),
    CatMarker(
      id: '00000000-0000-4000-8000-000000000015',
      name: 'minnoş',
      primaryPhoto: '',
      lat: 41.02605,
      lng: 28.97480,
    ),
    CatMarker(
      id: '00000000-0000-4000-8000-000000000016',
      name: 'zeytin',
      primaryPhoto: '',
      lat: 41.02515,
      lng: 28.97395,
      activeAlert: null,
    ),
  ];

  const focus = Offset(195, 380);

  testWidgets('concept 1 · the lens crossing the Galata group', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(loadCaptureFonts);

    // The real seeded coordinates, projected the way the running app
    // projects them, at the zoom the map opens on. Nothing about the
    // crowding in these frames is arranged for the capture.
    const projection = MapProjection(
      center: LatLng(41.02561, 28.97440),
      zoom: 17,
      size: Size(390, 844),
    );

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: Scaffold(
          // A blank ground, not a map: these frames are evidence of the
          // lens itself, and the browser captures show it over the real
          // basemap.
          backgroundColor: AppColors.bg,
          body: FocusLensLayer(
            cats: cats,
            projection: projection,
            onSelect: (_) {},
            onPan: (_) {},
            onZoom: (_) {},
          ),
        ),
      ),
    );

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(
        '../../../../../docs/design/screenshots/spike-280-lens-frame-0.png',
      ),
    );

    // The focus is dragged straight across the group, and the frames are
    // taken along the way — which is the only way to show that the effect
    // follows the pointer rather than toggling.
    final path = <Offset>[
      const Offset(150, 450),
      const Offset(178, 434),
      const Offset(196, 422),
      const Offset(228, 404),
    ];
    final gesture = await tester.startGesture(path.first);
    // The first frame starts the ramp; the second is the first one with
    // time on it. Without both, every frame below would be caught while
    // the lens was still arriving.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    for (final (index, point) in path.indexed) {
      await gesture.moveTo(point);
      await tester.pump(const Duration(milliseconds: 16));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(
          '../../../../../docs/design/screenshots/'
          'spike-280-lens-frame-${index + 1}.png',
        ),
      );
    }

    // Released: everything settles back onto its own coordinate.
    await gesture.up();
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(
        '../../../../../docs/design/screenshots/spike-280-lens-frame-5.png',
      ),
    );
  }, skip: !_capturing);

  testWidgets('concept 3 · the pin becoming the preview', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(loadCaptureFonts);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: Scaffold(
          backgroundColor: AppColors.bg,
          body: Builder(
            builder: (context) => Stack(
              children: [
                CarryGhostPin(cat: cats.first, center: focus),
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: TextButton(
                    onPressed: () => CatPreviewPageRoute.push(
                      context,
                      cat: cats.first,
                      onOpenDetail: () {},
                    ),
                    child: const Text('aç'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(
        '../../../../../docs/design/screenshots/spike-280-carry-frame-0.png',
      ),
    );

    await tester.tap(find.text('aç'));
    await tester.pump();
    for (final (index, step) in const [
      Duration(milliseconds: 80),
      Duration(milliseconds: 80),
      Duration(milliseconds: 80),
      Duration(milliseconds: 120),
    ].indexed) {
      await tester.pump(step);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(
          '../../../../../docs/design/screenshots/'
          'spike-280-carry-frame-${index + 1}.png',
        ),
      );
    }
    await tester.pumpAndSettle();
  }, skip: !_capturing);
}
