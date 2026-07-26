import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/add_cat/data/add_cat_api.dart';
import 'package:app/features/add_cat/ui/add_cat_screen.dart';
import 'package:app/features/cat_detail/data/cat_detail.dart';
import 'package:app/features/map/data/location_service.dart';

class _FakeAddCatApi implements AddCatApi {
  List<DuplicateCandidate> nearbyResult = const [];
  CatDetail? createResult;
  Object? createError;

  @override
  Future<List<DuplicateCandidate>> fetchNearby({
    required double lat,
    required double lng,
  }) async => nearbyResult;

  @override
  Future<CatDetail> createCat({
    required double lat,
    required double lng,
    String? name,
    required bool confirmedNew,
    required Uint8List photoBytes,
    required String photoFilename,
    required String idempotencyKey,
  }) async {
    if (createError != null) throw createError!;
    return createResult!;
  }
}

class _FakeImagePickerPlatform extends ImagePickerPlatform {
  XFile? nextFile;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async => nextFile;
}

// A minimal valid 1x1 PNG — the details step's photo-well previews the
// picked bytes via Image.memory, which throws asynchronously on genuinely
// invalid image data (unlike the api/notifier tests, which never decode
// the bytes at all).
final _validPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAAC0lEQVQYV2NgAAIAAAUAAen63NgAAAAASUVORK5CYII=',
);

class _FakeLocationService implements LocationService {
  @override
  Future<ResolvedLocation> resolveInitialCenter() async =>
      const ResolvedLocation(center: LatLng(41.03, 28.98), isFallback: false);
}

