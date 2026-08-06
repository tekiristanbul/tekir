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
  bool _atMinZoom = false;

  // prototype/app.js's `mapHelpFilter` (map.js's renderLeafletMarkers):
  // hides every non-alerted marker instead of navigating or refetching —
  // a pure client-side view over the cats already fetched for the current
  // viewport.
  bool _helpFilterOn = false;

  // Tracks whether the marker-preview sheet's showModalBottomSheet future
  // is currently pending, so _toggleHelpFilter knows whether it needs to
  // pop an open sheet (rather than just clearing provider state) when the
  // filter turns on and hides the selected marker.
  bool _sheetOpen = false;

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
    final visibleCats = _helpFilterOn
        ? cats.where((cat) => cat.needsHelp).toList()
        : cats;

    final markers = await Future.wait(
      visibleCats.map((cat) async {
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

  void _toggleHelpFilter() {
    setState(() => _helpFilterOn = !_helpFilterOn);
    final mapState = ref.read(catsMapProvider);
    final selected = mapState.selectedMarker;
    // Turning the filter on hides any marker that doesn't need help — if
    // that's the currently selected one, its highlight and preview sheet
    // must go with it, or the visible selection would point at a marker
    // the map no longer shows.
    final clearsSelection =
        _helpFilterOn && selected != null && !selected.needsHelp;
    if (clearsSelection) {
      ref.read(catsMapProvider.notifier).clearSelection();
      if (_sheetOpen) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
    unawaited(
      _rebuildMarkers(mapState.markers, clearsSelection ? null : selected?.id),
    );
  }

  Future<void> _openPreviewSheet(CatMarker cat) async {
    _sheetOpen = true;
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
    _sheetOpen = false;
    // reached on every dismissal path — swipe-down, scrim tap, the
    // explicit pop() above, or _toggleHelpFilter's programmatic pop — so
    // the selection (and marker highlight) always clears and the user is
    // left on the map, per issue #21.
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

  void _onCameraMove(CameraPosition position) {
    // tracks whether "alanı genişlet" can still widen anything; the small
    // epsilon absorbs the sdk reporting e.g. 12.000001 at the floor.
    final atMin = position.zoom <= istanbulMinZoom + 0.01;
    if (atMin != _atMinZoom) setState(() => _atMinZoom = atMin);
  }

  Future<void> _fetchVisible() async {
    final controller = _controller;
    if (controller == null) return;
    final bounds = await controller.getVisibleRegion();
    await ref.read(catsMapProvider.notifier).fetchForBounds(bounds);
  }

  // A user-visible retry, never wired to camera-idle refetches: only this
  // path bumps the attempt counter that remounts the initial-read gate.
  Future<void> _retryVisible() async {
    final controller = _controller;
    if (controller == null) return;
    final bounds = await controller.getVisibleRegion();
    await ref.read(catsMapProvider.notifier).retryForBounds(bounds);
  }

  @override
  Widget build(BuildContext context) {
    final initialLocation = ref.watch(initialLocationProvider);
    final mapState = ref.watch(catsMapProvider);
    final isInitialRead = mapState.isLoading && !mapState.hasLoadedOnce;
    final isEmptyRadius =
        mapState.hasLoadedOnce &&
        !mapState.isLoading &&
        mapState.error == null &&
        mapState.markers.isEmpty;
    // app-states.html's 07/13 frames swap the topbar search placeholder to
    // this copy while the map itself is loading or the radius is empty;
    // the prototype's static "Mahalle veya sokak ara" is the normal-state
    // baseline everywhere else.
    final searchHint = (isInitialRead || isEmptyRadius)
        ? 'bu civarda ara'
        : 'Mahalle veya sokak ara';

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
            left: AppSpacing.s4,
            // clears the notifications button parked at the same top
            // offset on the right (map_screen.dart's own issue #78
            // addition — no prototype IA, so it stays a corner button
            // instead of folding into this topbar).
            right: AppSpacing.s4 + kTapMin + AppSpacing.s2,
            child: PointerInterceptor(
              child: _MapSearchField(hintText: searchHint),
            ),
          ),
          Positioned(
            top:
                MediaQuery.of(context).padding.top +
                AppSpacing.s3 +
                kTapMin +
                AppSpacing.s2,
            left: AppSpacing.s4,
            right: AppSpacing.s4,
            child: PointerInterceptor(
              child: _MapChipRow(
                helpFilterOn: _helpFilterOn,
                onToggleHelpFilter: _toggleHelpFilter,
              ),
            ),
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
          onCameraMove: _onCameraMove,
        ),
        if (showFallbackBanner) const _FallbackLocationBanner(),
        if (isInitialRead)
          // state 13 · harita yükleniyor. keyed on the attempt counter so
          // a retry remounts the gate and earns a fresh 400 ms of silence.
          _InitialReadOverlay(
            key: ValueKey(mapState.attempt),
            locationKnown: !showFallbackBanner,
            onRetry: _retryVisible,
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
                child: MapErrorBanner(onRetry: _retryVisible),
              ),
            ),
        ],
        if (isEmptyRadius)
          // state 07 · civarda kayıt yok. no user dot is drawn: a
          // screen-center dot stops being the user's position the moment
          // the camera pans, and nothing anchors it to the real
          // coordinate yet.
          Positioned(
            left: AppSpacing.s4,
            right: AppSpacing.s4,
            bottom: _fabClearance,
            child: PointerInterceptor(
              child: EmptyRadiusCard(
                searchRadiusMeters: mapState.searchRadiusMeters,
                onAddCat: _addFirstCat,
                onWidenArea: _atMinZoom ? null : _widenArea,
              ),
            ),
          ),
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
      message: 'konum alınamadı — istanbul gösteriliyor',
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

/// The map topbar's search field (prototype/app.js's `renderMap`,
/// `.search-field`) — visual parity only. The prototype's own input has no
/// wired handler either (no oninput, no search-results rendering; the
/// audit at docs/design/issue-121-visual-parity-audit.md confirmed this),
/// so this stays a plain typeable field with no behavior behind it rather
/// than inventing a search feature issue #121 doesn't scope.
class _MapSearchField extends StatelessWidget {
  const _MapSearchField({required this.hintText});

  final String hintText;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.94),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.full),
        side: const BorderSide(color: AppColors.lineStrong),
      ),
      elevation: 1,
      shadowColor: const Color(0x122A1F1B),
      child: SizedBox(
        height: kTapMin,
        child: Row(
          // stretches the TextField to the full 44px height so its
          // semantics/hit-test size meets the tap-target guideline instead
          // of shrinking to the text's own line height.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(width: AppSpacing.s4),
            const Icon(Icons.search, size: 17, color: AppColors.muted),
            const SizedBox(width: AppSpacing.s2),
            Expanded(
              child: TextField(
                style: const TextStyle(fontSize: 15, color: AppColors.ink),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: hintText,
                  hintStyle: const TextStyle(color: AppColors.faint),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.s4),
          ],
        ),
      ),
    );
  }
}

