import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../data/cat_marker.dart';
import '../data/cats_api.dart';
import '../data/location_service.dart';

class CatsMapState {
  const CatsMapState({
    this.markers = const [],
    this.isLoading = false,
    this.hasLoadedOnce = false,
    this.error,
    this.selectedMarker,
    this.attempt = 0,
    this.searchRadiusMeters,
  });

  final List<CatMarker> markers;
  final bool isLoading;
  final bool hasLoadedOnce;
  final Object? error;

  /// Monotonic fetch counter. The screen keys its InitialReadGate on this
  /// so a retry remounts the gate and gets a fresh 400 ms of silence
  /// (docs/design/app-states.md, timing contract).
  final int attempt;

  /// Radius in meters of the viewport the shown [markers] were fetched
  /// for — center to the nearest edge of the request's bounds. State 07's
  /// "bu N metrede" copy must come from this real search radius, never a
  /// hardcoded number (docs/design/app-states.md, state 07). Null until
  /// the first fetch completes.
  final double? searchRadiusMeters;

  /// The cat whose marker-preview sheet is currently open (issue #21
  /// prototype-parity correction: a marker tap opens a preview sheet over
  /// the map, not a direct navigation — see prototype/app.js's openSheet).
  /// Null when no sheet is open.
  final CatMarker? selectedMarker;

  CatsMapState copyWith({
    List<CatMarker>? markers,
    bool? isLoading,
    bool? hasLoadedOnce,
    Object? error,
    bool clearError = false,
    CatMarker? selectedMarker,
    bool clearSelectedMarker = false,
    int? attempt,
    double? searchRadiusMeters,
  }) {
    return CatsMapState(
      markers: markers ?? this.markers,
      isLoading: isLoading ?? this.isLoading,
      hasLoadedOnce: hasLoadedOnce ?? this.hasLoadedOnce,
      error: clearError ? null : (error ?? this.error),
      selectedMarker: clearSelectedMarker
          ? null
          : (selectedMarker ?? this.selectedMarker),
      attempt: attempt ?? this.attempt,
      searchRadiusMeters: searchRadiusMeters ?? this.searchRadiusMeters,
    );
  }
}

/// Center-to-nearest-edge distance of [bounds] in meters — the effective
/// search radius of a bbox fetch.
double searchRadiusOf(LatLngBounds bounds) {
  final centerLat = (bounds.southwest.latitude + bounds.northeast.latitude) / 2;
  final centerLng =
      (bounds.southwest.longitude + bounds.northeast.longitude) / 2;
  final toWestEdge = Geolocator.distanceBetween(
    centerLat,
    centerLng,
    centerLat,
    bounds.southwest.longitude,
  );
  final toSouthEdge = Geolocator.distanceBetween(
    centerLat,
    centerLng,
    bounds.southwest.latitude,
    centerLng,
  );
  return toWestEdge < toSouthEdge ? toWestEdge : toSouthEdge;
}

/// Fetches cats for the visible map viewport. Guards against out-of-order
/// responses (a slow request for an old viewport landing after a newer one)
/// with a monotonic request id — only the most recently *started* request is
/// ever allowed to write to state.
class CatsMapNotifier extends Notifier<CatsMapState> {
  int _requestId = 0;

  @override
  CatsMapState build() => const CatsMapState();

  Future<void> fetchForBounds(LatLngBounds bounds) async {
    final requestId = ++_requestId;
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      attempt: state.attempt + 1,
    );

    try {
      final markers = await ref.read(catsApiProvider).fetchInBounds(bounds);
      if (requestId != _requestId) return;
      state = CatsMapState(
        markers: markers,
        isLoading: false,
        hasLoadedOnce: true,
        attempt: state.attempt,
        searchRadiusMeters: searchRadiusOf(bounds),
      );
    } catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(isLoading: false, hasLoadedOnce: true, error: e);
    }
  }

  /// Selects [cat] — highlights its marker and opens its preview sheet.
  /// Cluster/camera/bbox-fetch behavior is untouched by this.
  void selectCat(CatMarker cat) {
    state = state.copyWith(selectedMarker: cat);
  }

  /// Clears the current selection — the sheet closes (if still open) and
  /// the highlighted marker returns to its normal size/ring. The user stays
  /// on the map; this never navigates.
  void clearSelection() {
    state = state.copyWith(clearSelectedMarker: true);
  }
}

final catsMapProvider = NotifierProvider<CatsMapNotifier, CatsMapState>(
  CatsMapNotifier.new,
);

final initialLocationProvider = FutureProvider((ref) {
  return ref.watch(locationServiceProvider).resolveInitialCenter();
});
