import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/relative_time.dart';
import '../data/cat_detail.dart';
import 'cat_detail_notifier.dart';

const _heroHeight = 280.0;

const _statusLabelsTr = {
  'seen': 'görüldü',
  'fed': 'mama verildi',
  'water_provided': 'su verildi',
};

/// Cat-detail view reached from the map's marker-preview sheet
/// (docs/product/map.md, docs/design/implementation-contract.md): an
/// edge-to-edge hero photo, a compact last-update line, and a newest-first
/// status-update timeline. Read-only — posting an update, editing the cat,
/// follow, and needs-help rendering are out of scope for issue #21.
/// Permanent trait chips are not part of the mvp surface (issue #42) —
/// behavioral observations belong in update comments instead. Matches
/// prototype/app.js's renderDetail visual hierarchy; never shows raw
/// lat/lng, and every user-facing string is Turkish.
class CatDetailScreen extends ConsumerStatefulWidget {
  const CatDetailScreen({super.key, required this.catId});

  final String catId;

  @override
  ConsumerState<CatDetailScreen> createState() => _CatDetailScreenState();
}

class _CatDetailScreenState extends ConsumerState<CatDetailScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(catDetailProvider(widget.catId).notifier).load(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(catDetailProvider(widget.catId));

    return Scaffold(backgroundColor: AppColors.bg, body: _buildBody(state));
  }

  Widget _buildBody(CatDetailState state) {
    if (state.notFound) {
      return const _MessageScreen(
        icon: Icons.search_off,
        message: 'Kedi bulunamadı',
      );
    }
    if (state.error != null) {
      return _MessageScreen(
        icon: Icons.error_outline,
        message: 'Kedi yüklenemedi',
        actionLabel: 'Tekrar dene',
        onAction: () =>
            ref.read(catDetailProvider(widget.catId).notifier).load(),
      );
    }
    if (state.isLoading && !state.hasLoadedOnce) {
      return const _MessageScreen(loading: true);
    }
    final detail = state.detail;
    if (detail == null) {
      return const _MessageScreen(loading: true);
    }
    return _CatDetailBody(detail: detail, state: state);
  }
}

class _CatDetailBody extends ConsumerWidget {
  const _CatDetailBody({required this.detail, required this.state});

  final CatDetail detail;
  final CatDetailState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _HeroPhoto(detail: detail),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s5,
            AppSpacing.s4,
            AppSpacing.s5,
            AppSpacing.s6,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (detail.activeAlert != null) ...[
                _ActiveAlertBanner(alert: detail.activeAlert!),
                const SizedBox(height: AppSpacing.s4),
              ],
              if (detail.lastUpdateAt != null) ...[
                _LastUpdateRow(time: detail.lastUpdateAt!),
                const SizedBox(height: AppSpacing.s6),
              ],
              Text(
                'Son güncellemeler',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.s2),
              if (state.updates.isEmpty)
                const _EmptyHistory()
              else ...[
                for (var i = 0; i < state.updates.length; i++)
                  _TimelineItem(
                    update: state.updates[i],
                    isLast: i == state.updates.length - 1 && !state.hasNextPage,
                  ),
                if (state.hasNextPage) ...[
                  const SizedBox(height: AppSpacing.s2),
                  _LoadMoreButton(
                    isLoading: state.isLoadingMore,
                    onPressed: () => ref
                        .read(catDetailProvider(detail.id).notifier)
                        .loadMoreUpdates(),
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _HeroPhoto extends StatelessWidget {
  const _HeroPhoto({required this.detail});

  final CatDetail detail;

  @override
  Widget build(BuildContext context) {
    final photo = detail.primaryPhoto;
    return SizedBox(
      height: _heroHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (photo == null)
            const _HeroPlaceholder()
          else
            CachedNetworkImage(
              imageUrl: photo,
              fit: BoxFit.cover,
              placeholder: (context, _) =>
                  const _HeroPlaceholder(loading: true),
              errorWidget: (context, _, _) => const _HeroPlaceholder(),
            ),
          // scrim: keeps the back button and the name/area caption readable
          // over any photo, per prototype/styles.css's .hero-photo__scrim.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x59000000),
                  Colors.transparent,
                  Colors.transparent,
                  Color(0x47000000),
                ],
                stops: [0.0, 0.26, 0.74, 1.0],
              ),
            ),
          ),
          Positioned(
            top: AppSpacing.s3,
            left: AppSpacing.s4,
            child: _BackCircleButton(onGlass: true),
          ),
          Positioned(
            left: AppSpacing.s5,
            right: AppSpacing.s5,
            bottom: AppSpacing.s4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  detail.name,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    shadows: const [
                      Shadow(color: Color(0x59000000), blurRadius: 6),
                    ],
                  ),
                ),
                if (detail.areaLabel != null) ...[
                  const SizedBox(height: 3),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.location_on,
                        size: 13,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          detail.areaLabel!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
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

/// Branded placeholder — same footprint as a real photo, never a generic
/// grey box — used both while the photo loads and when a cat has none.
class _HeroPlaceholder extends StatelessWidget {
  const _HeroPlaceholder({this.loading = false});

  final bool loading;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.primarySoft,
      child: Center(
        child: loading
            ? const CircularProgressIndicator(color: AppColors.primaryStrong)
            : const Icon(Icons.pets, size: 56, color: AppColors.primaryStrong),
      ),
    );
  }
}

class _BackCircleButton extends StatelessWidget {
  const _BackCircleButton({this.onGlass = false});

