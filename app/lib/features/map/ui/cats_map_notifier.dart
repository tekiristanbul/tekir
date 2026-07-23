import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/cat_marker.dart';
import '../data/cats_api.dart';
import '../data/location_service.dart';

class CatsMapState {
  const CatsMapState({
    this.markers = const [],
    this.isLoading = false,
    this.hasLoadedOnce = false,
    this.error,
  });

  final List<CatMarker> markers;
  final bool isLoading;
  final bool hasLoadedOnce;
  final Object? error;

  CatsMapState copyWith({
    List<CatMarker>? markers,
    bool? isLoading,
    bool? hasLoadedOnce,
    Object? error,
    bool clearError = false,
  }) {
    return CatsMapState(
      markers: markers ?? this.markers,
      isLoading: isLoading ?? this.isLoading,
      hasLoadedOnce: hasLoadedOnce ?? this.hasLoadedOnce,
      error: clearError ? null : (error ?? this.error),
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
}

final catsMapProvider = NotifierProvider<CatsMapNotifier, CatsMapState>(
  CatsMapNotifier.new,
);

final initialLocationProvider = FutureProvider((ref) {
  return ref.watch(locationServiceProvider).resolveInitialCenter();
});
