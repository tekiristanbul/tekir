import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:app/features/map/data/location_service.dart';
import 'package:app/features/map/ui/cats_map_notifier.dart';
import 'package:app/main.dart';

// GoogleMap's onMapCreated/onCameraIdle never fire under plain `flutter
// test` (there's no real platform view backing it), so the fetch pipeline
// that normally populates catsMapProvider never runs here. Driving its
// state directly keeps these tests about the banner logic, not about
// mocking google_maps_flutter's platform channel.
class _FixedCatsMapNotifier extends CatsMapNotifier {
  _FixedCatsMapNotifier(this._state);

  final CatsMapState _state;

  @override
  CatsMapState build() => _state;
}

void main() {
  testWidgets(
    'opens on the map and shows the fallback banner when location is unavailable',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            initialLocationProvider.overrideWith(
              (ref) async => const ResolvedLocation(
                center: istanbulFallback,
                isFallback: true,
              ),
            ),
            catsMapProvider.overrideWith(
              () => _FixedCatsMapNotifier(const CatsMapState()),
            ),
          ],
          child: const CatsOfIstanbulApp(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(GoogleMap), findsOneWidget);
      expect(
        find.text('location unavailable — showing istanbul'),
        findsOneWidget,
      );
    },
  );

  testWidgets('shows the empty-radius card once loaded with no cats in view', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialLocationProvider.overrideWith(
            (ref) async => const ResolvedLocation(
              center: istanbulFallback,
              isFallback: false,
            ),
          ),
          catsMapProvider.overrideWith(
            () => _FixedCatsMapNotifier(
              const CatsMapState(
                hasLoadedOnce: true,
                markers: [],
                searchRadiusMeters: 300,
              ),
            ),
          ),
        ],
        child: const CatsOfIstanbulApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('bu 300 metrede henüz kayıtlı kedi yok'), findsOneWidget);
    expect(find.text('ilk kediyi ekle'), findsOneWidget);
    expect(find.text('alanı genişlet'), findsOneWidget);
  });
}
