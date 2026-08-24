import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../../core/analytics/analytics.dart';
import '../../../core/geo/istanbul_bounds.dart';
import '../../../core/motion/press_response.dart';
import '../../../core/motion/tekir_haptics.dart';
import '../../../core/states/fallback_location_note.dart';
import '../../../core/states/initial_read_gate.dart';
import '../../../core/states/inline_spinner.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/identity/session_identity.dart';
import '../../auth/ui/auth_gate.dart';
import '../../discover/ui/cat_search_panel.dart';
import '../../notifications/ui/notifications_notifier.dart';
import '../../profile/ui/profile_notifier.dart';
import '../data/cat_marker.dart';
import '../data/location_service.dart';
import '../data/map_style.dart';
import '../data/marker_layout.dart';
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

// The approved design's bottom measurements (artboard 01 / spec block):
// the add-cat pill sits 44 px above the screen bottom and the locate button
// 112 px, on a 874 px-tall reference screen. Both are measured from the
// safe-area inset here rather than from the raw screen edge, so a device
// with a home indicator does not put the pill underneath it.
const _addCatPillInset = 24.0;
const _addCatPillHeight = 50.0;
const _locateButtonGap = AppSpacing.s4;

double _addCatPillBottom(BuildContext context) =>
    MediaQuery.paddingOf(context).bottom + _addCatPillInset;

double _locateButtonBottom(BuildContext context) =>
    _addCatPillBottom(context) + _addCatPillHeight + _locateButtonGap;

/// Vertical room anything anchored to the bottom of the map has to leave
/// for the add-cat pill and the locate button above it.
double _bottomChromeClearance(BuildContext context) =>
    _locateButtonBottom(context) + kTapMin + AppSpacing.s3;

// how far "alanı genişlet" zooms out per tap — the inverse of the cluster
// tap's fixed step, for the same reason: guaranteed progress per tap.
const _widenAreaZoomStep = 2.0;