  final bool onGlass;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: onGlass ? Colors.white.withValues(alpha: 0.92) : AppColors.surface,
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => context.pop(),
        child: const SizedBox(
          width: kTapMin,
          height: kTapMin,
          child: Icon(Icons.chevron_left, color: AppColors.ink),
        ),
      ),
    );
  }
}

/// Active needs-help alert (issue #4/#23): category + expiry context in the
/// help color family, never blended with the primary accent (docs/product/
/// alerts.md) — the one place on this screen an active alert gets its loud
/// emphasis. The timeline below never repeats this treatment, active or
/// expired (see _NeedsHelpTag).
class _ActiveAlertBanner extends StatelessWidget {
  const _ActiveAlertBanner({required this.alert});

  final ActiveAlert alert;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s3,
      ),
      decoration: BoxDecoration(
        color: AppColors.helpSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.help),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 20,
            color: AppColors.help,
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  alert.categoryLabel,
                  style: const TextStyle(
                    color: AppColors.helpStrong,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  expiresInTr(alert.expiresAt),
                  style: const TextStyle(
                    color: AppColors.helpStrong,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LastUpdateRow extends StatelessWidget {
  const _LastUpdateRow({required this.time});

  final DateTime time;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s2,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.access_time,
            size: 16,
            color: AppColors.primaryStrong,
          ),
          const SizedBox(width: AppSpacing.s2),
          Text(
            'Son güncelleme: ${relativeTimeTr(time)}',
            style: const TextStyle(fontSize: 13, color: AppColors.muted),
          ),
        ],
      ),
    );
  }
}

class _StatusTag extends StatelessWidget {
  const _StatusTag({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s2,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Text(
        _statusLabelsTr[status] ?? status,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AppColors.primaryStrong,
        ),
      ),
    );
  }
}

/// A needs-help timeline entry's category tag (issue #4/#23). Deliberately
/// never uses the loud help-red styling here, active or expired — that
/// emphasis lives solely in _ActiveAlertBanner above the timeline, so it
/// isn't duplicated per history entry. An expired entry additionally never
/// gets any active-looking accent, per docs/product/alerts.md.
class _NeedsHelpTag extends StatelessWidget {
  const _NeedsHelpTag({required this.update});

  final CatUpdateEntry update;

  @override
  Widget build(BuildContext context) {
    final isActive = update.needsHelpActive ?? false;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s2,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: isActive ? AppColors.helpSoft : AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Text(
        update.needsHelpCategoryLabel ?? update.needsHelpCategory ?? '',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: isActive ? AppColors.helpStrong : AppColors.muted,
        ),
      ),
    );
  }
}

/// One update's structured statuses and free-text comment render as two
/// visually distinct elements — status tags (bold pills) vs. plain (never
/// italic) muted body text — per issue #21's requirement that the two
/// never blur together.
class _TimelineItem extends StatelessWidget {
  const _TimelineItem({required this.update, required this.isLast});

  final CatUpdateEntry update;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 20,
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 1.5,
                      margin: const EdgeInsets.only(top: 4),
                      color: AppColors.line,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: update.isNeedsHelp
                            ? _NeedsHelpTag(update: update)
                            : Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: update.statuses
                                    .map((s) => _StatusTag(status: s))
                                    .toList(),
                              ),
                      ),
                      const SizedBox(width: AppSpacing.s2),
                      Text(
                        relativeTimeTr(update.createdAt),
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.faint,
                        ),
                      ),
                    ],
                  ),
                  if (update.comment != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      update.comment!,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.muted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppSpacing.s6),
      child: Row(
        children: [
          Icon(Icons.history_toggle_off, color: AppColors.faint, size: 22),
          SizedBox(width: AppSpacing.s3),
          Text(
            'Henüz güncelleme yok',
            style: TextStyle(color: AppColors.muted),
          ),
        ],
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

/// Loading / not-found / generic-error screen — no photo hero yet, so the
/// back action gets its own small top-left circle instead of the hero's
/// on-photo one.
class _MessageScreen extends StatelessWidget {
  const _MessageScreen({
    this.icon,
    this.message,
    this.actionLabel,
    this.onAction,
    this.loading = false,
  });

  final IconData? icon;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Center(
          child: loading
              ? const CircularProgressIndicator(color: AppColors.primary)
              : Padding(
                  padding: const EdgeInsets.all(AppSpacing.s6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 40, color: AppColors.faint),
                      const SizedBox(height: AppSpacing.s3),
                      Text(
                        message ?? '',
                        style: const TextStyle(color: AppColors.muted),
                      ),
                      if (actionLabel != null && onAction != null) ...[
                        const SizedBox(height: AppSpacing.s3),
                        OutlinedButton(
                          onPressed: onAction,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.ink,
                            side: const BorderSide(color: AppColors.lineStrong),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(AppRadius.md),
                            ),
                          ),
                          child: Text(actionLabel!),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
        Positioned(
          top: MediaQuery.of(context).padding.top + AppSpacing.s3,
          left: AppSpacing.s4,
          child: const _BackCircleButton(),
        ),
      ],
    );
  }
}
