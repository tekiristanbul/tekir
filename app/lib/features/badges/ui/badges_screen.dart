import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/states/inline_spinner.dart';
import '../../../core/theme/app_theme.dart';
import '../data/badge.dart';
import 'badge_icons.dart';
import 'badges_notifier.dart';

/// Full badge list (issue #80), ported from the approved prototype's
/// `renderBadges`/`badgeRowHTML` (prototype/app.js:830-854): an
/// earned-count summary line, then each of the 5 fixed mvp badges
/// (docs/product/badges.md) with a progress bar when not yet earned.
/// Reached only via a gated entry point (ProfileScreen's "Tümünü gör"
/// link) — mirrors [NotificationsScreen]'s "assumes gated entry" note.
class BadgesScreen extends ConsumerStatefulWidget {
  const BadgesScreen({super.key});

  @override
  ConsumerState<BadgesScreen> createState() => _BadgesScreenState();
}

class _BadgesScreenState extends ConsumerState<BadgesScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(badgesProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(badgesProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: const Text('Rozetler'),
      ),
      body: SafeArea(child: _body(state)),
    );
  }

  Widget _body(BadgesState state) {
    if (state.isLoading && !state.hasLoadedOnce) {
      return const Center(
        child: InlineSpinner(
          size: 28,
          color: AppColors.primary,
          trackColor: AppColors.line,
        ),
      );
    }
    if (state.error != null && state.items.isEmpty) {
      return _ErrorRetry(
        onRetry: () => ref.read(badgesProvider.notifier).load(),
      );
    }

    final earnedCount = state.items.where((b) => b.earned).length;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.s4),
      children: [
        Text(
          earnedCount == 0
              ? 'Henüz hiç rozet kazanmadın. Aşağıdaki katkılarla ilk rozetini kazanabilirsin.'
              : '$earnedCount / ${state.items.length} rozet kazanıldı.',
          style: const TextStyle(color: AppColors.muted, fontSize: 13),
        ),
        const SizedBox(height: AppSpacing.s4),
        for (final badge in state.items) ...[
          _BadgeRow(
            badge: badge,
            onTap: () => context.push('/badges/${badge.id}'),
          ),
          const SizedBox(height: AppSpacing.s2),
        ],
      ],
    );
  }
}

class _BadgeRow extends StatelessWidget {
  const _BadgeRow({required this.badge, required this.onTap});

  final BadgeStatus badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pct = (badge.value / badge.target).clamp(0.0, 1.0);
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s3),
          child: Row(
            children: [
              // The design's `.badge-row__icon`: a 44px circle carrying the
              // earned/unearned tint, not a bare glyph next to the text.
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: badge.earned
                      ? AppColors.primarySoft
                      : AppColors.surfaceAlt,
                ),
                alignment: Alignment.center,
                child: Icon(
                  badgeIconFor(badge.icon),
                  size: 20,
                  // muted, not faint (issue #109, badge contrast): the icon
                  // carries the earned/unearned state, and faint reads at
                  // under 3:1 on this surface — below the non-text minimum.
                  color: badge.earned
                      ? AppColors.primaryStrong
                      : AppColors.muted,
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      badge.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      badge.earned
                          ? 'Kazanıldı'
                          : '${badge.value} / ${badge.target}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.muted,
                      ),
                    ),
                    if (!badge.earned) ...[
                      const SizedBox(height: AppSpacing.s2),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.full),
                        child: LinearProgressIndicator(
                          value: pct,
                          minHeight: 6,
                          backgroundColor: AppColors.surfaceAlt,
                          valueColor: const AlwaysStoppedAnimation(
                            AppColors.primary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 16, color: AppColors.faint),
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
              'Rozetler yüklenemedi',
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
