import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// Galata tower — matches the deterministic istanbul cluster in the seed
/// fixtures, so the fallback view always has cats to show.
const istanbulFallback = LatLng(41.0256, 28.9744);

class ResolvedLocation {
  const ResolvedLocation({required this.center, required this.isFallback});

  final LatLng center;
  final bool isFallback;
}

/// Resolves the map's initial camera center. Never throws: permission
/// denial, a disabled location service, or a timeout all fall back to
/// [istanbulFallback] instead of blocking the map.
class LocationService {
  Future<ResolvedLocation> resolveInitialCenter() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      final granted =
          permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
      if (!granted) {
        return const ResolvedLocation(
          center: istanbulFallback,
          isFallback: true,
        );
      }

      if (!await Geolocator.isLocationServiceEnabled()) {
        return const ResolvedLocation(
          center: istanbulFallback,
          isFallback: true,
        );
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 5),
        ),
      );
      return ResolvedLocation(
        center: LatLng(position.latitude, position.longitude),
        isFallback: false,
      );
    } catch (_) {
      return const ResolvedLocation(center: istanbulFallback, isFallback: true);
    }
  }
}

final locationServiceProvider = Provider<LocationService>(
  (ref) => LocationService(),
);
