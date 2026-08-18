import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:app/core/geo/istanbul_bounds.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/map/data/location_service.dart';
import 'package:app/features/map/ui/cats_map_notifier.dart';
import 'package:app/features/map/ui/map_screen.dart';
import 'package:app/features/map/ui/map_states.dart';

// GoogleMap's platform view never materializes under `flutter test`, so
// (exactly like widget_test.dart) these tests drive catsMapProvider's
// state directly and only ever render the empty-marker map.
class _FixedCatsMapNotifier extends CatsMapNotifier {
  _FixedCatsMapNotifier(this._state);

  final CatsMapState _state;

  @override
  CatsMapState build() => _state;
}

Widget _harness({
  required CatsMapState state,
  bool reduceMotion = false,
  bool fallbackLocation = false,
  bool permissionDenied = false,
}) {
  return ProviderScope(
    overrides: [
      initialLocationProvider.overrideWith(
        (ref) async => ResolvedLocation(
          center: istanbulFallback,
          isFallback: fallbackLocation,
          permissionDenied: permissionDenied,
        ),
      ),
      catsMapProvider.overrideWith(() => _FixedCatsMapNotifier(state)),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: const MapScreen(),
    ),
  );
}

// Pumps past the initialLocationProvider future so MapScreen's real map
// (and any state overlays) are mounted; leaves the timing clock at ~0.
Future<void> _pumpSettledLocation(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  await tester.pump();
}

