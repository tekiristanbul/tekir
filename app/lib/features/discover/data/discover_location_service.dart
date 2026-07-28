import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

/// The result of resolving the caller's own location for discover's two
/// location-aware tabs (nearby/needs-help, issue #82). Distinct from
/// [LocationService] (features/map/data/location_service.dart), which the
/// map screen keeps using unchanged: that service always succeeds by
/// silently falling back to a fixed istanbul landmark, which is the right
/// behavior for centering a camera but the wrong one here — this screen
/// shows the caller a real "distance from you" figure, so silently
/// substituting a fake point would just show a wrong number with no way to
/// tell it's wrong. Every failure mode is instead a distinct, recoverable
/// state the screen can show and offer to retry.
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
      return DiscoverLocationResolved(
        lat: position.latitude,
        lng: position.longitude,
      );
    } catch (_) {
      return const DiscoverLocationUnavailable();
    }
  }
}

final discoverLocationServiceProvider = Provider<DiscoverLocationService>(
  (ref) => DiscoverLocationService(),
);
