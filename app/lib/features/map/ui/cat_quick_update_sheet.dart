import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/analytics/analytics.dart';
import '../../../core/images/decode_budget.dart';
import '../../../core/motion/hero_tags.dart';
import '../../../core/motion/press_response.dart';
import '../../../core/motion/tekir_motion.dart';
import '../../../core/states/inline_spinner.dart';
import '../../../core/states/submitting_button.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/distance_format.dart';
import '../../../core/utils/relative_time.dart';
import '../../auth/ui/auth_gate.dart';
import '../../cat_detail/ui/cat_update_composer_notifier.dart';
import '../data/cat_marker.dart';

/// The sheet a tapped cat opens (issue #286, approved design artboard 02).
///
/// It replaces a preview that showed a photo, a name and a button to go
/// somewhere else. The common act on this map is standing next to a cat and
/// recording that you fed it, and that used to cost a marker tap, this
/// sheet, a navigation, a second sheet and a scroll. Now it is two taps
/// without leaving the map.
///
/// Everything the sheet writes goes through [CatUpdateComposerNotifier] —
/// the same composer the cat-detail screen uses, with the same idempotency
/// guarantees, the same failure copy and the same optimistic row. An update
/// recorded here is the same update recorded there, in the same history.
///
/// Content comes entirely from the already-fetched [CatMarker]; opening this
/// triggers no network read.
class CatQuickUpdateSheet extends ConsumerStatefulWidget {
  const CatQuickUpdateSheet({
    super.key,
    required this.cat,
    required this.distanceMeters,
    required this.onOpenDetail,
  });

  final CatMarker cat;

  /// How far the cat is from the user, or null when no real position is
  /// known — a distance measured from the istanbul fallback would read as
  /// "distance from you" and be wrong.
  final double? distanceMeters;

  final VoidCallback onOpenDetail;

  @override
  ConsumerState<CatQuickUpdateSheet> createState() =>
      _CatQuickUpdateSheetState();
}

class _CatQuickUpdateSheetState extends ConsumerState<CatQuickUpdateSheet> {
  @override
  void initState() {
    super.initState();
    // A sheet opened for a different cat, or reopened for this one, starts
    // from an empty draft rather than inheriting whatever was toggled last
    // time.
    Future.microtask(() {
      if (mounted) {
        ref.read(catUpdateComposerProvider(widget.cat.id).notifier).reset();
      }
    });
  }

  Future<void> _save() async {
    final catId = widget.cat.id;
    await AuthGate.require(
      context,
      ref,
      contextText: 'Update eklemek için giriş yap',
      // The same bounded intent the cat-detail composer reports: this is
      // an ordinary update, recorded from a different surface.
      intent: AnalyticsAuthIntent.ordinaryUpdate,
      onAuthenticated: () async {
        final saved = await ref
            .read(catUpdateComposerProvider(catId).notifier)
            .submit();
        if (!saved || !mounted) return;
        // The sheet's whole job is done in one tap; staying open would
        // leave a form nobody is filling in over a map nobody can see.
        Navigator.of(context).pop();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cat = widget.cat;
    final composer = ref.watch(catUpdateComposerProvider(cat.id));
    final selectionCount =
        composer.selectedStatuses.length + (composer.needsHelp ? 1 : 0);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bgElevated,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      padding: EdgeInsets.only(
        left: AppSpacing.s5,
        right: AppSpacing.s5,
        top: AppSpacing.s2,
        bottom: AppSpacing.s5 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _GrabHandle(),
          _IdentityRow(
            cat: cat,
            distanceMeters: widget.distanceMeters,
            onClose: () => Navigator.of(context).pop(),
          ),
          if (cat.activeAlert != null) ...[
            const SizedBox(height: AppSpacing.s3),
            _HelpRow(alert: cat.activeAlert!),
          ],
          const SizedBox(height: AppSpacing.s4),
          _QuickToggles(
            selectedStatuses: composer.selectedStatuses,
            needsHelp: composer.needsHelp,
            enabled: !composer.isSubmitting,
            onToggleStatus: (status) => ref
                .read(catUpdateComposerProvider(cat.id).notifier)
                .toggleStatus(status),
            onToggleHelp: () => ref
                .read(catUpdateComposerProvider(cat.id).notifier)
                .toggleNeedsHelp(),
          ),
          const SizedBox(height: AppSpacing.s3),
          SubmittingButton(
            label: selectionCount == 0
                ? '+ update ekle'
                : '+ update ekle · $selectionCount',
            submittingLabel: 'kaydediliyor',
            submitting: composer.isSubmitting,
            // Nothing selected is nothing to save: the design's own rule,
            // and the same one the composer's validation already enforces.
            onPressed: selectionCount == 0 ? null : () => unawaited(_save()),
          ),
          if (composer.error != null) ...[
            const SizedBox(height: AppSpacing.s2),
            Semantics(
              liveRegion: true,
              child: Text(
                updateSubmitErrorMessageTr(composer.error!),
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.helpStrong,
                ),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.s3),
          _DetailLink(onTap: widget.onOpenDetail),
        ],
      ),
    );
  }
}

class _GrabHandle extends StatelessWidget {
  const _GrabHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 38,
        height: 4,
        margin: const EdgeInsets.only(bottom: AppSpacing.s3),
        decoration: BoxDecoration(
          color: AppColors.lineStrong,
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
      ),
    );
  }
}

