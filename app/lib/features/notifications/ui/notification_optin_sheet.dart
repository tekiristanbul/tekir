import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/push/push_notifications.dart';
import '../../../core/theme/app_theme.dart';

/// Whether the notification opt-in prompt has already been shown this app
/// session — mirrors the approved prototype's `state.notifPermAsked`
/// (prototype/app.js:930-932): asked once, ever, per session, never on
/// every follow. "asked" deliberately lives only in memory — it resets on
/// a cold app start, which is the only place
/// [maybeShowNotificationOptInSheet] can be called again without an
/// explicit "reset" action, keeping this a local-only, no invented
/// persistence prompt. Under `NOTIFICATION_PROVIDER=fcm` the system
/// permission state is the durable truth anyway: once granted (or
/// permanently denied), re-showing this sheet costs one tap at most.
class _NotificationOptInAskedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void markAsked() => state = true;
}

final notificationOptInAskedProvider =
    NotifierProvider<_NotificationOptInAskedNotifier, bool>(
      _NotificationOptInAskedNotifier.new,
    );

/// Shows the notification opt-in prompt at most once per app session, and
/// only when [FollowButton] calls this after a cat was just followed —
/// per docs/product/notifications.md, permission is asked only after
/// following, never at first launch and never on unfollow or any other
/// action. This sheet is the *approved opt-in point* (issue #84): "İzin
/// ver" is the only place the real system notification permission is ever
/// requested — and only under `NOTIFICATION_PROVIDER=fcm`; under the local
/// `fake` default [PushNotificationsService] is disabled and both choices
/// remain local ui state, exactly the pre-#84 behavior.
Future<void> maybeShowNotificationOptInSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  if (ref.read(notificationOptInAskedProvider)) return;
  ref.read(notificationOptInAskedProvider.notifier).markAsked();

  await showModalBottomSheet<void>(
    context: context,
    builder: (_) => const _NotificationOptInSheet(),
  );
}

class _NotificationOptInSheet extends ConsumerWidget {
  const _NotificationOptInSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s5,
        AppSpacing.s6,
        AppSpacing.s5,
        AppSpacing.s6,
      ),
      decoration: const BoxDecoration(
        color: AppColors.bgElevated,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              margin: const EdgeInsets.only(bottom: AppSpacing.s3),
              decoration: const BoxDecoration(
                color: AppColors.primarySoft,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.notifications_outlined,
                size: 22,
                color: AppColors.primaryStrong,
              ),
            ),
            Text(
              'Bu kedi için bildirim almak ister misin?',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.s2),
            const Text(
              'Sadece aktif bir yardım bildirimi olduğunda haber veririz. Sık bildirim göndermeyiz.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.muted),
            ),
            const SizedBox(height: AppSpacing.s5),
            SizedBox(
              height: kTapMin,
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  // fire-and-forget: the sheet closes immediately; the
                  // system permission dialog (fcm only) takes over from
                  // here, and registration failures are silently retried
                  // on later app starts (PushNotificationsService.start).
                  ref
                      .read(pushNotificationsServiceProvider)
                      .requestPermissionAndRegister();
                  Navigator.of(context).pop();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.primaryInk,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
                child: const Text('İzin ver'),
              ),
            ),
            const SizedBox(height: AppSpacing.s2),
            SizedBox(
              height: kTapMin,
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Şimdi değil'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
