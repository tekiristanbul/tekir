import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../../core/analytics/analytics.dart';
import '../../../core/geo/istanbul_bounds.dart';
import '../../../core/states/initial_read_gate.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/ui/auth_gate.dart';
import '../data/cat_marker.dart';
import '../data/location_service.dart';
import '../data/map_style.dart';
import '../data/marker_bitmap_builder.dart';
import 'cat_preview_sheet.dart';
import 'cats_map_notifier.dart';
import 'map_states.dart';

/// istanbul street-level: about 2-3 streets, per docs/product/map.md.
const _initialZoom = 17.0;
const _debounceDuration = Duration(milliseconds: 400);

// how far a single cluster tap zooms in. fitting the camera to the
// cluster's own bounds (CameraUpdate.newLatLngBounds) sounds more
// "precise", but for a tight cluster (markers a few meters apart, like
// the seeded galata group) the bounds-fit zoom can come out *lower* than
// the current zoom — the tap would then not zoom in at all, and the
// cluster would never split. a fixed step guarantees forward progress on
// every tap, splitting any cluster within a couple of taps.
const _clusterTapZoomStep = 2.0;

// clustering itself is native (google_maps_flutter's own ClusterManager,
// which wraps Google's official @googlemaps/markerclusterer on web) — every
// cat marker just tags itself with this id and the sdk groups them.
const _catsClusterManagerId = ClusterManagerId('cats');

// keeps state 07's card clear of the shell's center-floating add-cat fab
// (app_shell.dart: 46 px diameter floating ~16 px above the body bottom).
const _fabClearance = 80.0;

