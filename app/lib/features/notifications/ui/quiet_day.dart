import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/analytics/analytics.dart';
import '../../../core/theme/app_theme.dart';
import '../../map/data/cat_marker.dart';
import 'quiet_day_notifier.dart';

// State 09's olive palette (docs/design/screens/app-states.html) — good
// news deliberately gets its own hue, never the help palette.
const _oliveBg = Color(0xFFEAEFE1);
const _oliveDisc = Color(0xFFDBE4CC);
const _oliveStroke = Color(0xFF5B6F42);
const _oliveInk = Color(0xFF3F5230);
const _oliveText = Color(0xFF6B7D55);
const _oliveDot = Color(0xFF7B9A52);
const _mustardDot = Color(0xFFC9A227);

/// State 09 · sakin gün (docs/design/app-states.md): the notifications
/// screen with no active help call — emptiness as good news. An olive
/// banner, and beneath it the account's followed cats with day-level
/// freshness from `GET /v1/me/follows`. The banner sub-line and the list
/// render only from real data; if the source is unavailable the sub-line
/// drops entirely. If a followed cat still has an active help call the
/// banner would be false, so the previous neutral empty state renders
/// instead.
class QuietDayBody extends ConsumerStatefulWidget {
  const QuietDayBody({super.key});

  @override
  ConsumerState<QuietDayBody> createState() => _QuietDayBodyState();
}

class _QuietDayBodyState extends ConsumerState<QuietDayBody> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(quietDayProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(quietDayProvider);
    if (state.hasActiveHelp) return const _NeutralEmpty();

    final now = DateTime.now();
    final loaded = state.status == QuietDayStatus.loaded;
    final windowDays = loaded ? quietDayWindowDays(state.cats, now) : null;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.s4),
      children: [
        _QuietBanner(
          subLine: windowDays == null
              ? null
              : 'takip ettiğin ${state.cats.length} kedi de '
                    'son $windowDays günde görüldü.',
        ),
        if (loaded && state.cats.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.s1,
              AppSpacing.s5,
              AppSpacing.s1,
              AppSpacing.s3,
            ),
            child: _SectionLabel('takip ettiklerin'),
          ),
          for (final cat in state.cats)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s3),
              child: _FollowedCatRow(cat: cat, now: now),
            ),
        ],
      ],
    );
  }
}

class _QuietBanner extends StatelessWidget {
  const _QuietBanner({required this.subLine});

  /// Null drops the second line entirely (contract gap 9): count-free
  /// banner, never an approximated value.
  final String? subLine;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4 + 2),
      decoration: BoxDecoration(
        color: _oliveBg,
        borderRadius: BorderRadius.circular(AppRadius.lg + 2),
      ),
      child: Row(
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              color: _oliveDisc,
              shape: BoxShape.circle,
            ),
            child: SizedBox(
              width: kTapMin,
              height: kTapMin,
              child: Icon(Icons.check_rounded, size: 22, color: _oliveStroke),
            ),
          ),
          const SizedBox(width: AppSpacing.s3 + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'aktif yardım çağrısı yok',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontSize: 18,
                    color: _oliveInk,
                  ),
                ),
                if (subLine != null) ...[
                  const SizedBox(height: AppSpacing.s1),
                  Text(
                    subLine!,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: _oliveText,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          text,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
            color: AppColors.faint,
          ),
        ),
        const SizedBox(width: AppSpacing.s2 + 2),
        const Expanded(child: Divider(height: 1, color: AppColors.line)),
      ],
    );
  }
}

class _FollowedCatRow extends StatelessWidget {
  const _FollowedCatRow({required this.cat, required this.now});

  final CatMarker cat;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final seenAt = cat.lastUpdateAt;
    return Material(
      color: AppColors.surfaceAlt,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: () => context.push(
          '/cats/${cat.id}',
          extra: AnalyticsSource.notification,
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s3),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.md + 1),
                child: SizedBox(
                  width: 54,
                  height: 54,
                  child: cat.primaryPhoto.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: cat.primaryPhoto,
                          fit: BoxFit.cover,
                          placeholder: (_, _) =>
                              const ColoredBox(color: AppColors.surfaceAlt),
                          errorWidget: (_, _, _) => const ColoredBox(
                            color: AppColors.line,
                            child: Icon(Icons.pets, color: AppColors.faint),
                          ),
                        )
                      : const ColoredBox(
                          color: AppColors.line,
                          child: Icon(Icons.pets, color: AppColors.faint),
                        ),
                ),
              ),
              const SizedBox(width: AppSpacing.s3 + 1),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cat.name.isNotEmpty ? cat.name : 'İsimsiz kedi',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.titleMedium?.copyWith(fontSize: 18),
                    ),
                    // A cat without a real last_update_at gets no freshness
                    // line at all — never an approximated one.
                    if (seenAt != null) ...[
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: quietDayDaysAgo(seenAt, now) >= 2
                                  ? _mustardDot
                                  : _oliveDot,
                              shape: BoxShape.circle,
                            ),
                            child: const SizedBox(width: 6, height: 6),
                          ),
                          const SizedBox(width: AppSpacing.s2 - 2),
                          Text(
                            quietDayFreshnessTr(seenAt, now),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppColors.faint,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              const Icon(Icons.chevron_right, size: 16, color: AppColors.faint),
            ],
          ),
        ),
      ),
    );
  }
}

/// The pre-contract neutral empty state, kept for the one case the
/// quiet-day banner would be untrue: a followed cat still has an active
/// help call while the inbox happens to be empty.
class _NeutralEmpty extends StatelessWidget {
  const _NeutralEmpty();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.notifications_none, size: 40, color: AppColors.faint),
            SizedBox(height: AppSpacing.s3),
            Text(
              'Henüz bildirimin yok',
              style: TextStyle(color: AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}
