import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../discover/ui/discover_notifier.dart';
import '../../map/ui/cats_map_notifier.dart';
import '../data/cat_detail.dart';
import '../data/cat_detail_api.dart';

class CatDetailState {
  const CatDetailState({
    this.detail,
    this.updates = const [],
    this.nextCursor,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasLoadedOnce = false,
    this.notFound = false,
    this.error,
  });

  final CatDetail? detail;
  final List<CatUpdateEntry> updates;
  final String? nextCursor;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasLoadedOnce;
  final bool notFound;
  final Object? error;

  bool get hasNextPage => nextCursor != null;

  CatDetailState copyWith({
    CatDetail? detail,
    List<CatUpdateEntry>? updates,
    String? nextCursor,
    bool clearNextCursor = false,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasLoadedOnce,
    bool? notFound,
    Object? error,
    bool clearError = false,
  }) {
    return CatDetailState(
      detail: detail ?? this.detail,
      updates: updates ?? this.updates,
      nextCursor: clearNextCursor ? null : (nextCursor ?? this.nextCursor),
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasLoadedOnce: hasLoadedOnce ?? this.hasLoadedOnce,
      notFound: notFound ?? this.notFound,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Loads a single cat's detail + first page of update history. One instance
/// per cat id (see catDetailProvider's family), matching the map-to-detail
/// navigation: a screen is always scoped to exactly one cat.
class CatDetailNotifier extends Notifier<CatDetailState> {
  CatDetailNotifier(this.catId);

  final String catId;

  @override
  CatDetailState build() => const CatDetailState();

  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true, notFound: false);

    final api = ref.read(catDetailApiProvider);
    try {
      final detail = await api.fetchDetail(catId);
      final page = await api.fetchUpdates(catId);
      state = CatDetailState(
        detail: detail,
        updates: page.items,
        nextCursor: page.nextCursor,
        isLoading: false,
        hasLoadedOnce: true,
      );
    } on CatNotFoundException {
      state = state.copyWith(
        isLoading: false,
        hasLoadedOnce: true,
        notFound: true,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, hasLoadedOnce: true, error: e);
    }
  }

  Future<void> loadMoreUpdates() async {
    final cursor = state.nextCursor;
    if (cursor == null || state.isLoadingMore) return;

    state = state.copyWith(isLoadingMore: true);
    try {
      final page = await ref
          .read(catDetailApiProvider)
          .fetchUpdates(catId, cursor: cursor);
      state = state.copyWith(
        updates: [...state.updates, ...page.items],
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

  /// Inserts a just-created update (issue #43) at the front of the
  /// newest-first timeline. Uses the server-confirmed entry from the
  /// create response directly rather than re-fetching, so the
  /// exactly-one-new-entry guarantee never races [loadMoreUpdates]. No-op
  /// if detail hasn't loaded yet — the ui only offers a way to submit once
  /// it has. Also a no-op if this id is already present, so a retried
  /// submit whose earlier attempt actually succeeded server-side can't
  /// duplicate the timeline entry.
  ///
  /// A help-carrying entry (issue #101) is always the cat's newest active
  /// state — the server just computed its expires_at 72 hours out — so it
  /// also becomes [CatDetail.activeAlert], built from the entry's own
  /// fields (the comment doubles as the note) rather than re-fetched: the
  /// same "server-confirmed entry, never optimistic" contract as the
  /// timeline insert itself.
  void prependUpdate(CatUpdateEntry entry) {
    final detail = state.detail;
    if (detail == null) return;
    if (state.updates.any((u) => u.id == entry.id)) return;
    final expiresAt = entry.needsHelpExpiresAt;
    final activeAlert = (entry.needsHelp && expiresAt != null)
        ? ActiveAlert(
            comment: entry.comment,
            createdAt: entry.createdAt,
            expiresAt: expiresAt,
          )
        : detail.activeAlert;
    state = state.copyWith(
      updates: [entry, ...state.updates],
      detail: CatDetail(
        id: detail.id,
        name: detail.name,
        lat: detail.lat,
        lng: detail.lng,
        areaLabel: detail.areaLabel,
        primaryPhoto: detail.primaryPhoto,
        createdAt: detail.createdAt,
        lastUpdateAt: entry.createdAt,
        activeAlert: activeAlert,
        mediaCount: detail.mediaCount,
        isOwner: detail.isOwner,
      ),
    );
  }

  /// Replaces a successfully corrected entry in place (issue #80), keeping
  /// its timeline position — a correction never changes created_at/author,
  /// only statuses/comment/updated_at, so re-sorting is never needed.
  /// No-op if the entry has since scrolled out of the loaded page (a
  /// vanishingly unlikely race, given the 10-minute correction window).
  void replaceUpdate(CatUpdateEntry entry) {
    final index = state.updates.indexWhere((u) => u.id == entry.id);
    if (index == -1) return;
    final updated = [...state.updates];
    updated[index] = entry;
    state = state.copyWith(updates: updated);
  }

  /// Removes a successfully deleted entry from the timeline (issue #80) —
  /// the server has already soft-deleted it, so every reader's view
  /// (including the author's own) simply never shows it again.
  void removeUpdate(String updateId) {
    state = state.copyWith(
      updates: state.updates.where((u) => u.id != updateId).toList(),
    );
  }

  /// Reconciles [CatDetail.activeAlert] after the caller removed their own
  /// help mark in-window (issue #101) — cleared via PATCH or deleted with
  /// its whole update. The cat's active state may fall back to an older
  /// still-active mark, and only the server can decide that (activeness is
  /// always its clock, never this device's), so re-fetch the detail. If
  /// the re-fetch fails, drop the alert locally when the removed mark was
  /// its source (matched by created_at): a stale "yardıma ihtiyacı var"
  /// banner is worse than briefly missing a fallback alert, and the next
  /// full load corrects either way.
  Future<void> reconcileAfterHelpRemoval(DateTime removedMarkCreatedAt) async {
    if (state.detail == null) return;
    try {
      final fresh = await ref.read(catDetailApiProvider).fetchDetail(catId);
      state = state.copyWith(detail: fresh);
    } catch (_) {
      final detail = state.detail;
      final alert = detail?.activeAlert;
      if (detail == null || alert == null) return;
      if (!alert.createdAt.isAtSameMomentAs(removedMarkCreatedAt)) return;
      state = state.copyWith(
        detail: CatDetail(
          id: detail.id,
          name: detail.name,
          lat: detail.lat,
          lng: detail.lng,
          areaLabel: detail.areaLabel,
          primaryPhoto: detail.primaryPhoto,
          createdAt: detail.createdAt,
          lastUpdateAt: detail.lastUpdateAt,
          activeAlert: null,
          mediaCount: detail.mediaCount,
          isOwner: detail.isOwner,
        ),
      );
    }
  }

  /// Promotes an existing media-archive entry to the cat's cover photo
  /// (issue #156) — only the cat's own owner can call this successfully;
  /// the server re-checks ownership regardless of what the client believes.
  /// Replaces [CatDetailState.detail] with the server-refreshed detail
  /// (its own primary_photo/is_owner) and invalidates [catMediaProvider] so
  /// the media grid's "ana" badge moves to the newly-promoted entry on next
  /// build, rather than staying stale until some unrelated refetch.
  Future<void> setCoverPhoto(String mediaId) async {
    final updated = await ref
        .read(catDetailApiProvider)
        .setCoverPhoto(catId, mediaId);
    state = state.copyWith(detail: updated);
    ref.invalidate(catMediaProvider(catId));
  }

  /// Renames the cat (issue #227) — a recovery path for a naming mistake
  /// made at creation time. Only the cat's own owner ever sees the
  /// affordance that calls this; the server re-checks ownership regardless
  /// of what the client believes. Replaces [CatDetailState.detail] with the
  /// server-refreshed detail (its own name) and patches the same name into
  /// [catsMapProvider]/[discoverProvider] in place (issue #230) — unlike
  /// [catMediaProvider] above, those two providers' `build()` fetches
  /// nothing, so invalidating them would discard whatever the map/discover
  /// screens already had loaded instead of refreshing it.
  Future<void> renameCat(String name) async {
    final updated = await ref.read(catDetailApiProvider).renameCat(catId, name);
    state = state.copyWith(detail: updated);
    ref.read(catsMapProvider.notifier).renameCat(catId, name);
    ref.read(discoverProvider.notifier).renameCat(catId, name);
  }
}

final catDetailProvider =
    NotifierProvider.family<CatDetailNotifier, CatDetailState, String>(
      CatDetailNotifier.new,
    );

/// Backs the cat-profile "medya" tab (issue #121's media-archive parity
/// gap): one lazily-fetched, cached-per-cat list — the archive has no
/// pagination or optimistic-mutation contract of its own, so a plain
/// [FutureProvider] is enough, unlike [catDetailProvider]'s hand-rolled
/// notifier for the timeline.
final catMediaProvider = FutureProvider.family<List<CatMediaItem>, String>((
  ref,
  catId,
) {
  return ref.watch(catDetailApiProvider).fetchMedia(catId);
});
