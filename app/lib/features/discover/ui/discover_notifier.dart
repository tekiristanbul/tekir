import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/analytics/analytics.dart';
import '../../../core/identity/session_identity.dart';
import '../../follow/data/follows_api.dart';
import '../../map/data/cat_marker.dart';
import '../data/discover_api.dart';
import '../data/discover_cat.dart';
import '../data/discover_location_service.dart';

/// The keşfet screen's three mvp surfaces (docs/product/discovery.md,
/// issue #82): every active cat by distance, only those with an active
/// needs-help alert, and the account's own followed cats. Matches the
/// approved prototype's segmented control (prototype/app.js:707-749)
/// exactly — `nearby`/`needsHelp` are public and location-aware; `following`
/// is private, account-owned state.
enum DiscoverTab { nearby, needsHelp, following }

/// One of the two location-aware tabs' state: which page of
/// [DiscoverCat]s has loaded so far, and — since a location-aware tab can
/// fail in more ways than a plain network call — the last resolved (or
/// failed) [DiscoverLocationOutcome], so the screen can show a state that
/// actually explains what's wrong (permission denied vs. service disabled
/// vs. a plain server error) rather than one generic error block.
class DiscoverLocationTabState {
  const DiscoverLocationTabState({
    this.locationOutcome,
    this.cats = const [],
    this.nextCursor,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasLoadedOnce = false,
    this.error,
  });

  final DiscoverLocationOutcome? locationOutcome;
  final List<DiscoverCat> cats;
  final String? nextCursor;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasLoadedOnce;
  final Object? error;

  bool get hasMore => nextCursor != null;