// how long the preview sheet stays on the stack after the detail route is
// pushed over it, so the shared photo's flight has a source to leave from.
// Comfortably longer than either platform's page transition (material's
// ~300 ms zoom, cupertino's ~400 ms slide) — the sheet is invisible behind
// the detail for the whole wait, so overshooting costs nothing and
// undershooting would cut the flight.
const _heroFlightClearance = Duration(milliseconds: 500);

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen>
    with WidgetsBindingObserver {
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

  /// Pending removal of a preview sheet the detail route was pushed over —
  /// see [_openDetailFromSheet].
  Timer? _heroFlightClearanceTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _heroFlightClearanceTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  // Covers returning from the settings app the `konum iznini aç` cta may
  // have opened (issue #262) — that path has no in-app callback of its
  // own, only "the app came back to the foreground", so this is the one
  // place that can catch a permission change made there and update the
  // map/banner without requiring a restart.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(initialLocationProvider);
    }
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

    // Cats recorded at the same doorway end up on the same coordinate, and
    // identical positions make the one drawn last the only one that can be
    // tapped: the others are unreachable, not merely hidden. Fanning a
    // coincident group out by a few metres makes each of them its own tap
    // target. It is display only — nothing is written back, and the offset
    // is derived from the cat's own id, so a pin lands in the same place on
    // every rebuild instead of jumping between renders.
    final positions = fanOutCoincident(visibleCats);

    final markers = await Future.wait(
      visibleCats.map((cat) async {
        final selected = cat.id == selectedId;
        final icon = await bitmaps.pin(
          cacheKey: cat.id,
          photoUrl: cat.primaryPhoto,
          needsHelp: cat.needsHelp,
          selected: selected,
        );
        return Marker(
          markerId: MarkerId(cat.id),
          position: positions[cat.id] ?? LatLng(cat.lat, cat.lng),
          icon: icon,
          clusterManagerId: _catsClusterManagerId,
          // The selected pin is always on top; everything else stacks by
          // latitude, southern pins over northern ones, which is what a map
          // reader expects and — more to the point — is stable, so the same
          // cat does not win the overlap one rebuild and lose it the next.
          zIndexInt: selected ? selectedMarkerZIndex : latitudeZIndex(cat.lat),
          onTap: () => _onCatSelected(cat),
        );
      }),
    );

    if (generation != _markerBuildGeneration || !mounted) return;
    setState(() => _markers = markers.toSet());
  }

  Future<void> _onClusterTap(Cluster cluster) async {
    unawaited(TekirHaptics.acknowledge());
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
    // Fired here, synchronously, rather than after the marker set is
    // rebuilt: the pin's own selected state is a re-rendered bitmap that
    // lands a frame or more later, so the hand is what actually
    // acknowledges the tap.
    unawaited(TekirHaptics.acknowledge());
    ref.read(catsMapProvider.notifier).selectCat(cat);
    unawaited(_liftSelectedPinClearOfSheet(cat));
  }

  /// Slides the camera so the tapped pin sits above the preview sheet
  /// rather than behind it.
  ///
  /// The sheet covers roughly the bottom third of the screen, and a pin
  /// tapped low — or near the right edge, where a pin can sit half off the
  /// map — was then hidden by the surface describing it. Nothing marked the
  /// connection between the two.
  ///
  /// Deliberately a nudge, not a recentre: moving the pin to the middle of
  /// the remaining space would throw away the user's own framing of the
  /// neighbourhood, which is the thing they were reading when they tapped.
  Future<void> _liftSelectedPinClearOfSheet(CatMarker cat) async {
    final controller = _controller;
    if (controller == null) return;
    final size = MediaQuery.sizeOf(context);
    // The sheet's own height is not known until it lays out, and this runs
    // before it opens; a third of the screen is what it occupies at the
    // content sizes this sheet can reach.
    final sheetHeight = size.height / 3;
    final screenPoint = await controller.getScreenCoordinate(
      LatLng(cat.lat, cat.lng),
    );
    if (!mounted) return;

    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final pinY = screenPoint.y / devicePixelRatio;
    final pinX = screenPoint.x / devicePixelRatio;
    // The band the sheet will cover, plus the pin's own height so a pin
    // resting exactly on the sheet's edge still clears it.
    final safeBottom = size.height - sheetHeight - 48;
    final dy = pinY > safeBottom ? pinY - safeBottom : 0.0;
    // Horizontal only when the pin is genuinely near an edge.
    const edgeMargin = 56.0;
    final dx = pinX > size.width - edgeMargin
        ? pinX - (size.width - edgeMargin)
        : (pinX < edgeMargin ? pinX - edgeMargin : 0.0);
    if (dy == 0 && dx == 0) return;

    await controller.animateCamera(CameraUpdate.scrollBy(dx, dy));
  }

  void _toggleHelpFilter() {
    unawaited(TekirHaptics.acknowledge());
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
          onOpenDetail: () => _openDetailFromSheet(sheetContext, cat),
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

  /// Opens the cat behind the preview sheet, pushing *before* dismissing.
  ///
  /// This used to pop the sheet and then push the detail, which rendered
  /// the product's central move — this cat, the one you touched on the map
  /// — as a retreat followed by an unrelated arrival, with no relationship
  /// drawn between the sheet's photo and the detail's. Pushing first keeps
  /// the sheet as the departing route for one transition, which is what
  /// lets the shared photo fly across (core/motion/hero_tags.dart).
  ///
  /// The sheet is then removed rather than popped: by that point it is
  /// underneath the detail, so an animated dismissal would be an animation
  /// nobody can see, and popping would take the detail off the stack
  /// instead. Removal waits out the flight so the photo is never orphaned
  /// mid-air.
  ///
  /// Removal applies only while the sheet is still buried. A user who goes
  /// back inside those 500 ms pops the detail and is looking at the sheet
  /// again — removing it then would snatch a surface out from under them
  /// with no animation, which is why [ModalRoute.isCurrent] is checked and
  /// not just [ModalRoute.isActive]. The sheet is left alone in that case
  /// and dismisses normally, as it would have without the flight.
  void _openDetailFromSheet(BuildContext sheetContext, CatMarker cat) {
    final sheetRoute = ModalRoute.of(sheetContext);
    final navigator = Navigator.of(sheetContext);
    context.push('/cats/${cat.id}', extra: AnalyticsSource.map);
    if (sheetRoute == null) return;
    _heroFlightClearanceTimer?.cancel();
    _heroFlightClearanceTimer = Timer(_heroFlightClearance, () {
      if (!navigator.mounted || !sheetRoute.isActive) return;
      if (sheetRoute.isCurrent) return;
      navigator.removeRoute(sheetRoute);
    });
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
    // this copy while the map itself is loading or the radius is empty.
    // The normal-state baseline is no longer "Mahalle veya sokak ara":
    // search is by the cat's own name now (issue #284), and neighbourhood
    // or street search is explicitly out of scope in the approved design,
    // so a placeholder promising it would be a lie.
    final searchHint = (isInitialRead || isEmptyRadius)
        ? 'bu civarda ara'
        : 'kedi ara';

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

    // No location condition blocks the map. A denied permission, a disabled
    // service, a timeout and an out-of-area position all resolve to the
    // fixed istanbul center, and the map opens on greater istanbul with its
    // cats loaded — the product's promise is istanbul's cats, which a
    // visitor who never shares a location is still entitled to see. What
    // changes is the zoom, the suppressed user dot, and the fallback note's
    // cta; nothing renders as an error or a wall.
    return Scaffold(
      body: initialLocation.when(
        data: (resolved) => _buildMapChrome(
          center: resolved.center,
          isFallback: resolved.isFallback,
          searchHint: searchHint,
        ),
        loading: () => const Center(
          child: InlineSpinner(
            size: 28,
            color: AppColors.primary,
            trackColor: AppColors.line,
          ),
        ),
        error: (_, _) => _buildMapChrome(
          center: istanbulFallback,
          isFallback: true,
          searchHint: searchHint,
        ),
      ),
    );
  }

  // The `konum iznini aç` cta's handler (issue #262): recoverable denial
  // re-prompts through the OS dialog and non-recoverable denial opens the
  // app's settings page (LocationService.recoverPermission decides which),
  // then re-runs resolveInitialCenter so the map/banner reflect whatever
  // the user actually chose. Returning from settings is covered separately
  // by didChangeAppLifecycleState, since that path never returns here.
  void _requestLocationPermission() {
    unawaited(_recoverLocationPermission());
  }

  Future<void> _recoverLocationPermission() async {
    await ref.read(locationServiceProvider).recoverPermission();
    if (!mounted) return;
    ref.invalidate(initialLocationProvider);
  }

  Widget _buildMapChrome({
    required LatLng center,
    required bool isFallback,
    required String searchHint,
  }) {
    final mapState = ref.watch(catsMapProvider);
    final topInset = MediaQuery.of(context).padding.top;
    final helpCount = mapState.markers.where((m) => m.needsHelp).length;
    return Stack(
      children: [
        _buildMap(center: center, isFallback: isFallback),
        // The whole top strip is one row (approved design artboard 01):
        // search pill, bell, avatar. The bell and the profile stopped being
        // a corner button and a tab respectively — they are the two things
        // that sit beside search, and nothing else does.
        Positioned(
          top: topInset + AppSpacing.s3,
          left: AppSpacing.s4,
          right: AppSpacing.s4,
          child: PointerInterceptor(
            child: _TopStrip(
              searchHint: searchHint,
              nearbyCount: mapState.hasLoadedOnce
                  ? mapState.markers.length
                  : null,
              onSearch: _openSearch,
            ),
          ),
        ),
        if (helpCount > 0)
          Positioned(
            top: topInset + AppSpacing.s3 + kTapMin + AppSpacing.s2,
            left: AppSpacing.s4,
            // Not stretched: the strip is a statement sized to its own
            // sentence, and a full-width bar would read as a banner.
            child: PointerInterceptor(
              child: _HelpStrip(
                count: helpCount,
                isOn: _helpFilterOn,
                onTap: _toggleHelpFilter,
              ),
            ),
          ),
        // Below the help strip, which itself sits one tap-target below the
        // top strip.
        if (isFallback)
          Positioned(
            top:
                topInset +
                AppSpacing.s3 +
                (kTapMin + AppSpacing.s2) * (helpCount > 0 ? 2 : 1),
            left: AppSpacing.s4,
            right: AppSpacing.s4,
            child: PointerInterceptor(
              child: FallbackLocationNote(
                onEnableLocation: _requestLocationPermission,
              ),
            ),
          ),
        Positioned(
          right: AppSpacing.s4,
          bottom: _locateButtonBottom(context),
          child: PointerInterceptor(child: _LocateButton(onTap: _locate)),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: _addCatPillBottom(context),
          child: PointerInterceptor(
            child: Center(child: _AddCatPill(onTap: _addCat)),
          ),
        ),
      ],
    );
  }

  /// Opens the search panel and, if the user picked a cat, selects it on
  /// the map — the panel never navigates anywhere itself.
  Future<void> _openSearch() async {
    final picked = await CatSearchPanel.push(context);
    if (picked == null || !mounted) return;
    await _revealCat(picked);
  }

  /// Brings [cat] into view and selects it.
  ///
  /// A searched cat is routinely outside the current viewport, and the
  /// shipped selection path only ever nudged a pin that was already on
  /// screen. The camera is moved first so the sheet that follows is
  /// describing something visible; the marker itself arrives with the
  /// camera-idle refetch that the move triggers, so a cat from outside the
  /// loaded set does not have to be fetched separately.
  Future<void> _revealCat(CatMarker cat) async {
    final controller = _controller;
    if (controller != null) {
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(cat.lat, cat.lng), _initialZoom),
      );
    }
    if (!mounted) return;
    ref.read(catsMapProvider.notifier).selectCat(cat);
  }

  /// Recentres on the user's own position (approved design artboard 01).
  ///
  /// A fallback centre is a hard-coded istanbul point, not a location —
  /// centring on it would claim to have found the user. That case re-runs
  /// permission recovery instead, which is the only thing that can actually
  /// answer the request.
  Future<void> _locate() async {
    unawaited(TekirHaptics.acknowledge());
    final resolved = ref.read(initialLocationProvider).value;
    if (resolved == null || resolved.isFallback) {
      _requestLocationPermission();
      return;
    }
    await _controller?.animateCamera(
      CameraUpdate.newLatLngZoom(resolved.center, _initialZoom),
    );
  }

  // Gate-at-intent, the exact mechanism the retired shell fab used
  // (app_shell.dart's _AddCatFab): a guest sees AuthGate's prompt sheet
  // first, and `/add-cat` is pushed only once sign-in completes.
  void _addCat() {
    unawaited(TekirHaptics.acknowledge());
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

  Widget _buildMap({required LatLng center, required bool isFallback}) {
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
            // A fallback center is a fixed, hard-coded istanbul point, not
            // a real location — the close walking-distance zoom would read
            // as pointing at one specific place. Zooming out to the map's
            // own widest allowed view instead shows "greater istanbul", per
            // issue #235.
            zoom: isFallback ? istanbulFallbackZoom : _initialZoom,
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
        if (isInitialRead)
          // state 13 · harita yükleniyor. keyed on the attempt counter so
          // a retry remounts the gate and earns a fresh 400 ms of silence.
          _InitialReadOverlay(
            key: ValueKey(mapState.attempt),
            locationKnown: !isFallback,
            onRetry: _retryVisible,
          )
        else ...[
          if (mapState.isLoading) const _LoadingBar(),
          if (mapState.error != null)
            Positioned(
              top: MediaQuery.of(context).padding.top + AppSpacing.s3,
              left: AppSpacing.s3,
              right: AppSpacing.s3,
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
            bottom: _bottomChromeClearance(context),
            child: PointerInterceptor(
              child: EmptyRadiusCard(
                searchRadiusMeters: mapState.searchRadiusMeters,
                onAddCat: _addCat,
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
            top: MediaQuery.of(context).padding.top + AppSpacing.s3,
            left: AppSpacing.s3,
            right: AppSpacing.s3,
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
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: _bottomChromeClearance(context),
                    child: const Center(child: MapLoadingStatusPill()),
                  ),
              ],
            ),
          ),
        );
      },
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

