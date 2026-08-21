import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/states/inline_spinner.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/relative_time.dart' show relativeTimeTr;
import '../data/badge.dart';
import 'badge_icons.dart';
import 'badges_notifier.dart';

/// One badge's detail (issue #80), ported from the approved prototype's
/// `renderBadgeDetail` (prototype/app.js:857-873): a hero (icon, name,
/// earned-date-or-progress), a progress bar when not yet earned, a "how to
/// earn" row from the badge's fixed condition text, and its flavor
/// description. Shares [badgesProvider] with [BadgesScreen] rather than
/// making its own request — a deep link straight to this screen still
/// triggers a load if the shared state is empty.
class BadgeDetailScreen extends ConsumerStatefulWidget {
  const BadgeDetailScreen({super.key, required this.badgeId});

  final String badgeId;

  @override
  ConsumerState<BadgeDetailScreen> createState() => _BadgeDetailScreenState();
}

class _BadgeDetailScreenState extends ConsumerState<BadgeDetailScreen> {
  @override
  void initState() {
    super.initState();
    final state = ref.read(badgesProvider);
    if (!state.hasLoadedOnce && !state.isLoading) {
      Future.microtask(() => ref.read(badgesProvider.notifier).load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(badgesProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: const Text('Rozet'),
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

    BadgeStatus? badge;
    for (final b in state.items) {
      if (b.id == widget.badgeId) {
        badge = b;
        break;
      }
    }
    if (badge == null) {
      return const Center(
        child: Text(
          'Rozet bulunamadı',
          style: TextStyle(color: AppColors.muted),
        ),
      );
    }

    final pct = (badge.value / badge.target).clamp(0.0, 1.0);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.s5),
      children: [
        // The design's `.badge-detail-hero`: the colored circle sits only
        // behind the icon (`.badge-detail-hero__icon`, 96px) — the hero
        // itself carries no card background of its own.
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s6),
          child: Column(
            children: [
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: badge.earned
                      ? AppColors.primarySoft
                      : AppColors.surfaceAlt,
                ),
                alignment: Alignment.center,
                child: Icon(
                  badgeIconFor(badge.icon),
                  size: 44,
                  // muted, not faint (issue #109, badge contrast): faint on
                  // surfaceAlt is ~2.4:1, below the 3:1 non-text minimum.
                  color: badge.earned
                      ? AppColors.primaryStrong
                      : AppColors.muted,
                ),
              ),
              const SizedBox(height: AppSpacing.s3),
              Text(badge.name, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: AppSpacing.s1),
              Text(
                badge.earned
                    ? '${relativeTimeTr(badge.earnedAt!)} kazanıldı'
                    : '${badge.value} / ${badge.target}',
                style: const TextStyle(color: AppColors.muted, fontSize: 13),
              ),
            ],
          ),
        ),
        if (!badge.earned) ...[
          const SizedBox(height: AppSpacing.s4),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.full),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 6,
              backgroundColor: AppColors.surfaceAlt,
              valueColor: const AlwaysStoppedAnimation(AppColors.primary),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.s5),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.emoji_events_outlined,
              size: 18,
              color: AppColors.muted,
            ),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Nasıl kazanılır',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppColors.muted,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    badge.condition,
                    style: const TextStyle(color: AppColors.ink),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.s4),
        Text(
          badge.descr,
          style: const TextStyle(
            color: AppColors.muted,
            fontSize: 13,
            height: 1.5,
          ),
        ),
      ],
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
              'Rozet yüklenemedi',
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
