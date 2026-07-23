import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  });

  final List<CatMarker> markers;
  final bool isLoading;
  final bool hasLoadedOnce;
  final Object? error;

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
  }) {
    return CatsMapState(
      markers: markers ?? this.markers,
      isLoading: isLoading ?? this.isLoading,
      hasLoadedOnce: hasLoadedOnce ?? this.hasLoadedOnce,
      error: clearError ? null : (error ?? this.error),
      selectedMarker: clearSelectedMarker
          ? null
          : (selectedMarker ?? this.selectedMarker),
    );
  }
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
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final markers = await ref.read(catsApiProvider).fetchInBounds(bounds);
      if (requestId != _requestId) return;
      state = CatsMapState(
        markers: markers,
        isLoading: false,
        hasLoadedOnce: true,
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