/// The map's whole top chrome (issue #284, approved design artboard 01):
/// a search pill, the notification bell, and the account avatar, in one
/// 44px row. This replaced three separate things — a decorative search
/// field that was never typeable (issue #138), a corner notifications
/// button, and a profil tab in a bottom bar that no longer exists.
class _TopStrip extends StatelessWidget {
  const _TopStrip({
    required this.searchHint,
    required this.nearbyCount,
    required this.onSearch,
  });

  final String searchHint;

  /// Cats in the current viewport, or null before the first read lands —
  /// the design's "yakında 12". Null rather than 0 so an unread map never
  /// claims there are no cats here.
  final int? nearbyCount;

  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _SearchPill(
            hintText: searchHint,
            nearbyCount: nearbyCount,
            onTap: onSearch,
          ),
        ),
        const SizedBox(width: AppSpacing.s2 + 1),
        const _NotificationsButton(),
        const SizedBox(width: AppSpacing.s2 + 1),
        const _AccountAvatarButton(),
      ],
    );
  }
}

/// The strip's search entry point. Not a field: it opens
/// [CatSearchPanel], which has the real one. A `TextField` here would have
/// to type over a platform view with the map's own gestures underneath it,
/// which is the arrangement issue #138 removed.
class _SearchPill extends StatelessWidget {
  const _SearchPill({
    required this.hintText,
    required this.nearbyCount,
    required this.onTap,
  });

