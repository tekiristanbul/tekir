import 'package:flutter_riverpod/flutter_riverpod.dart';

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
class BadgesNotifier extends Notifier<BadgesState> {
  @override
  BadgesState build() => const BadgesState();

  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final items = await ref.read(badgesApiProvider).fetch();
      state = BadgesState(items: items, hasLoadedOnce: true);
    } catch (e) {
      state = state.copyWith(isLoading: false, hasLoadedOnce: true, error: e);
    }
  }
}

final badgesProvider = NotifierProvider<BadgesNotifier, BadgesState>(
  BadgesNotifier.new,
);