Future<void> _pumpAddCat(WidgetTester tester, _FakeAddCatApi api) async {
  final router = GoRouter(
    initialLocation: '/add-cat',
    routes: [
      GoRoute(
        path: '/add-cat',
        builder: (context, state) => const AddCatScreen(),
      ),
      GoRoute(
        path: '/cats/:id',
        builder: (context, state) =>
            Scaffold(body: Text('cat detail ${state.pathParameters['id']}')),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        addCatApiProvider.overrideWithValue(api),
        locationServiceProvider.overrideWith((ref) => _FakeLocationService()),
      ],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ),
  );
  // AddCatScreen mounts a real GoogleMap platform view — pumpAndSettle
  // would hang on its continuous internal animation (same reasoning as
  // add_cat_gate_widget_test.dart / map_marker_navigation_test.dart).
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

// Taps the photo well, then "Galeriden seç" in the resulting camera/gallery
// chooser sheet (the fake ImagePickerPlatform answers with fakePlatform's
// nextFile regardless of which source is actually chosen).
Future<void> _pickPhoto(WidgetTester tester) async {
  await tester.tap(find.text('Fotoğraf ekle'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(find.text('Galeriden seç'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  final fakePlatform = _FakeImagePickerPlatform();
  ImagePickerPlatform.instance = fakePlatform;

  testWidgets(
    'confirming a location with no nearby cats advances straight to the details step',
    (tester) async {
      await _pumpAddCat(tester, _FakeAddCatApi());

      expect(find.text('Konumu seç'), findsOneWidget);
      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Kedi ekle'), findsOneWidget);
      expect(find.text('Fotoğraf (zorunlu)'), findsOneWidget);
    },
  );

  testWidgets(
    'a typed name survives leaving and returning to the details step',
    (tester) async {
      // Regression: the name field must read from AddCatState.name on
      // (re)build, not rely on TextField's own internal editing state —
      // _DetailsStep is torn down and rebuilt from scratch when the step
      // switch in AddCatScreen.build moves away from and back to details
      // (e.g. tapping the app bar's back action, then confirming the
      // location again).
      await _pumpAddCat(tester, _FakeAddCatApi());
      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.enterText(find.byType(TextFormField), 'Boncuk');
      await tester.pump();

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Konumu seç'), findsOneWidget);

      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Boncuk'), findsOneWidget);
    },
  );

  testWidgets(
    'confirming a location with nearby cats shows the non-blocking duplicate modal',
    (tester) async {
      final api = _FakeAddCatApi()
        ..nearbyResult = const [
          DuplicateCandidate(id: 'cat-1', name: 'tekir', primaryPhoto: ''),
        ];
      await _pumpAddCat(tester, api);

      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.text(
          'Bu bölgede zaten kayıtlı bir kedi var. Gördüğün kedi bu mu?',
        ),
        findsOneWidget,
      );
      expect(find.text('tekir'), findsOneWidget);
      // still on the location step underneath — the modal is an overlay,
      // never a dead end (docs/product/cats.md/trust.md: advisory only).
      expect(find.text('Fotoğraf (zorunlu)'), findsNothing);
    },
  );

  testWidgets(
    'tapping a duplicate candidate opens that cat, not a broken navigator pop',
    (tester) async {
      // Regression: the modal is a state-driven overlay atop /add-cat, not
      // a pushed route — tapping a candidate must go(/cats/:id) directly,
      // never Navigator.pop() first (which would instead close /add-cat).
      final api = _FakeAddCatApi()
        ..nearbyResult = const [
          DuplicateCandidate(id: 'cat-1', name: 'tekir', primaryPhoto: ''),
        ];
      await _pumpAddCat(tester, api);
      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('tekir'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('cat detail cat-1'), findsOneWidget);
      expect(find.byType(AddCatScreen), findsNothing);
    },
  );

  testWidgets(
    '"yine de ekle" continues past the duplicate modal to the details step',
    (tester) async {
      final api = _FakeAddCatApi()
        ..nearbyResult = const [
          DuplicateCandidate(id: 'cat-1', name: 'tekir', primaryPhoto: ''),
        ];
      await _pumpAddCat(tester, api);
      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Hayır, farklı bir kedi — yine de ekle'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Fotoğraf (zorunlu)'), findsOneWidget);
    },
  );

  testWidgets(
    'saving without a photo shows a validation message and never submits',
    (tester) async {
      final api = _FakeAddCatApi();
      await _pumpAddCat(tester, api);
      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Kaydet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Kaydetmeden önce bir fotoğraf ekle'), findsOneWidget);
    },
  );

  testWidgets(
    'picking a photo and saving successfully navigates to the created cat',
    (tester) async {
      final api = _FakeAddCatApi()
        ..createResult = CatDetail(
          id: 'new-cat-id',
          name: '',
          lat: 41.03,
          lng: 28.98,
          areaLabel: null,
          primaryPhoto: '/v1/media/objects/x.jpg',
          createdAt: DateTime.utc(2026, 1, 1),
          lastUpdateAt: null,
        );
      await _pumpAddCat(tester, api);
      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      fakePlatform.nextFile = XFile.fromData(
        _validPngBytes,
        name: 'photo.jpg',
        path: 'photo.jpg',
      );
      await _pickPhoto(tester);

      await tester.tap(find.text('Kaydet'));
      await tester.pump();
      // the page-transition animation to /cats/:id needs longer than the
      // other pumps in this file to fully remove the old route.
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('cat detail new-cat-id'), findsOneWidget);
      expect(find.byType(AddCatScreen), findsNothing);
    },
  );

  testWidgets('a failed save shows a retry state that resubmits on tap', (
    tester,
  ) async {
    final api = _FakeAddCatApi()..createError = const AddCatNetworkException();
    await _pumpAddCat(tester, api);
    await tester.tap(find.text('Bu konumu kullan'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    fakePlatform.nextFile = XFile.fromData(
      _validPngBytes,
      name: 'photo.jpg',
      path: 'photo.jpg',
    );
    await _pickPhoto(tester);

    await tester.tap(find.text('Kaydet'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Bağlantı sorunu, tekrar dene.'), findsOneWidget);
    expect(find.text('Tekrar dene'), findsOneWidget);

    api.createError = null;
    api.createResult = CatDetail(
      id: 'new-cat-id',
      name: '',
      lat: 41.03,
      lng: 28.98,
      areaLabel: null,
      primaryPhoto: null,
      createdAt: DateTime.utc(2026, 1, 1),
      lastUpdateAt: null,
    );
    await tester.tap(find.text('Tekrar dene'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('cat detail new-cat-id'), findsOneWidget);
    expect(find.byType(AddCatScreen), findsNothing);
  });
}