/// The map topbar's chip row (prototype/app.js's `renderMapChrome`) — only
/// the needs-help filter ships here. The prototype's second chip
/// ("konum kapalı", shown only once `state.locationGranted === false`)
/// depends on the location-permission screen issue #121 leaves open
/// pending a product decision (docs/design/app-states.md's open question
/// on state 06) — omitted rather than guessed.
class _MapChipRow extends StatelessWidget {
  const _MapChipRow({
    required this.helpFilterOn,
    required this.onToggleHelpFilter,
  });

  final bool helpFilterOn;
  final VoidCallback onToggleHelpFilter;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: _HelpFilterChip(isOn: helpFilterOn, onTap: onToggleHelpFilter),
    );
  }
}

/// `.chip.is-warm` (prototype/styles.css): bolder than a plain chip even
/// off, so it reads as "the alert filter" at a glance against the rest of
/// the map chrome.
class _HelpFilterChip extends StatelessWidget {
  const _HelpFilterChip({required this.isOn, required this.onTap});

  final bool isOn;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final background = isOn
        ? AppColors.help
        : Colors.white.withValues(alpha: 0.94);
    final foreground = isOn ? AppColors.helpInk : AppColors.helpStrong;
    // visible pill stays 32px tall (prototype's `.chip`); the tap target
    // still meets the 44px minimum (`.chip::before`'s invisible hit-area
    // expansion) via the surrounding InkWell instead of the visible chrome.
    return Semantics(
      container: true,
      excludeSemantics: true,
      button: true,
      toggled: isOn,
      label: 'yardım gerekiyor filtresi',
      onTap: onTap,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.full),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: kTapMin),
            alignment: Alignment.center,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(AppRadius.full),
                border: Border.all(color: AppColors.help),
                boxShadow: isOn
                    ? const [
                        BoxShadow(
                          color: Color(0x122A1F1B),
                          offset: Offset(0, 1),
                          blurRadius: 2,
                        ),
                      ]
                    : null,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s3,
                  vertical: AppSpacing.s2 - 2,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 14,
                      color: foreground,
                    ),
                    const SizedBox(width: AppSpacing.s1),
                    // Flexible (not a bare Text) so the label shrinks
                    // instead of overflowing the chip row's positioned
                    // width budget at large text-scale factors.
                    Flexible(
                      child: Text(
                        'yardım gerekiyor',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: foreground,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
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
