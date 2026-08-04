import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/analytics/analytics.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/relative_time.dart';
import '../data/notification.dart';
import 'notifications_notifier.dart';
import 'quiet_day.dart';

/// The authenticated account's own notification inbox (issue #78): a
/// newest-first list of "a followed cat's needs-help update", each
/// tappable through to that cat's detail. Reached only via `AuthGate`'s
/// gated entry point (map_screen's bell icon) — this screen assumes a
/// session already exists and does not itself gate or redirect.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(notificationsProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(notificationsProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: const Text('Bildirimler'),
      ),
      body: SafeArea(child: _body(state)),
    );
  }

  Widget _body(NotificationsState state) {
    if (state.isLoading && !state.hasLoadedOnce) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.items.isEmpty) {
      return _ErrorRetry(
        onRetry: () => ref.read(notificationsProvider.notifier).load(),
      );
    }
    if (state.items.isEmpty) {
      return const QuietDayBody();
    }
    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.s4),
      itemCount: state.items.length + (state.hasNextPage ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.s2),
      itemBuilder: (context, index) {
        if (index >= state.items.length) {
          return _LoadMoreButton(
            isLoading: state.isLoadingMore,
            onPressed: () =>
                ref.read(notificationsProvider.notifier).loadMore(),
          );
        }
        final item = state.items[index];
        return _NotificationTile(
          notification: item,
          onTap: () {
            ref.read(notificationsProvider.notifier).markRead(item.id);
            context.push(
              '/cats/${item.catId}',
              extra: AnalyticsSource.notification,
            );
          },
        );
      },
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.notification, required this.onTap});

  final AppNotification notification;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: notification.read ? AppColors.surface : AppColors.helpSoft,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s3),
          child: Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 20,
                color: notification.read ? AppColors.muted : AppColors.help,
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Takip ettiğin bir kedi için yardım bildirimi',
                      style: TextStyle(
                        fontWeight: notification.read
                            ? FontWeight.w500
                            : FontWeight.w700,
                        color: AppColors.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      relativeTimeTr(notification.createdAt),
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.faint,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.faint),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: AppColors.faint),
            const SizedBox(height: AppSpacing.s3),
            const Text(
              'Bildirimler yüklenemedi',
              style: TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: AppSpacing.s3),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.ink,
                side: const BorderSide(color: AppColors.lineStrong),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
              ),
              child: const Text('Tekrar dene'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadMoreButton extends StatelessWidget {
  const _LoadMoreButton({required this.isLoading, required this.onPressed});

  final bool isLoading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: kTapMin,
      child: OutlinedButton(
        onPressed: isLoading ? null : onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: AppColors.surface,
          foregroundColor: AppColors.ink,
          side: const BorderSide(color: AppColors.lineStrong),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
        ),
        child: isLoading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text(
                'Daha fazla göster',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
      ),
    );
  }
}