  final String hintText;
  final int? nearbyCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = nearbyCount == null
        ? hintText
        : '$hintText · yakında $nearbyCount';
    return Semantics(
      button: true,
      label: label,
      child: PressResponse(
        child: Material(
          color: AppColors.bgElevated,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.full),
            side: const BorderSide(color: AppColors.lineStrong),
          ),
          elevation: 1,
          shadowColor: const Color(0x122A1F1B),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.full),
            onTap: onTap,
            child: SizedBox(
              height: kTapMin,
              child: Row(
                children: [
                  const SizedBox(width: AppSpacing.s4),
                  const Icon(Icons.search, size: 17, color: AppColors.muted),
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.faint,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s4),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared shape for the strip's two circular controls, so the bell and the
/// avatar are the same object with different contents rather than two
/// buttons that happen to look alike.
class _StripCircle extends StatelessWidget {
  const _StripCircle({
    required this.semanticLabel,
    required this.onTap,
    required this.child,
    this.badge,
  });

  final String semanticLabel;
  final VoidCallback onTap;
  final Widget child;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: PressResponse(
        child: SizedBox(
          width: kTapMin,
          height: kTapMin,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Material(
                color: AppColors.bgElevated,
                shape: const CircleBorder(),
                elevation: 1,
                shadowColor: const Color(0x122A1F1B),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onTap,
                  child: SizedBox(
                    width: kTapMin,
                    height: kTapMin,
                    child: Center(child: child),
                  ),
                ),
              ),
              ?badge,
            ],
          ),
        ),
      ),
    );
  }
}

