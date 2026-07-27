import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/identity/session_identity.dart';
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
/// [build]/[load] reset-and-guard on the session's account id exactly like
/// [ProfileNotifier] (issue #80 product-owner review, finding 5) — see its
/// doc comment for why [build] uses `ref.listen` rather than `ref.watch`,
/// skips any transition through `AsyncLoading`, compares account ids (not
/// the whole session), why [load] reads the id off
/// [SessionIdentityService.cached] rather than [sessionProvider]'s own
/// reactive value, and why it re-checks after its await.
class DiscoverNotifier extends Notifier<DiscoverState> {
  @override
  DiscoverState build() {
    ref.listen(sessionProvider, (previous, next) {
      if (previous == null || previous.isLoading || next.isLoading) return;
      if (previous.value?.userId != next.value?.userId) {
        state = const DiscoverState();
      }
    });
    return const DiscoverState();
  }

  Future<void> load() async {
    final requestedFor = ref
        .read(sessionIdentityServiceProvider)
        .cached
        ?.userId;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final cats = await ref.read(followsApiProvider).fetchFollows();
      if (ref.read(sessionIdentityServiceProvider).cached?.userId !=
          requestedFor) {
        return;
      }
      state = DiscoverState(cats: cats, hasLoadedOnce: true);
    } catch (e) {
      if (ref.read(sessionIdentityServiceProvider).cached?.userId !=
          requestedFor) {
        return;
      }
      state = state.copyWith(isLoading: false, hasLoadedOnce: true, error: e);
    }
  }
}

final discoverProvider = NotifierProvider<DiscoverNotifier, DiscoverState>(
  DiscoverNotifier.new,
);
