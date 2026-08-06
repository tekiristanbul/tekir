import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Galata tower — matches the deterministic istanbul cluster in the seed
/// fixtures, so the fallback view always has cats to show.
const istanbulFallback = LatLng(41.0256, 28.9744);

class ResolvedLocation {
  const ResolvedLocation({
    required this.center,
    required this.isFallback,
    this.permissionDenied = false,
  });

  final LatLng center;
  final bool isFallback;

  /// True only when [isFallback] is because permission was never granted or
  /// was denied — never for a disabled location service or a resolution
  /// timeout/error. Only this reason gates the map behind state 06's
  /// full-screen block (docs/design/app-states.md); the other fallback
  /// reasons keep the existing silent-fallback-with-banner behavior.
  final bool permissionDenied;
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
          permissionDenied: true,
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