/// Entry point onto the notification inbox (issue #78), now carrying an
/// unread count (issue #284). Gate-at-intent: a guest's tap shows AuthGate's
/// prompt sheet first — an inbox is inherently account-owned state (see
/// docs/product/privacy.md) — rather than pushing `/notifications` and
/// failing there.
class _NotificationsButton extends ConsumerStatefulWidget {
  const _NotificationsButton();

  @override
  ConsumerState<_NotificationsButton> createState() =>
      _NotificationsButtonState();
}

class _NotificationsButtonState extends ConsumerState<_NotificationsButton> {
  @override
  void initState() {
    super.initState();
    Future.microtask(_loadIfAuthenticated);
  }

  // The badge is persistent chrome, so the inbox's first page is read once
  // the account settles rather than only when the inbox is opened. A guest
  // reads nothing at all.
  void _loadIfAuthenticated() {
    if (!mounted) return;
    final state = ref.read(notificationsProvider);
    if (ref.read(sessionIdentityServiceProvider).cached == null) return;
    if (state.hasLoadedOnce || state.isLoading) return;
    unawaited(ref.read(notificationsProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sessionProvider, (previous, next) {
      if (next.value != null) _loadIfAuthenticated();
    });
    final unread = ref.watch(unreadNotificationCountProvider);
    final label = unread == 0
        ? 'Bildirimler'
        : 'Bildirimler, $unread okunmamış';
    return _StripCircle(
      semanticLabel: label,
      onTap: () => _gatedOpen(context, ref),
      badge: unread == 0
          ? null
          : Positioned(right: 2, top: 1, child: _UnreadBadge(count: unread)),
      child: const Icon(
        Icons.notifications_outlined,
        size: 20,
        color: AppColors.ink,
      ),
    );
  }

  void _gatedOpen(BuildContext context, WidgetRef ref) {
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

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final text = count > unreadBadgeCap ? '$unreadBadgeCap+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 17, minHeight: 17),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.primary,
        shape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: AppColors.bgElevated, width: 2),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 9.5,
          height: 1.1,
          fontWeight: FontWeight.w800,
          color: AppColors.primaryInk,
        ),
      ),
    );
  }
}

/// The account entry point the retired profil tab used to be. Shows the
/// signed-in account's initials, per the approved design; a guest — or an
/// account whose profile has not loaded yet — gets the neutral glyph rather
/// than invented initials.
class _AccountAvatarButton extends ConsumerStatefulWidget {
  const _AccountAvatarButton();

  @override
  ConsumerState<_AccountAvatarButton> createState() =>
      _AccountAvatarButtonState();
}

class _AccountAvatarButtonState extends ConsumerState<_AccountAvatarButton> {
  @override
  void initState() {
    super.initState();
    Future.microtask(_loadIfAuthenticated);
  }

