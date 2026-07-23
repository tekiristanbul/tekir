import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/map/data/cats_api.dart';
import 'package:app/features/map/data/location_service.dart';
import 'package:app/features/map/ui/cats_map_notifier.dart';
import 'package:app/main.dart';

class _FakeCatsApi implements CatsApi {
  _FakeCatsApi(this.markers);

  final List<CatMarker> markers;

  @override
  Future<List<CatMarker>> fetchInBounds(LatLngBounds bounds) async => markers;
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
            catsApiProvider.overrideWithValue(_FakeCatsApi(const [])),
          ],
          child: const CatsOfIstanbulApp(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(FlutterMap), findsOneWidget);
      expect(
        find.text('location unavailable — showing istanbul'),
        findsOneWidget,
      );
    },
  );

  testWidgets('shows the empty-state banner once loaded with no cats in view', (
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
          catsApiProvider.overrideWithValue(_FakeCatsApi(const [])),
        ],
        child: const CatsOfIstanbulApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('no cats in this area yet'), findsOneWidget);
  });
}
