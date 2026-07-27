import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../follow/data/follows_api.dart';
import '../../map/data/cat_marker.dart';

class DiscoverState {
  const DiscoverState({
    this.cats = const [],
    this.isLoading = false,
    this.hasLoadedOnce = false,
    this.error,
  });

  final List<CatMarker> cats;
  final bool isLoading;
  final bool hasLoadedOnce;
  final Object? error;

  DiscoverState copyWith({
    List<CatMarker>? cats,
    bool? isLoading,
    bool? hasLoadedOnce,
    Object? error,
    bool clearError = false,
  }) {
    return DiscoverState(
      cats: cats ?? this.cats,
      isLoading: isLoading ?? this.isLoading,
      hasLoadedOnce: hasLoadedOnce ?? this.hasLoadedOnce,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Keşfet's minimal mvp content (issue #80 product-owner review, finding 2):
/// just the authenticated account's own followed cats, reusing
/// `GET /v1/me/follows` via the existing [FollowsApi] rather than a bespoke
/// endpoint — the full discover scope (nearby/needs-help/all-by-distance) is
/// deliberately out of scope here and tracked as a separate follow-up issue.
///
/// Mirrors [ProfileNotifier]'s plain load()-triggered-by-the-screen shape
/// for now, not [FollowsNotifier]'s own build()-time session watch — the
/// account-scoped reset-on-session-change this state also needs (issue #80
/// product-owner review, finding 5) lands together with profile/badges/
/// notifications' own equivalent fix, so all four get the same race-safe
/// treatment in one pass rather than this one alone risking a build() vs.
/// explicit load() race.
class DiscoverNotifier extends Notifier<DiscoverState> {
  @override
  DiscoverState build() => const DiscoverState();

  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final cats = await ref.read(followsApiProvider).fetchFollows();
      state = DiscoverState(cats: cats, hasLoadedOnce: true);
    } catch (e) {
      state = state.copyWith(isLoading: false, hasLoadedOnce: true, error: e);
    }
  }
}

final discoverProvider = NotifierProvider<DiscoverNotifier, DiscoverState>(
  DiscoverNotifier.new,
);
