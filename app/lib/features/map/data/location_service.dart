import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/geo/istanbul_bounds.dart';
import '../../../core/geo/location_permission.dart';

/// Galata tower — a fixed, hard-coded point roughly central to the
/// product's active istanbul area (issue #235). The map opens on this at
/// [istanbulFallbackZoom], a broad-area zoom, rather than street level, so
/// the fallback reads as "istanbul" rather than a single landmark. No
/// live cat-density calculation feeds this; it's deliberately static and
/// only tuned by hand.
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
/// denial, a disabled location service, a timeout, an invalid reading, or
/// a resolved position outside the supported istanbul area all fall back
/// to [istanbulFallback] instead of blocking the map or centering on an
/// irrelevant place (issue #235).
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
      final resolved = LatLng(position.latitude, position.longitude);
      // A device position clearly outside the product's supported area (or,
      // via NaN comparisons always failing, an invalid reading) is no more
      // useful than no location at all — issue #235. Falls back exactly
      // like a disabled service: silently, without permissionDenied.
      if (!istanbulBounds.contains(resolved)) {
        return const ResolvedLocation(
          center: istanbulFallback,
          isFallback: true,
        );
      }
      return ResolvedLocation(center: resolved, isFallback: false);
    } catch (_) {
      return const ResolvedLocation(center: istanbulFallback, isFallback: true);
    }
  }

  /// The `konum iznini aç` cta's recovery action (issue #262) — see
  /// [recoverLocationPermission] for why re-requesting alone isn't enough.
  /// Discover's own service exposes the identical method against the same
  /// shared implementation.
  Future<void> recoverPermission() => recoverLocationPermission();
}

final locationServiceProvider = Provider<LocationService>(
  (ref) => LocationService(),
);
