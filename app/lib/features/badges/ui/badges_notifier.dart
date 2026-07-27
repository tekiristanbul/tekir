import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/identity/session_identity.dart';
import '../data/badge.dart';
import '../data/badges_api.dart';

class BadgesState {
  const BadgesState({
    this.items = const [],
    this.isLoading = false,
    this.hasLoadedOnce = false,
    this.error,
  });

  final List<BadgeStatus> items;
  final bool isLoading;
  final bool hasLoadedOnce;
  final Object? error;

  BadgesState copyWith({
    List<BadgeStatus>? items,
    bool? isLoading,
    bool? hasLoadedOnce,
    Object? error,
    bool clearError = false,
  }) {
    return BadgesState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      hasLoadedOnce: hasLoadedOnce ?? this.hasLoadedOnce,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Loads the authenticated account's own badge progress (issue #80) — a
/// fixed 5-item list, never paginated, mirroring [AccountNotifier]'s plain
/// load shape rather than [NotificationsNotifier]'s cursor-paged one.
///
/// [build]/[load] reset-and-guard on the session's account id exactly like
/// [ProfileNotifier] (issue #80 product-owner review, finding 5) — see its
/// doc comment for why [build] uses `ref.listen` rather than `ref.watch`,
/// skips any transition through `AsyncLoading`, compares account ids (not
/// the whole session), why [load] reads the id off
/// [SessionIdentityService.cached] rather than [sessionProvider]'s own
/// reactive value, and why it re-checks after its await.
class BadgesNotifier extends Notifier<BadgesState> {
  @override
  BadgesState build() {
    ref.listen(sessionProvider, (previous, next) {
      if (previous == null || previous.isLoading || next.isLoading) return;
      if (previous.value?.userId != next.value?.userId) {
        state = const BadgesState();
      }
    });
    return const BadgesState();
  }

  Future<void> load() async {
    final requestedFor = ref
        .read(sessionIdentityServiceProvider)
        .cached
        ?.userId;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final items = await ref.read(badgesApiProvider).fetch();
      if (ref.read(sessionIdentityServiceProvider).cached?.userId !=
          requestedFor) {
        return;
      }
      state = BadgesState(items: items, hasLoadedOnce: true);
    } catch (e) {
      if (ref.read(sessionIdentityServiceProvider).cached?.userId !=
          requestedFor) {
        return;
      }
      state = state.copyWith(isLoading: false, hasLoadedOnce: true, error: e);
    }
  }
}

final badgesProvider = NotifierProvider<BadgesNotifier, BadgesState>(
  BadgesNotifier.new,
);
