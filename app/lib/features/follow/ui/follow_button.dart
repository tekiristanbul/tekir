import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/analytics/analytics.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/ui/auth_gate.dart';
import '../../notifications/ui/notification_optin_sheet.dart';
import 'follow_state_notifier.dart';

/// Follow/unfollow toggle for a cat (issue #65). Gate-at-intent: a guest's
/// tap never mutates anything before authentication succeeds — it shows
/// [AuthGate]'s prompt sheet first, and only calls [FollowsNotifier.toggle]
/// once sign-in completes (resumed intent), exactly the mechanism issue
/// #47/#57 built and issue #65 is the first feature to actually call.
class FollowButton extends ConsumerWidget {
  const FollowButton({super.key, required this.catId, this.source});

  final String catId;

  /// Which vocabulary source the surface hosting this button was opened
  /// from — carried onto follow_created/follow_removed (issue #84); null
  /// (parameter omitted) when unknown, e.g. a direct deep link.
  final AnalyticsSource? source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFollowed = ref.watch(
      followsProvider.select((s) => s.value?.contains(catId) ?? false),
    );

    return SizedBox(
      height: kTapMin,
      child: OutlinedButton.icon(
        onPressed: () => _handleTap(context, ref),
        style: OutlinedButton.styleFrom(
          foregroundColor: isFollowed ? AppColors.primaryStrong : AppColors.ink,
          side: BorderSide(
            color: isFollowed ? AppColors.primary : AppColors.lineStrong,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
        icon: Icon(
          isFollowed ? Icons.favorite : Icons.favorite_border,
          size: 18,
        ),
        label: Text(isFollowed ? 'Takip ediliyor' : 'Takip et'),
      ),
    );
  }

  void _handleTap(BuildContext context, WidgetRef ref) {
    unawaited(
      AuthGate.require(
        context,
        ref,
        contextText: 'Bir kediyi takip etmek için giriş yap',
        intent: AnalyticsAuthIntent.follow,
        onAuthenticated: () => unawaited(_toggle(context, ref)),
      ),
    );
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref) async {
    final wasFollowing =
        ref.read(followsProvider).value?.contains(catId) ?? false;
    try {
      await ref.read(followsProvider.notifier).toggle(catId);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(followActionErrorMessageTr(e))));
      return;
    }
    // logged only after the server confirmed the change (issue #84) — a
    // failed toggle above never emits.
    ref
        .read(analyticsProvider)
        .log(
          wasFollowing
              ? AnalyticsEvent.followRemoved(source)
              : AnalyticsEvent.followCreated(source),
        );
    // Notification permission is asked only after following a cat — never
    // on unfollow, and at most once per session (issue #78,
    // docs/product/notifications.md).
    if (!wasFollowing && context.mounted) {
      await maybeShowNotificationOptInSheet(context, ref);
    }
  }
}
