import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/identity/session_identity.dart';
import '../data/follows_api.dart';

/// Turkish, actionable copy for a failed follow/unfollow attempt — mirrors
/// updateSubmitErrorMessageTr's convention (cat_update_composer_notifier).
String followActionErrorMessageTr(Object error) {
  return switch (error) {
    FollowUnauthorizedException() => 'Kimlik doğrulanamadı, tekrar dene.',
    FollowCatNotFoundException() => 'Bu kedi artık bulunamıyor.',
    FollowNetworkException() => 'Bağlantı sorunu, tekrar dene.',
    _ => 'Sunucuya ulaşılamadı, birazdan tekrar dene.',
  };
}

/// The authenticated account's followed cat ids (issue #65: following is
/// private per-account state — docs/product/community.md). [build] re-runs
/// automatically whenever [sessionProvider]'s state changes (Riverpod's
/// standard watch-triggers-rebuild behavior), so logging in loads the
/// account's follows, logging out clears them back to empty, and switching
/// accounts replaces one set with the other — a guest never has a
/// client-side follows cache at all.
class FollowsNotifier extends AsyncNotifier<Set<String>> {
  @override
  Future<Set<String>> build() async {
    final session = ref.watch(sessionProvider).value;
    if (session == null) return const {};
    try {
      final cats = await ref.read(followsApiProvider).fetchFollows();
      return cats.map((c) => c.id).toSet();
    } catch (_) {
      // Follow state is supplementary, not core content — fail open to an
      // empty set rather than surfacing an error state on every screen that
      // merely checks "is this cat followed by me".
      return const {};
    }
  }

  /// Follows or unfollows [catId] depending on its current state. Calls the
  /// api first and only updates local state on success (no optimistic
  /// persistence, matching cat_update_composer_notifier's convention);
  /// rethrows the mapped [FollowsApi] exception on failure so the caller
  /// (e.g. a follow button) can surface [followActionErrorMessageTr].
  Future<void> toggle(String catId) async {
    final current = state.value ?? const <String>{};
    final api = ref.read(followsApiProvider);
    if (current.contains(catId)) {
      await api.unfollow(catId);
      state = AsyncData({...current}..remove(catId));
    } else {
      await api.follow(catId);
      state = AsyncData({...current, catId});
    }
  }
}

final followsProvider = AsyncNotifierProvider<FollowsNotifier, Set<String>>(
  FollowsNotifier.new,
);
