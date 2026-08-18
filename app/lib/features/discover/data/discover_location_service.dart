import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/geo/istanbul_bounds.dart';
import '../../../core/geo/location_permission.dart';

/// The result of resolving the caller's own location for discover's two
/// location-aware tabs (nearby/needs-help, issue #82). Distinct from
/// [LocationService] (features/map/data/location_service.dart) only in what
/// it reports, not in what the screen does with it: both surfaces fall back
/// to the same fixed istanbul center, and neither ever blocks. The reason
/// this still enumerates its failure modes is the distance column — a
/// figure the caller reads as "how far from me", which would be a plain lie
/// against a substituted point. So discover keeps the outcome, falls back
/// for the query, and drops the distance instead of faking it.
sealed class DiscoverLocationOutcome {
  const DiscoverLocationOutcome();
}

class DiscoverLocationResolved extends DiscoverLocationOutcome {
  const DiscoverLocationResolved({required this.lat, required this.lng});

  final double lat;
  final double lng;
}

/// Permission is currently denied, but asking again may still succeed (the
/// user hasn't permanently dismissed it) — the recovery action re-requests
/// permission.
class DiscoverLocationPermissionDenied extends DiscoverLocationOutcome {
  const DiscoverLocationPermissionDenied();
}

/// Permission was denied permanently (e.g. "don't ask again") — re-asking
/// in-app can never succeed; the only recovery is the system settings
/// screen.
class DiscoverLocationPermissionDeniedForever extends DiscoverLocationOutcome {
  const DiscoverLocationPermissionDeniedForever();
}

/// The device's location service (gps) itself is off, independent of this
/// app's own permission grant.
class DiscoverLocationServiceDisabled extends DiscoverLocationOutcome {
  const DiscoverLocationServiceDisabled();
}

/// Permission and service are fine, but resolving a position failed or
/// timed out — a transient condition worth a plain retry.
class DiscoverLocationUnavailable extends DiscoverLocationOutcome {
  const DiscoverLocationUnavailable();
}

/// A position resolved cleanly but lands outside the product's supported
/// istanbul area — a reviewer or a traveller opening the app from another
/// city. Sending it to `GET /v1/cats/discover` earns a `400 invalid area`,
/// so it is caught here and treated exactly like the map's own
/// out-of-bounds fallback ([LocationService.resolveInitialCenter]).
class DiscoverLocationOutOfArea extends DiscoverLocationOutcome {
  const DiscoverLocationOutOfArea();
}

/// Resolves the caller's current location for discover's nearby/needs-help
/// tabs. Never throws — every failure mode maps to one of the outcomes
/// above instead.
class DiscoverLocationService {
  Future<DiscoverLocationOutcome> resolve() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        return const DiscoverLocationPermissionDeniedForever();
      }
      if (permission == LocationPermission.denied) {
        return const DiscoverLocationPermissionDenied();
      }

      if (!await Geolocator.isLocationServiceEnabled()) {
        return const DiscoverLocationServiceDisabled();
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 8),
        ),
      );
      if (!istanbulBounds.contains(
        LatLng(position.latitude, position.longitude),
      )) {
        return const DiscoverLocationOutOfArea();
      }
      return DiscoverLocationResolved(
        lat: position.latitude,
        lng: position.longitude,
      );
    } catch (_) {
      return const DiscoverLocationUnavailable();
    }
  }

  /// The `konum iznini aç` action on discover's fallback note. Shares the
  /// map cta's implementation ([recoverLocationPermission]) — a plain
  /// re-resolve can't recover a denial iOS has stopped re-prompting for.
  Future<void> recoverPermission() => recoverLocationPermission();
}

final discoverLocationServiceProvider = Provider<DiscoverLocationService>(
  (ref) => DiscoverLocationService(),
);