void main() {
  group('state 13 · harita yükleniyor (timing contract)', () {
    const reading = CatsMapState(isLoading: true);

    testWidgets('shows nothing loading-related before 400 ms', (tester) async {
      await _pumpSettledLocation(tester, _harness(state: reading));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(SonarUserDot), findsNothing);
      expect(find.text('yakındaki kediler getiriliyor'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('dims the ground and pulses the user dot from 400 ms', (
      tester,
    ) async {
      await _pumpSettledLocation(tester, _harness(state: reading));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(SonarUserDot), findsOneWidget);
      expect(find.text('yakındaki kediler getiriliyor'), findsNothing);
    });

    testWidgets('the status band joins only after 1.6 s', (tester) async {
      await _pumpSettledLocation(tester, _harness(state: reading));
      await tester.pump(const Duration(milliseconds: 1500));
      expect(find.text('yakındaki kediler getiriliyor'), findsNothing);

      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('yakındaki kediler getiriliyor'), findsOneWidget);
    });

    testWidgets('at 6 s the wait ends in the error state', (tester) async {
      await _pumpSettledLocation(tester, _harness(state: reading));
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();

      expect(find.text('yakındaki kediler yüklenemedi'), findsOneWidget);
      expect(find.text('tekrar dene'), findsOneWidget);
      expect(find.byType(SonarUserDot), findsNothing);
    });

    testWidgets('without a known location no user dot is invented', (
      tester,
    ) async {
      await _pumpSettledLocation(
        tester,
        _harness(state: reading, fallbackLocation: true),
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(SonarUserDot), findsNothing);
    });

    testWidgets('reduced motion renders the settled frame, nothing animates', (
      tester,
    ) async {
      await _pumpSettledLocation(
        tester,
        _harness(state: reading, reduceMotion: true),
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(SonarUserDot), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('state 07 · civarda kayıt yok', () {
    const empty = CatsMapState(hasLoadedOnce: true, searchRadiusMeters: 300);

    testWidgets('shows the sand card with the real radius and both actions', (
      tester,
    ) async {
      await _pumpSettledLocation(tester, _harness(state: empty));
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.text('bu 300 metrede henüz kayıtlı kedi yok'),
        findsOneWidget,
      );
      expect(
        find.text(
          'gördüğün ilk kediyi eklersen mahalledeki herkes onu takip '
          'edebilir.',
        ),
        findsOneWidget,
      );
      expect(find.text('ilk kediyi ekle'), findsOneWidget);
      expect(find.text('alanı genişlet'), findsOneWidget);
      // a screen-center dot stops being the user's position as soon as
      // the camera pans, so state 07 draws no user dot at all.
      expect(find.byType(SonarUserDot), findsNothing);
    });

    testWidgets('both actions meet the 44 px minimum target', (tester) async {
      await _pumpSettledLocation(tester, _harness(state: empty));
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        tester.getSize(find.widgetWithText(InkWell, 'ilk kediyi ekle')).height,
        greaterThanOrEqualTo(kTapMin),
      );
      expect(
        tester.getSize(find.widgetWithText(InkWell, 'alanı genişlet')).height,
        greaterThanOrEqualTo(kTapMin),
      );
    });

    testWidgets('with only the fallback center no user dot is drawn', (
      tester,
    ) async {
      await _pumpSettledLocation(
        tester,
        _harness(state: empty, fallbackLocation: true),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(SonarUserDot), findsNothing);
      expect(
        find.text('bu 300 metrede henüz kayıtlı kedi yok'),
        findsOneWidget,
      );
    });

    testWidgets('at minimum zoom "alanı genişlet" renders disabled', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: EmptyRadiusCard(
              searchRadiusMeters: 300,
              onAddCat: () {},
              onWidenArea: null,
            ),
          ),
        ),
      );

      final widen = tester.widget<InkWell>(
        find.widgetWithText(InkWell, 'alanı genişlet'),
      );
      expect(widen.onTap, isNull);
    });
  });

  group('no usable location never blocks the map', () {
    const empty = CatsMapState();

    testWidgets('a denied permission still opens the map, with the note', (
      tester,
    ) async {
      await _pumpSettledLocation(
        tester,
        _harness(state: empty, permissionDenied: true, fallbackLocation: true),
      );
      await tester.pump();

      // The pre-0.4.3 behaviour was a full-screen block instead of the map
      // (old state 06). Apple review 0.4.2 hit it by denying the prompt and
      // reported it as an error; nothing about a missing location is an
      // error, so the map renders and the note explains the anchor.
      expect(
        find.text('nerede olduğunu bilmeden haritayı açamıyoruz'),
        findsNothing,
      );
      expect(find.byType(GoogleMap), findsOneWidget);
      expect(
        find.text('konum yok — istanbul merkezi gösteriliyor'),
        findsOneWidget,
      );
      expect(find.text('konum iznini aç'), findsOneWidget);
    });

    testWidgets('the note action meets the 44 px minimum target', (
      tester,
    ) async {
      await _pumpSettledLocation(
        tester,
        _harness(state: empty, permissionDenied: true, fallbackLocation: true),
      );
      await tester.pump();

      expect(
        tester
            .getSize(find.widgetWithText(TextButton, 'konum iznini aç'))
            .height,
        greaterThanOrEqualTo(kTapMin),
      );
    });

    testWidgets('a disabled service or timeout shows the same note', (
      tester,
    ) async {
      await _pumpSettledLocation(
        tester,
        _harness(state: empty, fallbackLocation: true),
      );
      await tester.pump();

      expect(
        find.text('konum yok — istanbul merkezi gösteriliyor'),
        findsOneWidget,
      );
    });

    testWidgets('a real in-area location shows no note at all', (
      tester,
    ) async {
      await _pumpSettledLocation(tester, _harness(state: empty));
      await tester.pump();

      expect(
        find.text('konum yok — istanbul merkezi gösteriliyor'),
        findsNothing,
      );
    });
  });

  group('map read error state', () {
    testWidgets('a failed fetch shows the no-blame banner with one action', (
      tester,
    ) async {
      await _pumpSettledLocation(
        tester,
        _harness(
          state: CatsMapState(hasLoadedOnce: true, error: Exception('down')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('yakındaki kediler yüklenemedi'), findsOneWidget);
      expect(find.text('tekrar dene'), findsOneWidget);
      // raw transport errors are never user-visible (contract global rule).
      expect(find.textContaining('Exception'), findsNothing);
    });
  });

  group('initial fallback viewport (issue #235)', () {
    const state = CatsMapState(hasLoadedOnce: true);

    testWidgets('a real location opens at the close, walking-distance zoom', (
      tester,
    ) async {
      await _pumpSettledLocation(tester, _harness(state: state));
      await tester.pump();

      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      expect(map.initialCameraPosition.zoom, 17.0);
    });

    testWidgets(
      'the istanbul fallback opens broad, not zoomed to a single point',
      (tester) async {
        await _pumpSettledLocation(
          tester,
          _harness(state: state, fallbackLocation: true),
        );
        await tester.pump();

        final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
        expect(map.initialCameraPosition.target, istanbulFallback);
        expect(map.initialCameraPosition.zoom, istanbulFallbackZoom);
        expect(map.initialCameraPosition.zoom, lessThan(17.0));
      },
    );
  });

  group('EmptyRadiusCard.titleFor', () {
    test('uses the real radius, rounded to a readable step', () {
      expect(
        EmptyRadiusCard.titleFor(300),
        'bu 300 metrede henüz kayıtlı kedi yok',
      );
      expect(
        EmptyRadiusCard.titleFor(284),
        'bu 300 metrede henüz kayıtlı kedi yok',
      );
      expect(
        EmptyRadiusCard.titleFor(30),
        'bu 50 metrede henüz kayıtlı kedi yok',
      );
      expect(
        EmptyRadiusCard.titleFor(1400),
        'bu 1,4 kilometrede henüz kayıtlı kedi yok',
      );
      expect(
        EmptyRadiusCard.titleFor(2049),
        'bu 2 kilometrede henüz kayıtlı kedi yok',
      );
    });

    test('stays number-free when no radius is known yet', () {
      expect(
        EmptyRadiusCard.titleFor(null),
        'bu civarda henüz kayıtlı kedi yok',
      );
    });
  });
}
