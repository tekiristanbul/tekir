import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  /// it has.
  void prependUpdate(CatUpdateEntry entry) {
    final detail = state.detail;
    if (detail == null) return;
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
        activeAlert: detail.activeAlert,
      ),
    );
  }
}

final catDetailProvider =
    NotifierProvider.family<CatDetailNotifier, CatDetailState, String>(
      CatDetailNotifier.new,
    );
