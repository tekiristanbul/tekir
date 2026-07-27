import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/identity/session_identity.dart';
import '../data/notification.dart';
import '../data/notifications_api.dart';

class NotificationsState {
  const NotificationsState({
    this.items = const [],
    this.nextCursor,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasLoadedOnce = false,
    this.error,
  });

  final List<AppNotification> items;
  final String? nextCursor;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasLoadedOnce;
  final Object? error;

  bool get hasNextPage => nextCursor != null;

  NotificationsState copyWith({
    List<AppNotification>? items,
    String? nextCursor,
    bool clearNextCursor = false,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasLoadedOnce,
    Object? error,
    bool clearError = false,
  }) {
    return NotificationsState(
      items: items ?? this.items,
      nextCursor: clearNextCursor ? null : (nextCursor ?? this.nextCursor),
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasLoadedOnce: hasLoadedOnce ?? this.hasLoadedOnce,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Loads and pages the authenticated account's own notification inbox
/// (issue #78) — mirrors [CatDetailNotifier]'s load/loadMore/pagination
/// shape. A single (non-family) instance: unlike a cat detail, there is
/// exactly one inbox, the caller's own.
///
/// [build]/[load] reset-and-guard on the session's account id exactly like
/// [ProfileNotifier] (issue #80 product-owner review, finding 5) — see its
/// doc comment for why [build] uses `ref.listen` rather than `ref.watch`,
/// skips any transition through `AsyncLoading`, compares account ids (not
/// the whole session), why [load] reads the id off
/// [SessionIdentityService.cached] rather than [sessionProvider]'s own
/// reactive value, and why it re-checks after its await. [loadMore]/
/// [markRead] aren't separately guarded: both require an already-loaded,
/// non-empty inbox (`state.nextCursor`/a matching item id), and [load]'s
/// own reset already clears both back to empty the instant the account
/// changes, so neither can act on another account's data.
class NotificationsNotifier extends Notifier<NotificationsState> {
  @override
  NotificationsState build() {
    ref.listen(sessionProvider, (previous, next) {
      if (previous == null || previous.isLoading || next.isLoading) return;
      if (previous.value?.userId != next.value?.userId) {
        state = const NotificationsState();
      }
    });
    return const NotificationsState();
  }

  Future<void> load() async {
    final requestedFor = ref
        .read(sessionIdentityServiceProvider)
        .cached
        ?.userId;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final page = await ref.read(notificationsApiProvider).fetch();
      if (ref.read(sessionIdentityServiceProvider).cached?.userId !=
          requestedFor) {
        return;
      }
      state = NotificationsState(
        items: page.items,
        nextCursor: page.nextCursor,
        isLoading: false,
        hasLoadedOnce: true,
      );
    } catch (e) {
      if (ref.read(sessionIdentityServiceProvider).cached?.userId !=
          requestedFor) {
        return;
      }
      state = state.copyWith(isLoading: false, hasLoadedOnce: true, error: e);
    }
  }

  Future<void> loadMore() async {
    final cursor = state.nextCursor;
    if (cursor == null || state.isLoadingMore) return;

    state = state.copyWith(isLoadingMore: true);
    try {
      final page = await ref
          .read(notificationsApiProvider)
          .fetch(cursor: cursor);
      state = state.copyWith(
        items: [...state.items, ...page.items],
        nextCursor: page.nextCursor,
        clearNextCursor: page.nextCursor == null,
        isLoadingMore: false,
      );
    } catch (_) {
      // keep the already-loaded page; a failed "load more" isn't a reason
      // to discard what's already on screen.
      state = state.copyWith(isLoadingMore: false);
    }
  }

  /// Marks [id] read, locally and server-side. Fails open: a failed
  /// mark-read call is silently ignored rather than surfaced, since it
  /// never blocks anything else on this screen and the item will simply
  /// still show as unread next time.
  Future<void> markRead(String id) async {
    final index = state.items.indexWhere((n) => n.id == id);
    if (index == -1 || state.items[index].read) return;

    try {
      await ref.read(notificationsApiProvider).markRead(id);
    } catch (_) {
      return;
    }
    final updated = [...state.items];
    final n = updated[index];
    updated[index] = AppNotification(
      id: n.id,
      catId: n.catId,
      updateId: n.updateId,
      read: true,
      createdAt: n.createdAt,
    );
    state = state.copyWith(items: updated);
  }
}

final notificationsProvider =
    NotifierProvider<NotificationsNotifier, NotificationsState>(
      NotificationsNotifier.new,
    );