  void _loadIfAuthenticated() {
    if (!mounted) return;
    final state = ref.read(profileProvider);
    if (ref.read(sessionIdentityServiceProvider).cached == null) return;
    if (state.hasLoadedOnce || state.isLoading) return;
    unawaited(ref.read(profileProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sessionProvider, (previous, next) {
      if (next.value != null) _loadIfAuthenticated();
    });
    final displayName = ref.watch(
      profileProvider.select((s) => s.profile?.displayName),
    );
    final initials = accountInitials(displayName);
    return _StripCircle(
      semanticLabel: displayName == null ? 'Hesabım' : 'Hesabım, $displayName',
      onTap: () => context.push('/profile'),
      child: initials == null
          ? const Icon(Icons.person_outline, size: 20, color: AppColors.ink)
          : Text(
              initials,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: AppColors.muted,
              ),
            ),
    );
  }
}

/// At most two initials from a display name, upper-cased in turkish (where
/// "i" upper-cases to "İ", not "I"). Null for an absent or blank name — the
/// avatar shows its glyph rather than a guess.
///
/// Public and file-level so it can be tested directly; the widget it serves
/// is private.
String? accountInitials(String? displayName) {
  if (displayName == null) return null;
  final parts = displayName
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;
  final letters = parts.length == 1
      ? [parts.first.characters.first]
      : [parts.first.characters.first, parts.last.characters.first];
  return _upperTr(letters.join());
}

/// Dart's own `toUpperCase` is locale-independent, so it turns "irem" into
/// "Irem" — the wrong letter in the language this app is written in. The
/// two dotted/dotless pairs are mapped first; everything else follows the
/// default rule.
String _upperTr(String value) {
  return value.replaceAll('i', 'İ').replaceAll('ı', 'I').toUpperCase();
}

/// The approved design's help strip: how many cats in view are waiting,
/// stated rather than implied. Tapping it keeps the shipped filter
/// behaviour (prototype/app.js's `mapHelpFilter`) — hiding every
/// non-alerted marker, a pure client-side view over the cats already
/// fetched for this viewport.
class _HelpStrip extends StatelessWidget {
  const _HelpStrip({
    required this.count,
    required this.isOn,
    required this.onTap,
  });

  final int count;
  final bool isOn;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = '$count kedi yardım bekliyor';
    return Semantics(
      container: true,
      excludeSemantics: true,
      button: true,
      toggled: isOn,
      label: label,
      onTap: onTap,
      child: PressResponse(
        child: Material(
          color: isOn ? AppColors.help : AppColors.helpSoft,
          borderRadius: BorderRadius.circular(AppRadius.full),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.full),
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: kTapMin),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s3 + 1,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // A dot in the help colour, not an alert glyph: the strip
                  // is a count, and a warning triangle beside a number reads
                  // as the number itself being wrong.
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isOn ? AppColors.helpInk : AppColors.help,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s2 - 1),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: isOn ? AppColors.helpInk : AppColors.helpStrong,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Recentre on the user's own position (approved design artboard 01). The
/// map had no such control at all: `myLocationButtonEnabled` is off, so
/// once the camera moved there was no way back to yourself.
class _LocateButton extends StatelessWidget {
  const _LocateButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Konumuma dön',
      child: PressResponse(
        child: Material(
          color: AppColors.bgElevated,
          shape: const CircleBorder(),
          elevation: 2,
          shadowColor: const Color(0x1A2A1F1B),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: const SizedBox(
              width: kTapMin,
              height: kTapMin,
              child: Icon(Icons.my_location, size: 19, color: AppColors.ink),
            ),
          ),
        ),
      ),
    );
  }
}

/// The app's one primary action, centred at the bottom of the map
/// (approved design artboard 01). It was a bare circular fab docked in the
/// bottom bar; with the bar gone it carries its own label, which is what
/// the design asks for and what makes an unlabelled "+" over a map
/// unnecessary.
class _AddCatPill extends StatelessWidget {
  const _AddCatPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Kedi ekle',
      child: PressResponse(
        child: Material(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(AppRadius.full),
          elevation: 4,
          shadowColor: const Color(0x66A44732),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.full),
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: _addCatPillHeight),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s6 + 2,
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add, size: 19, color: AppColors.primaryInk),
                  SizedBox(width: AppSpacing.s2 + 1),
                  Text(
                    'kedi ekle',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primaryInk,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
