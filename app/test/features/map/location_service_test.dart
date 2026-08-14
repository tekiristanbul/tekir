import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';

import 'package:app/features/map/data/location_service.dart';

class _FakeGeolocatorPlatform extends GeolocatorPlatform {
  LocationPermission checkResult = LocationPermission.whileInUse;
  LocationPermission requestResult = LocationPermission.whileInUse;
  bool serviceEnabled = true;
  Position? position;
  Object? positionError;

  @override
  Future<LocationPermission> checkPermission() async => checkResult;

  @override
  Future<LocationPermission> requestPermission() async => requestResult;

  @override
  Future<bool> isLocationServiceEnabled() async => serviceEnabled;

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    if (positionError != null) throw positionError!;
    return position!;
  }
}

Position _positionAt(double lat, double lng) => Position(
  latitude: lat,
  longitude: lng,
  timestamp: DateTime.now(),
  accuracy: 10,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
  floor: null,
  isMocked: false,
);

void main() {
  final fakePlatform = _FakeGeolocatorPlatform();
  GeolocatorPlatform.instance = fakePlatform;

  setUp(() {
    fakePlatform.checkResult = LocationPermission.whileInUse;
    fakePlatform.requestResult = LocationPermission.whileInUse;
    fakePlatform.serviceEnabled = true;
    fakePlatform.position = _positionAt(41.03, 28.98);
    fakePlatform.positionError = null;
  });

  group('LocationService.resolveInitialCenter', () {
    test(
      'in-area: a valid device position inside istanbul is used as-is',
      () async {
        fakePlatform.position = _positionAt(41.03, 28.98);

        final resolved = await LocationService().resolveInitialCenter();

        expect(resolved.center.latitude, 41.03);
        expect(resolved.center.longitude, 28.98);
        expect(resolved.isFallback, isFalse);
        expect(resolved.permissionDenied, isFalse);
      },
    );

    test(
      'denied: a denied permission falls back with permissionDenied set',
      () async {
        fakePlatform.checkResult = LocationPermission.denied;
        fakePlatform.requestResult = LocationPermission.denied;

        final resolved = await LocationService().resolveInitialCenter();

        expect(resolved.center, istanbulFallback);
        expect(resolved.isFallback, isTrue);
        expect(resolved.permissionDenied, isTrue);
      },
    );

    test(
      'unavailable: a disabled location service falls back silently',
      () async {
        fakePlatform.serviceEnabled = false;

        final resolved = await LocationService().resolveInitialCenter();

        expect(resolved.center, istanbulFallback);
        expect(resolved.isFallback, isTrue);
        expect(resolved.permissionDenied, isFalse);
      },
    );

    test('invalid: a failed position read falls back silently', () async {
      fakePlatform.positionError = Exception('timed out');

      final resolved = await LocationService().resolveInitialCenter();

      expect(resolved.center, istanbulFallback);
      expect(resolved.isFallback, isTrue);
      expect(resolved.permissionDenied, isFalse);
    });

    test(
      'out-of-area: a resolved position outside istanbul falls back',
      () async {
        // well outside istanbulBounds — e.g. ankara.
        fakePlatform.position = _positionAt(39.93, 32.86);

        final resolved = await LocationService().resolveInitialCenter();

        expect(resolved.center, istanbulFallback);
        expect(resolved.isFallback, isTrue);
        expect(resolved.permissionDenied, isFalse);
      },
    );
  });
}
