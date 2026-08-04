import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/identity/session_identity.dart';
import '../../follow/data/follows_api.dart';
import '../../map/data/cat_marker.dart';

/// Calendar-day distance between [seenAt] and [now] (0 = today). Clock
/// skew that puts [seenAt] in the future clamps to today rather than
/// inventing a negative age.
int quietDayDaysAgo(DateTime seenAt, DateTime now) {
  final local = seenAt.toLocal();
  final days = DateTime(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime(local.year, local.month, local.day)).inDays;
  return days < 0 ? 0 : days;
}

/// State 09's per-row freshness copy (docs/design/app-states.md).
String quietDayFreshnessTr(DateTime seenAt, DateTime now) {
  return switch (quietDayDaysAgo(seenAt, now)) {
    0 => 'bugün görüldü',
    1 => 'dün görüldü',
    final n => '$n gün önce',
  };
}

/// The "son N günde" window of the banner sub-line: the smallest day count
/// covering every followed cat's last sighting. Null when the sub-line
/// must drop — no follows, or any cat without a real `last_update_at`.
/// The value is always derived, never approximated (contract gap 9).
int? quietDayWindowDays(List<CatMarker> cats, DateTime now) {
  if (cats.isEmpty) return null;
  var maxDaysAgo = 0;
  for (final cat in cats) {
    final seenAt = cat.lastUpdateAt;
    if (seenAt == null) return null;
    final days = quietDayDaysAgo(seenAt, now);
    if (days > maxDaysAgo) maxDaysAgo = days;
  }
  return maxDaysAgo + 1;
}

enum QuietDayStatus { initial, loading, loaded, unavailable }

/// State 09 · sakin gün's data: the account's followed cats from
/// `GET /v1/me/follows`, fetched only when the notifications screen's
/// empty state actually renders. [QuietDayStatus.unavailable] drops the
/// banner sub-line and the list entirely — a count-free banner, never a
/// derived or invented value.
class QuietDayState {
  const QuietDayState({
    this.status = QuietDayStatus.initial,
    this.cats = const [],
  });

  final QuietDayStatus status;
  final List<CatMarker> cats;

  /// Whether any followed cat still has an active help call — then the
  /// quiet-day banner would be false and must not render.
  bool get hasActiveHelp => cats.any((c) => c.needsHelp);
}

/// Mirrors [NotificationsNotifier]'s session reset-and-guard convention:
/// follows are account-owned, so the state resets the instant the account
/// id changes and a stale in-flight response can never land on the next
/// account's screen.
class QuietDayNotifier extends Notifier<QuietDayState> {
  @override
  QuietDayState build() {
    ref.listen(sessionProvider, (previous, next) {
      if (previous == null || previous.isLoading || next.isLoading) return;
      if (previous.value?.userId != next.value?.userId) {
        state = const QuietDayState();
      }
    });
    return const QuietDayState();
  }

  Future<void> load() async {
    if (state.status == QuietDayStatus.loading ||
        state.status == QuietDayStatus.loaded) {
      return;
    }
    final requestedFor = ref
        .read(sessionIdentityServiceProvider)
        .cached
        ?.userId;
    state = const QuietDayState(status: QuietDayStatus.loading);
    try {
      final cats = await ref.read(followsApiProvider).fetchFollows();
      if (ref.read(sessionIdentityServiceProvider).cached?.userId !=
          requestedFor) {
        return;
      }
      state = QuietDayState(status: QuietDayStatus.loaded, cats: cats);
    } catch (_) {
      if (ref.read(sessionIdentityServiceProvider).cached?.userId !=
          requestedFor) {
        return;
      }
      state = const QuietDayState(status: QuietDayStatus.unavailable);
    }
  }
}

final quietDayProvider = NotifierProvider<QuietDayNotifier, QuietDayState>(
  QuietDayNotifier.new,
);