  DiscoverLocationTabState copyWith({
    DiscoverLocationOutcome? locationOutcome,
    List<DiscoverCat>? cats,
    String? nextCursor,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasLoadedOnce,
    Object? error,
    bool clearError = false,
    bool clearCursor = false,
  }) {
    return DiscoverLocationTabState(
      locationOutcome: locationOutcome ?? this.locationOutcome,
      cats: cats ?? this.cats,
      nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasLoadedOnce: hasLoadedOnce ?? this.hasLoadedOnce,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// The following tab's state — unchanged in shape from this screen's
/// original minimal-mvp slice (issue #80 product-owner review), just
/// nested under [DiscoverState.following] now that the screen has two more
/// tabs alongside it.
class DiscoverFollowingTabState {
  const DiscoverFollowingTabState({
    this.cats = const [],
    this.isLoading = false,
    this.hasLoadedOnce = false,
    this.error,
  });

  final List<CatMarker> cats;
  final bool isLoading;
  final bool hasLoadedOnce;
  final Object? error;

  DiscoverFollowingTabState copyWith({
    List<CatMarker>? cats,
    bool? isLoading,
    bool? hasLoadedOnce,
    Object? error,
    bool clearError = false,
  }) {
    return DiscoverFollowingTabState(
      cats: cats ?? this.cats,
      isLoading: isLoading ?? this.isLoading,
      hasLoadedOnce: hasLoadedOnce ?? this.hasLoadedOnce,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class DiscoverState {
  const DiscoverState({
    this.selectedTab = DiscoverTab.nearby,
    this.nearby = const DiscoverLocationTabState(),
    this.needsHelp = const DiscoverLocationTabState(),
    this.following = const DiscoverFollowingTabState(),
  });

  final DiscoverTab selectedTab;
  final DiscoverLocationTabState nearby;
  final DiscoverLocationTabState needsHelp;
  final DiscoverFollowingTabState following;

  DiscoverState copyWith({
    DiscoverTab? selectedTab,
    DiscoverLocationTabState? nearby,
    DiscoverLocationTabState? needsHelp,
    DiscoverFollowingTabState? following,
  }) {
    return DiscoverState(
      selectedTab: selectedTab ?? this.selectedTab,
      nearby: nearby ?? this.nearby,
      needsHelp: needsHelp ?? this.needsHelp,
      following: following ?? this.following,
    );
  }
}

/// Drives all three of keşfet's tabs. `nearby`/`needsHelp` request location
/// lazily — only the first time their own tab is actually selected — and
/// are never reset by an account/session change (they're public, guest data
/// with no per-account leakage risk); `following` keeps its existing
/// session-scoped reset-and-guard behavior (issue #80 product-owner
/// review) unchanged, so logging out or switching accounts can never leak
/// one account's followed cats into another's view.
class DiscoverNotifier extends Notifier<DiscoverState> {
  @override
  DiscoverState build() {
    ref.listen(sessionProvider, (previous, next) {
      if (previous == null || previous.isLoading || next.isLoading) return;
      if (previous.value?.userId != next.value?.userId) {
        state = state.copyWith(following: const DiscoverFollowingTabState());
      }
    });
    return const DiscoverState();
  }

  void selectTab(DiscoverTab tab) {
    if (tab != state.selectedTab) {
      ref
          .read(analyticsProvider)
          .log(
            AnalyticsEvent.discoverViewSelected(switch (tab) {
              DiscoverTab.nearby => AnalyticsDiscoverView.nearby,
              DiscoverTab.needsHelp => AnalyticsDiscoverView.needsHelp,
              DiscoverTab.following => AnalyticsDiscoverView.following,
            }),
          );
    }
    state = state.copyWith(selectedTab: tab);
  }

  Future<void> ensureNearbyLoaded() async {
    if (state.nearby.hasLoadedOnce || state.nearby.isLoading) return;
    await _loadLocationTab(DiscoverFilter.nearby);
  }

  Future<void> ensureNeedsHelpLoaded() async {
    if (state.needsHelp.hasLoadedOnce || state.needsHelp.isLoading) return;
    await _loadLocationTab(DiscoverFilter.needsHelp);
  }

  Future<void> retryNearby() => _loadLocationTab(DiscoverFilter.nearby);

  Future<void> retryNeedsHelp() => _loadLocationTab(DiscoverFilter.needsHelp);

  Future<void> loadMoreNearby() => _loadMoreLocationTab(DiscoverFilter.nearby);

  Future<void> loadMoreNeedsHelp() =>
      _loadMoreLocationTab(DiscoverFilter.needsHelp);

  DiscoverLocationTabState _tabFor(DiscoverFilter filter) =>
      filter == DiscoverFilter.nearby ? state.nearby : state.needsHelp;

  void _setTab(DiscoverFilter filter, DiscoverLocationTabState next) {
    state = filter == DiscoverFilter.nearby
        ? state.copyWith(nearby: next)
        : state.copyWith(needsHelp: next);
  }

  Future<void> _loadLocationTab(DiscoverFilter filter) async {
    _setTab(
      filter,
      _tabFor(filter).copyWith(isLoading: true, clearError: true),
    );

    final outcome = await ref.read(discoverLocationServiceProvider).resolve();
    // location_permission_result (issue #84): the bounded outcome of this
    // resolve — never the position itself; coordinates are never part of
    // any analytics event.
    ref
        .read(analyticsProvider)
        .log(
          AnalyticsEvent.locationPermissionResult(switch (outcome) {
            DiscoverLocationResolved() => AnalyticsResult.success,
            DiscoverLocationPermissionDenied() ||
            DiscoverLocationPermissionDeniedForever() =>
              AnalyticsResult.permissionDenied,
            DiscoverLocationServiceDisabled() ||
            DiscoverLocationUnavailable() => AnalyticsResult.offline,
          }),
        );
    if (outcome is! DiscoverLocationResolved) {
      _setTab(
        filter,
        _tabFor(filter).copyWith(
          isLoading: false,
          hasLoadedOnce: true,
          locationOutcome: outcome,
          cats: const [],
          clearCursor: true,
        ),
      );
      return;
    }

    try {
      final page = await ref
          .read(discoverApiProvider)
          .fetch(filter: filter, lat: outcome.lat, lng: outcome.lng);
      _setTab(
        filter,
        DiscoverLocationTabState(
          locationOutcome: outcome,
          cats: page.items,
          nextCursor: page.nextCursor,
          hasLoadedOnce: true,
        ),
      );
    } catch (e) {
      _setTab(
        filter,
        _tabFor(filter).copyWith(
          isLoading: false,
          hasLoadedOnce: true,
          locationOutcome: outcome,
          error: e,
        ),
      );
    }
  }

  Future<void> _loadMoreLocationTab(DiscoverFilter filter) async {
    final current = _tabFor(filter);
    final outcome = current.locationOutcome;
    if (current.isLoadingMore ||
        !current.hasMore ||
        outcome is! DiscoverLocationResolved) {
      return;
    }

    _setTab(filter, current.copyWith(isLoadingMore: true, clearError: true));
    try {
      final page = await ref
          .read(discoverApiProvider)
          .fetch(
            filter: filter,
            lat: outcome.lat,
            lng: outcome.lng,
            cursor: current.nextCursor,
          );
      final latest = _tabFor(filter);
      _setTab(
        filter,
        latest.copyWith(
          isLoadingMore: false,
          cats: [...latest.cats, ...page.items],
          nextCursor: page.nextCursor,
          clearCursor: page.nextCursor == null,
        ),
      );
    } catch (e) {
      _setTab(filter, _tabFor(filter).copyWith(isLoadingMore: false, error: e));
    }
  }

  Future<void> loadFollowing() async {
    final requestedFor = ref
        .read(sessionIdentityServiceProvider)
        .cached
        ?.userId;
    state = state.copyWith(
      following: state.following.copyWith(isLoading: true, clearError: true),
    );
    try {
      final cats = await ref.read(followsApiProvider).fetchFollows();
      if (ref.read(sessionIdentityServiceProvider).cached?.userId !=
          requestedFor) {
        return;
      }
      state = state.copyWith(
        following: DiscoverFollowingTabState(cats: cats, hasLoadedOnce: true),
      );
    } catch (e) {
      if (ref.read(sessionIdentityServiceProvider).cached?.userId !=
          requestedFor) {
        return;
      }
      state = state.copyWith(
        following: state.following.copyWith(
          isLoading: false,
          hasLoadedOnce: true,
          error: e,
        ),
      );
    }
  }

  /// Patches [catId]'s name in place across all three tabs (issue #230) —
  /// [build]'s empty state fetches nothing, so invalidating this provider
  /// after a rename (as issue #227 originally did) discarded whatever tab
  /// data was already loaded instead of refreshing it. A no-op wherever
  /// [catId] isn't currently loaded.
  void renameCat(String catId, String name) {
    DiscoverLocationTabState patch(DiscoverLocationTabState tab) =>
        tab.copyWith(
          cats: [
            for (final cat in tab.cats)
              cat.id == catId ? cat.copyWith(name: name) : cat,
          ],
        );

    state = state.copyWith(
      nearby: patch(state.nearby),
      needsHelp: patch(state.needsHelp),
      following: state.following.copyWith(
        cats: [
          for (final cat in state.following.cats)
            cat.id == catId ? cat.copyWith(name: name) : cat,
        ],
      ),
    );
  }

  /// Drops [catId] from every tab's already-loaded list in place (issue
  /// #228's delete flow) — never invalidate/re-fetch, since this
  /// notifier's own build() fetches nothing: invalidating would empty
  /// nearby/needsHelp/following instead of updating them (the #230 defect
  /// the delete flow deliberately avoids repeating). No-op when the cat
  /// isn't present in any of the three tabs.
  void removeCat(String catId) {
    final nextNearby = state.nearby.cats.any((c) => c.id == catId)
        ? state.nearby.copyWith(
            cats: state.nearby.cats.where((c) => c.id != catId).toList(),
          )
        : state.nearby;
    final nextNeedsHelp = state.needsHelp.cats.any((c) => c.id == catId)
        ? state.needsHelp.copyWith(
            cats: state.needsHelp.cats.where((c) => c.id != catId).toList(),
          )
        : state.needsHelp;
    final nextFollowing = state.following.cats.any((c) => c.id == catId)
        ? state.following.copyWith(
            cats: state.following.cats.where((c) => c.id != catId).toList(),
          )
        : state.following;
    if (identical(nextNearby, state.nearby) &&
        identical(nextNeedsHelp, state.needsHelp) &&
        identical(nextFollowing, state.following)) {
      return;
    }
    state = state.copyWith(
      nearby: nextNearby,
      needsHelp: nextNeedsHelp,
      following: nextFollowing,
    );
  }
}

final discoverProvider = NotifierProvider<DiscoverNotifier, DiscoverState>(
  DiscoverNotifier.new,
);
