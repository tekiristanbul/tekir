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
  /// Follows this account changed in this session, by cat id, kept until
  /// the session ends.
  ///
  /// A read that was already in flight when the user toggled a follow
  /// answers from a moment before that toggle existed, and letting it land
  /// unmerged would silently undo what the user just did — visible in the
  /// resumed-intent path, where signing in starts a fetch and the follow
  /// it resumes lands after that fetch was issued but before it returns.
  /// A local decision is newer than any read that predates it, so it wins
  /// the merge. Entries are dropped only when the mutation fails, or when
  /// the account changes and the whole map stops applying.
  final _decidedLocally = <String, bool>{};

  /// The newest [toggle] still in flight for each cat id.
  ///
  /// Two taps on the same heart produce two requests whose completion
  /// order is not the tap order, and only the newest tap is the user's
  /// actual intent. Without this ticket an older request failing would
  /// revert to *its* idea of "before" — undoing the newer tap, and
  /// deleting the newer tap's entry from [_decidedLocally] on the way out,
  /// so the ui ended up disagreeing with the server for the rest of the
  /// session. A superseded attempt now cleans up nothing and reverts
  /// nothing; it still throws, because it genuinely failed.
  final _latestAttempt = <String, int>{};
  int _attempts = 0;

  @override
  Future<Set<String>> build() async {
    final session = ref.watch(sessionProvider).value;
    if (session == null) {
      // A guest has no follows cache, and the next account must not inherit
      // the previous one's local decisions.
      _decidedLocally.clear();
      _latestAttempt.clear();
      return const {};
    }
    try {
      final cats = await ref.read(followsApiProvider).fetchFollows();
      return _merge(cats.map((c) => c.id).toSet());
    } catch (_) {
      // Follow state is supplementary, not core content — fail open to an
      // empty set rather than surfacing an error state on every screen that
      // merely checks "is this cat followed by me".
      return _merge(const {});
    }
  }

  Set<String> _merge(Set<String> remote) {
    if (_decidedLocally.isEmpty) return remote;
    final merged = {...remote};
    _decidedLocally.forEach((catId, followed) {
      if (followed) {
        merged.add(catId);
      } else {
        merged.remove(catId);
      }
    });
    return merged;
  }

  /// Follows or unfollows [catId] depending on its current state.
  ///
  /// Optimistic: local state flips in the same frame as the tap, and the
  /// request runs behind it — the binding rule for every user-triggered
  /// mutation (docs/design/app-states.md: "user-triggered mutations get
  /// same-frame feedback", the 400 ms read delay never applies to them).
  /// This used to await the api first, which left the heart visibly dead
  /// for a whole round trip on a slow connection.
  ///
  /// A failure reverts this cat alone rather than restoring the whole set,
  /// so a concurrent toggle on a different cat is never undone as a side
  /// effect, then rethrows the mapped [FollowsApi] exception so the caller
  /// (e.g. a follow button) can surface [followActionErrorMessageTr].
  ///
  /// A failure that has already been superseded by a newer tap on the same
  /// cat reverts nothing at all — see [_latestAttempt]. It still throws:
  /// that request did fail, and the caller decides what to say about it.
  Future<void> toggle(String catId) async {
    final current = state.value ?? const <String>{};
    final wasFollowing = current.contains(catId);
    final attempt = ++_attempts;
    _latestAttempt[catId] = attempt;
    _decidedLocally[catId] = !wasFollowing;
    state = AsyncData(
      wasFollowing ? ({...current}..remove(catId)) : {...current, catId},
    );

    final api = ref.read(followsApiProvider);
    try {
      if (wasFollowing) {
        await api.unfollow(catId);
      } else {
        await api.follow(catId);
      }
    } catch (_) {
      if (_latestAttempt[catId] == attempt) {
        _latestAttempt.remove(catId);
        _decidedLocally.remove(catId);
        final latest = state.value ?? const <String>{};
        state = AsyncData(
          wasFollowing ? {...latest, catId} : ({...latest}..remove(catId)),
        );
      }
      rethrow;
    }
    if (_latestAttempt[catId] == attempt) _latestAttempt.remove(catId);
  }
}

final followsProvider = AsyncNotifierProvider<FollowsNotifier, Set<String>>(
  FollowsNotifier.new,
);
