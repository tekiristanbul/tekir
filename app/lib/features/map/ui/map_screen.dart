import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/theme/app_theme.dart';
import '../data/cat_marker.dart';
import '../data/location_service.dart';
import 'cat_pin.dart';
import 'cats_map_notifier.dart';

/// istanbul street-level: about 2-3 streets, per docs/product/map.md.
const _initialZoom = 17.0;
const _debounceDuration = Duration(milliseconds: 400);

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final _mapController = MapController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  void _onMapEvent(MapEvent event) {
    // camera idle / debounce: refetch only once movement settles, never
    // on every frame of a pan or fling gesture.
    _debounce?.cancel();
    _debounce = Timer(_debounceDuration, _fetchVisible);
  }

  void _fetchVisible() {
    ref
        .read(catsMapProvider.notifier)
        .fetchForBounds(_mapController.camera.visibleBounds);
  }

  void _onCatSelected(CatMarker cat) {
    // cat-detail is a separate slice (issue #7 scope); surface the id so
    // that flow has something to receive.
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('selected cat: ${cat.id}')));
  }

  @override
  Widget build(BuildContext context) {
    final initialLocation = ref.watch(initialLocationProvider);

    return Scaffold(
      body: initialLocation.when(
        data: (resolved) => _MapView(
          mapController: _mapController,
          initialCenter: resolved.center,
          showFallbackBanner: resolved.isFallback,
          onMapEvent: _onMapEvent,
          onMapReady: _fetchVisible,
          onCatSelected: _onCatSelected,
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => _MapView(
          mapController: _mapController,
          initialCenter: istanbulFallback,
          showFallbackBanner: true,
          onMapEvent: _onMapEvent,
          onMapReady: _fetchVisible,
          onCatSelected: _onCatSelected,
        ),
      ),
    );
  }
}

class _MapView extends ConsumerWidget {
  const _MapView({
    required this.mapController,
    required this.initialCenter,
    required this.showFallbackBanner,
    required this.onMapEvent,
    required this.onMapReady,
    required this.onCatSelected,
  });

  final MapController mapController;
  final LatLng initialCenter;
  final bool showFallbackBanner;
  final void Function(MapEvent event) onMapEvent;
  final VoidCallback onMapReady;
  final void Function(CatMarker cat) onCatSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mapState = ref.watch(catsMapProvider);

    return Stack(
      children: [
        FlutterMap(
          mapController: mapController,
          options: MapOptions(
            initialCenter: initialCenter,
            initialZoom: _initialZoom,
            onMapEvent: onMapEvent,
            onMapReady: onMapReady,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'org.tekiristanbul.catsofistanbul',
            ),
            MarkerClusterLayerWidget(
              options: MarkerClusterLayerOptions(
                maxClusterRadius: 60,
                size: const Size(44, 44),
                markers: [
                  for (final cat in mapState.markers)
                    Marker(
                      point: LatLng(cat.lat, cat.lng),
                      width: 44,
                      height: 44,
                      child: CatPin(cat: cat, onTap: () => onCatSelected(cat)),
                    ),
                ],
                builder: (context, markers) =>
                    CatClusterPin(count: markers.length),
              ),
            ),
            const RichAttributionWidget(
              attributions: [
                TextSourceAttribution('OpenStreetMap contributors'),
              ],
            ),
          ],
        ),
        if (showFallbackBanner) const _FallbackLocationBanner(),
        if (mapState.isLoading) const _LoadingBar(),
        if (mapState.error != null) _ErrorBanner(onRetry: onMapReady),
        if (mapState.hasLoadedOnce &&
            !mapState.isLoading &&
            mapState.error == null &&
            mapState.markers.isEmpty)
          const _EmptyBanner(),
      ],
    );
  }
}

class _FallbackLocationBanner extends StatelessWidget {
  const _FallbackLocationBanner();

  @override
  Widget build(BuildContext context) {
    return const _TopBanner(
      icon: Icons.location_off,
      message: 'location unavailable — showing istanbul',
    );
  }
}

class _EmptyBanner extends StatelessWidget {
  const _EmptyBanner();

  @override
  Widget build(BuildContext context) {
    return const _TopBanner(
      icon: Icons.pets,
      message: 'no cats in this area yet',
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: Material(
        color: AppColors.panel,
        elevation: 2,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 18),
              const SizedBox(width: 8),
              const Expanded(child: Text("couldn't load cats")),
              TextButton(onPressed: onRetry, child: const Text('retry')),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoadingBar extends StatelessWidget {
  const _LoadingBar();

  @override
  Widget build(BuildContext context) {
    return const Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: LinearProgressIndicator(minHeight: 3),
    );
  }
}

class _TopBanner extends StatelessWidget {
  const _TopBanner({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: Material(
        color: AppColors.panel,
        elevation: 2,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      ),
    );
  }
}