class _IdentityRow extends StatelessWidget {
  const _IdentityRow({
    required this.cat,
    required this.distanceMeters,
    required this.onClose,
  });

  final CatMarker cat;
  final double? distanceMeters;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // The photo is the shared element the cat-detail header picks up
        // (core/motion/hero_tags.dart): tapping through does not dismiss
        // this sheet and open an unrelated screen, it carries this cat's
        // photo across.
        Hero(
          tag: catPhotoHeroTag(cat.id),
          // Arc rather than straight-line travel: the photo moves up and
          // across at the same time, and a curved path reads as one
          // continuous motion where a diagonal reads as a slide.
          createRectTween: (begin, end) =>
              MaterialRectCenterArcTween(begin: begin, end: end),
          child: _SheetPhoto(url: cat.primaryPhoto),
        ),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                cat.name.isNotEmpty ? cat.name : 'İsimsiz kedi',
                style: Theme.of(
                  context,
                ).textTheme.headlineSmall?.copyWith(fontSize: 26, height: 1.05),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              _ContextLine(
                areaLabel: cat.areaLabel,
                distanceMeters: distanceMeters,
                lastUpdateAt: cat.lastUpdateAt,
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.s2),
        Semantics(
          button: true,
          label: 'kapat',
          child: PressResponse(
            child: InkResponse(
              onTap: onClose,
              radius: 24,
              child: const SizedBox(
                width: kTapMin,
                height: kTapMin,
                child: Center(
                  child: Text(
                    'kapat',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.faint,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The design's carer line, built only from what the map's own read already
/// carries. A count of the neighbours looking after this cat is not one of
/// those things and is not invented here (issue #286, out of scope).
class _ContextLine extends StatelessWidget {
  const _ContextLine({
    required this.areaLabel,
    required this.distanceMeters,
    required this.lastUpdateAt,
  });

  final String? areaLabel;
  final double? distanceMeters;
  final DateTime? lastUpdateAt;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      ?areaLabel,
      if (distanceMeters != null) formatDistanceTr(distanceMeters!),
      if (lastUpdateAt != null) relativeTimeTr(lastUpdateAt!),
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(
      parts.join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: AppColors.faint,
      ),
    );
  }
}

/// The active help mark and how long it has left.
///
/// Help is a notification with an expiry, not a state with a resolve
/// button — there is deliberately nothing to press here. The window is the
/// product's own 72 hours, read off the server-computed expiry, never
/// recomputed from a client clock.
class _HelpRow extends StatelessWidget {
  const _HelpRow({required this.alert});

  final ActiveAlert alert;

  @override
  Widget build(BuildContext context) {
    final note = alert.comment?.trim();
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3 + 1,
        vertical: AppSpacing.s3,
      ),
      decoration: BoxDecoration(
        color: AppColors.helpSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.priority_high, size: 15, color: AppColors.help),
              const SizedBox(width: AppSpacing.s2 - 2),
              const Expanded(
                child: Text(
                  'yardım gerekiyor',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.helpStrong,
                  ),
                ),
              ),
              Text(
                expiresInTr(alert.expiresAt),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: AppColors.help,
                ),
              ),
            ],
          ),
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              note,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                height: 1.45,
                color: AppColors.helpStrong,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The four toggles, multi-select, mapping onto the shipped status
/// vocabulary and the single help flag. One save writes one update carrying
/// whatever is selected — they are not four separate actions.
class _QuickToggles extends StatelessWidget {
  const _QuickToggles({
    required this.selectedStatuses,
    required this.needsHelp,
    required this.enabled,
    required this.onToggleStatus,
    required this.onToggleHelp,
  });

  final Set<String> selectedStatuses;
  final bool needsHelp;
  final bool enabled;
  final ValueChanged<String> onToggleStatus;
  final VoidCallback onToggleHelp;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _Toggle(
            icon: Icons.visibility_outlined,
            label: 'gördüm',
            isOn: selectedStatuses.contains('seen'),
            enabled: enabled,
            onTap: () => onToggleStatus('seen'),
          ),
        ),
        const SizedBox(width: AppSpacing.s1 + 2),
        Expanded(
          child: _Toggle(
            icon: Icons.set_meal_outlined,
            label: 'mama',
            isOn: selectedStatuses.contains('fed'),
            enabled: enabled,
            onTap: () => onToggleStatus('fed'),
          ),
        ),
        const SizedBox(width: AppSpacing.s1 + 2),
        Expanded(
          child: _Toggle(
            icon: Icons.water_drop_outlined,
            label: 'su',
            isOn: selectedStatuses.contains('water_provided'),
            enabled: enabled,
            onTap: () => onToggleStatus('water_provided'),
          ),
        ),
        const SizedBox(width: AppSpacing.s1 + 2),
        Expanded(
          child: _Toggle(
            icon: Icons.priority_high,
            label: 'yardım',
            isOn: needsHelp,
            enabled: enabled,
            isHelp: true,
            onTap: onToggleHelp,
          ),
        ),
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.icon,
    required this.label,
    required this.isOn,
    required this.enabled,
    required this.onTap,
    this.isHelp = false,
  });

  final IconData icon;
  final String label;
  final bool isOn;
  final bool enabled;
  final bool isHelp;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final motion = TekirMotion.of(context);
    final onColor = isHelp ? AppColors.help : AppColors.primary;
    final background = isOn ? onColor : AppColors.surfaceAlt;
    final foreground = isOn
        ? AppColors.primaryInk
        : (isHelp ? AppColors.helpStrong : AppColors.muted);
    return Semantics(
      container: true,
      excludeSemantics: true,
      button: true,
      toggled: isOn,
      enabled: enabled,
      label: label,
      onTap: enabled ? onTap : null,
      child: PressResponse(
        enabled: enabled,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.full),
            onTap: enabled ? onTap : null,
            child: AnimatedContainer(
              duration: motion(TekirMotion.state),
              curve: TekirMotion.enter,
              constraints: const BoxConstraints(minHeight: kTapMin),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(AppRadius.full),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // A tick replaces the icon when the toggle is on, so the
                  // selected state is carried by a shape as well as by the
                  // fill — a fill alone is exactly the colour-only signal
                  // the app has removed everywhere else.
                  Icon(isOn ? Icons.check : icon, size: 14, color: foreground),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: foreground,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The way through to everything this sheet deliberately does not do:
/// history, media, a photo on an update, a comment.
class _DetailLink extends StatelessWidget {
  const _DetailLink({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      excludeSemantics: true,
      button: true,
      label: 'kedi detayına git, geçmiş, medya, fotoğraflı update',
      onTap: onTap,
      child: PressResponse(
        child: Material(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.md),
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: kTapMin),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s4 - 1,
                vertical: AppSpacing.s2,
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'kedi detayına git',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: AppColors.ink,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'geçmiş · medya · fotoğraflı update',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.faint,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: AppColors.primary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetPhoto extends StatelessWidget {
  const _SheetPhoto({required this.url});

  static const _size = 56.0;

  final String url;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(18);
    if (url.isEmpty) {
      return ClipRRect(borderRadius: radius, child: const _PhotoPlaceholder());
    }
    return ClipRRect(
      borderRadius: radius,
      child: CachedNetworkImage(
        imageUrl: url,
        width: _size,
        height: _size,
        fit: BoxFit.cover,
        memCacheWidth: decodeWidthFor(context, _size),
        placeholder: (context, _) => const SizedBox(
          width: _size,
          height: _size,
          child: Center(
            child: InlineSpinner(
              size: 18,
              color: AppColors.primary,
              trackColor: AppColors.line,
            ),
          ),
        ),
        errorWidget: (context, _, _) => const _PhotoPlaceholder(),
      ),
    );
  }
}

class _PhotoPlaceholder extends StatelessWidget {
  const _PhotoPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _SheetPhoto._size,
      height: _SheetPhoto._size,
      color: AppColors.primarySoft,
      child: const Icon(Icons.pets, size: 24, color: AppColors.primaryStrong),
    );
  }
}