// how far "alanı genişlet" zooms out per tap — the inverse of the cluster
// tap's fixed step, for the same reason: guaranteed progress per tap.
const _widenAreaZoomStep = 2.0;

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  GoogleMapController? _controller;
  Timer? _debounce;
  Set<Marker> _markers = {};
  int _markerBuildGeneration = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  // rebuilds the marker set (fetching/decoding each cat's photo into a
  // BitmapDescriptor) whenever the fetched cat list or the selected marker
  // changes — selection re-renders that one pin larger/ringed (prototype's
  // .marker.is-selected). guarded by a generation counter so a slow rebuild
  // from stale inputs can't clobber a newer one that finished first.
  Future<void> _rebuildMarkers(List<CatMarker> cats, String? selectedId) async {
    final generation = ++_markerBuildGeneration;
    final bitmaps = ref.read(markerBitmapBuilderProvider);

    final markers = await Future.wait(
      cats.map((cat) async {
        final icon = await bitmaps.pin(
          cacheKey: cat.id,
          photoUrl: cat.primaryPhoto,
          needsHelp: cat.needsHelp,
          selected: cat.id == selectedId,
        );
        return Marker(
          markerId: MarkerId(cat.id),
          position: LatLng(cat.lat, cat.lng),
          icon: icon,
          clusterManagerId: _catsClusterManagerId,
          onTap: () => _onCatSelected(cat),
        );
      }),
    );

    if (generation != _markerBuildGeneration || !mounted) return;
    setState(() => _markers = markers.toSet());
  }

  Future<void> _onClusterTap(Cluster cluster) async {
    final controller = _controller;
    if (controller == null) return;
    final currentZoom = await controller.getZoomLevel();
    final targetZoom = math.min(
      currentZoom + _clusterTapZoomStep,
      istanbulMaxZoom,
    );
    await controller.animateCamera(
      CameraUpdate.newLatLngZoom(cluster.position, targetZoom),
    );
  }

  // Selecting a marker highlights it and opens the preview sheet — it never
  // navigates directly (prototype/app.js's selectCat -> openSheet). Only
  // the sheet's "Detaya git" action opens the cat-detail route.
  void _onCatSelected(CatMarker cat) {
    ref.read(catsMapProvider.notifier).selectCat(cat);
  }

  Future<void> _openPreviewSheet(CatMarker cat) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // issue #80 product-owner review: MapScreen is now a
      // StatefulShellRoute branch with its own nested Navigator — without
      // this, the sheet paints underneath the shell's persistent bottom
      // nav/add-cat fab (app_shell.dart) instead of above the whole app.
      useRootNavigator: true,
      builder: (sheetContext) => PointerInterceptor(
        child: CatPreviewSheet(
          cat: cat,
          onOpenDetail: () {
            Navigator.of(sheetContext).pop();
            context.push('/cats/${cat.id}', extra: AnalyticsSource.map);
          },
        ),
      ),
    );
    // reached on every dismissal path — swipe-down, scrim tap, or the
    // explicit pop() above — so the selection (and marker highlight)
    // always clears and the user is left on the map, per issue #21.
    if (!mounted) return;
    ref.read(catsMapProvider.notifier).clearSelection();
  }

  void _onMapCreated(GoogleMapController controller) {
    _controller = controller;
    _fetchVisible();
  }

  void _onCameraIdle() {
    // camera idle / debounce: refetch only once movement settles, never
    // on every frame of a pan or fling gesture.
    _debounce?.cancel();
    _debounce = Timer(_debounceDuration, _fetchVisible);
  }

  Future<void> _fetchVisible() async {
    final controller = _controller;
    if (controller == null) return;
    final bounds = await controller.getVisibleRegion();
    await ref.read(catsMapProvider.notifier).fetchForBounds(bounds);
  }

  @override
  Widget build(BuildContext context) {
    final initialLocation = ref.watch(initialLocationProvider);

    ref.listen(catsMapProvider, (previous, next) {
      final selectionChanged =
          previous?.selectedMarker?.id != next.selectedMarker?.id;
      if (previous?.markers != next.markers || selectionChanged) {
        _rebuildMarkers(next.markers, next.selectedMarker?.id);
      }
      if (selectionChanged && next.selectedMarker != null) {
        _openPreviewSheet(next.selectedMarker!);
      }
    });

    return Scaffold(
      body: Stack(
        children: [
          initialLocation.when(
            data: (resolved) => _buildMap(
              center: resolved.center,
              showFallbackBanner: resolved.isFallback,
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) =>
                _buildMap(center: istanbulFallback, showFallbackBanner: true),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + AppSpacing.s3,
            right: AppSpacing.s4,
            child: PointerInterceptor(child: _NotificationsButton()),
          ),
        ],
      ),
    );
  }

  Future<void> _widenArea() async {
    final controller = _controller;
    if (controller == null) return;
    final currentZoom = await controller.getZoomLevel();
    final targetZoom = math.max(
      currentZoom - _widenAreaZoomStep,
      istanbulMinZoom,
    );
    // the refetch for the wider viewport rides the normal camera-idle
    // debounce; no direct fetch call needed.
    final camera = await controller.getVisibleRegion();
    final center = LatLng(
      (camera.southwest.latitude + camera.northeast.latitude) / 2,
      (camera.southwest.longitude + camera.northeast.longitude) / 2,
    );
    await controller.animateCamera(
      CameraUpdate.newLatLngZoom(center, targetZoom),
    );
  }

  // Gate-at-intent, the exact mechanism of the shell's add-cat fab
  // (app_shell.dart's _AddCatFab): a guest sees AuthGate's prompt sheet
  // first, and `/add-cat` is pushed only once sign-in completes.
  void _addFirstCat() {
    unawaited(
      AuthGate.require(
        context,
        ref,
        contextText: 'Kedi eklemek için giriş yap',
        intent: AnalyticsAuthIntent.addCat,
        onAuthenticated: () => context.push('/add-cat'),
      ),
    );
  }

  Widget _buildMap({required LatLng center, required bool showFallbackBanner}) {
    final mapState = ref.watch(catsMapProvider);
    final isInitialRead = mapState.isLoading && !mapState.hasLoadedOnce;
    final isEmptyRadius =
        mapState.hasLoadedOnce &&
        !mapState.isLoading &&
        mapState.error == null &&
        mapState.markers.isEmpty;

    return Stack(
      children: [
        GoogleMap(
          initialCameraPosition: CameraPosition(
            target: center,
            zoom: _initialZoom,
          ),
          style: catsOfIstanbulMapStyle,
          cameraTargetBounds: CameraTargetBounds(istanbulBounds),
          minMaxZoomPreference: const MinMaxZoomPreference(
            istanbulMinZoom,
            istanbulMaxZoom,
          ),
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          mapToolbarEnabled: false,
          markers: _markers,
          clusterManagers: {
            ClusterManager(
              clusterManagerId: _catsClusterManagerId,
              onClusterTap: _onClusterTap,
            ),
          },
          onMapCreated: _onMapCreated,
          onCameraIdle: _onCameraIdle,
        ),
        if (showFallbackBanner) const _FallbackLocationBanner(),
        if (isInitialRead)
          // state 13 · harita yükleniyor. keyed on the attempt counter so
          // a retry remounts the gate and earns a fresh 400 ms of silence.
          _InitialReadOverlay(
            key: ValueKey(mapState.attempt),
            locationKnown: !showFallbackBanner,
            onRetry: _fetchVisible,
          )
        else ...[
          if (mapState.isLoading) const _LoadingBar(),
          if (mapState.error != null)
            Positioned(
              top: 12,
              left: 12,
              right: 12,
              // on web, GoogleMap is a real platform view (an html
              // element), not flutter-rendered pixels — widgets stacked
              // above it need PointerInterceptor or their taps can fall
              // through to the map underneath.
              child: PointerInterceptor(
                child: MapErrorBanner(onRetry: _fetchVisible),
              ),
            ),
        ],
        if (isEmptyRadius) ...[
          // state 07 · civarda kayıt yok: the dashed radius ring and sonar
          // pulse sit on the user dot, which the camera centers on — with
          // only the fallback center known there is no user dot to mark.
          if (!showFallbackBanner)
            const Center(child: SonarUserDot(showRadiusRing: true)),
          Positioned(
            left: AppSpacing.s4,
            right: AppSpacing.s4,
            bottom: _fabClearance,
            child: PointerInterceptor(
              child: EmptyRadiusCard(
                searchRadiusMeters: mapState.searchRadiusMeters,
                onAddCat: _addFirstCat,
                onWidenArea: _widenArea,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// State 13's screen-level presentation, phased by the shared timing gate
/// (docs/design/app-states.md): nothing before 400 ms; then the map ground
/// dims to 75 % with the sonar user dot; the status band joins at 1.6 s;
/// at 6 s the wait is over and the error state renders. no placeholder
/// pins are drawn — the contract's hard limit allows them only for cats
/// with a real cached position, and no such cache exists in this app, so
/// the map opens pinless (contract gap 3).
class _InitialReadOverlay extends StatelessWidget {
  const _InitialReadOverlay({
    super.key,
    required this.locationKnown,
    required this.onRetry,
  });

  final bool locationKnown;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return InitialReadGate(
      reading: true,
      builder: (context, phase) {
        if (phase == InitialReadPhase.hidden) return const SizedBox.shrink();
        if (phase == InitialReadPhase.timedOut) {
          return Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: PointerInterceptor(child: MapErrorBanner(onRetry: onRetry)),
          );
        }
        return Positioned.fill(
          child: IgnorePointer(
            child: Stack(
              children: [
                // the ground stays visible at 75 % — no spinner screen.
                const Positioned.fill(
                  child: ColoredBox(color: Color(0x40FBF6EE)),
                ),
                if (locationKnown) const Center(child: SonarUserDot()),
                if (phase == InitialReadPhase.skeletonWithStatus)
                  const Positioned(
                    left: 0,
                    right: 0,
                    bottom: _fabClearance + AppSpacing.s3,
                    child: Center(child: MapLoadingStatusPill()),
                  ),
              ],
            ),
          ),
        );
      },
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
        color: AppColors.surface,
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

/// Entry point onto the notification inbox (issue #78) — a glass circle
/// button over the map, matching cat_detail_screen's `_BackCircleButton`
/// visual language. Gate-at-intent, exactly like the shell's add-cat fab
/// (app_shell.dart): a guest's tap shows AuthGate's prompt sheet first
/// (there is nothing to show a guest — an inbox is inherently
/// account-owned state, see docs/product/privacy.md) rather than pushing
/// `/notifications` and failing there. The prototype has no notifications
/// screen at all (issue #78 postdates it), so unlike the profile entry
/// point this button has no prototype IA to match — it stays a corner
/// button rather than moving into the bottom nav (issue #80 product-owner
/// review, finding 1).
class _NotificationsButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      color: Colors.white.withValues(alpha: 0.92),
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _gatedOpenNotifications(context, ref),
        child: const SizedBox(
          width: kTapMin,
          height: kTapMin,
          child: Icon(Icons.notifications_outlined, color: AppColors.ink),
        ),
      ),
    );
  }

  void _gatedOpenNotifications(BuildContext context, WidgetRef ref) {
    unawaited(
      AuthGate.require(
        context,
        ref,
        contextText: 'Bildirimlerini görmek için giriş yap',
        intent: AnalyticsAuthIntent.profile,
        onAuthenticated: () => context.push('/notifications'),
      ),
    );
  }
}
