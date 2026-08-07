import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../../../core/analytics/analytics.dart';
import '../../../core/states/inline_spinner.dart';
import '../../../core/states/optimistic_inline_row.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/relative_time.dart';
import '../../auth/ui/auth_gate.dart';
import '../../follow/ui/follow_button.dart';
import '../data/cat_detail.dart';
import 'cat_detail_notifier.dart';
import 'cat_update_composer_notifier.dart';
import 'cat_update_sheet.dart';
import 'update_correction_sheet.dart';

const _statusLabelsTr = {
  'seen': 'görüldü',
  'fed': 'mama verildi',
  'water_provided': 'su verildi',
};

/// Cat-detail view reached from the map's marker-preview sheet
/// (docs/product/map.md, docs/design/implementation-contract.md): an
/// edge-to-edge 16:9 cover photo (tappable for an uncropped full-screen
/// view), a compact last-update line, a follow toggle, and a newest-first
/// status-update timeline. The screen has exactly one primary action —
/// the "+ update" bar opening the composition sheet — per the binding
/// design (docs/design/screens/cat-profile.html): "gördüm" is an option
/// inside that sheet, never a competing button on the screen itself.
/// The sheet also carries the single `yardıma ihtiyacı var` mark since
/// issue #102, per the #100 simplified help contract. Following the cat
/// (issue #65) is in scope; editing the cat remains out of scope. Every contribution
/// action is gated at the point of intent via [AuthGate] — a guest never
/// sees the composer or mutates follow state before signing in.
/// Permanent trait chips are not part of the mvp surface (issue #42) —
/// behavioral observations belong in update comments instead. Matches
/// prototype/app.js's renderDetail visual hierarchy; never shows raw
/// lat/lng, and every user-facing string is Turkish.
class CatDetailScreen extends ConsumerStatefulWidget {
  const CatDetailScreen({super.key, required this.catId, this.openSource});

  final String catId;

  /// Which vocabulary surface this detail was opened from (issue #84's
  /// cat_opened source). Null — no cat_opened event at all — for openings
  /// outside the vocabulary (deep link, post-creation navigation).
  final AnalyticsSource? openSource;

  @override
  ConsumerState<CatDetailScreen> createState() => _CatDetailScreenState();
}

class _CatDetailScreenState extends ConsumerState<CatDetailScreen> {
  @override
  void initState() {
    super.initState();
    final source = widget.openSource;
    if (source != null) {
      ref.read(analyticsProvider).log(AnalyticsEvent.catOpened(source));
    }
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
    return _CatDetailBody(
      detail: detail,
      state: state,
      openSource: widget.openSource,
    );
  }
}

class _CatDetailBody extends ConsumerWidget {
  const _CatDetailBody({
    required this.detail,
    required this.state,
    this.openSource,
  });

  final CatDetail detail;
  final CatDetailState state;
  final AnalyticsSource? openSource;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The optimistic timeline row (docs/design/app-states.md, mutation
    // affordances): an ordinary submission from either entry point drops
    // in here in the same frame as the tap, and on failure flips to the
    // help palette without ever disappearing.
    final pending = ref.watch(
      catUpdateComposerProvider(detail.id).select((s) => s.pending),
    );
    // A background submission's failure cause still surfaces once, as the
    // same snackbar the one-tap path always used — the row itself only
    // says "kaydedilemedi". Help failures never carry a pending row; the
    // sheet shows their error inline itself.
    ref.listen(catUpdateComposerProvider(detail.id), (previous, next) {
      final failedNow =
          previous?.pending?.status == InlineSaveStatus.saving &&
          next.pending?.status == InlineSaveStatus.failed;
      final error = next.error;
      if (!failedNow || error == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(updateSubmitErrorMessageTr(error))),
      );
    });
    return Stack(
      children: [
        _buildScroll(context, ref, pending),
        // The binding design's fixed action bar: the screen's single
        // primary action floats over the scroll on a gradient into the
        // background, so it is reachable from any scroll position.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _UpdateBar(catId: detail.id),
        ),
      ],
    );
  }

  Widget _buildScroll(
    BuildContext context,
    WidgetRef ref,
    PendingUpdate? pending,
  ) {
    // Clearance for the fixed "+ update" bar, derived from its actual
    // layout rather than a constant: the device's bottom safe-area inset,
    // the bar's own vertical padding, and the button's minimum height —
    // scaled with the text scaler, since the single-line label grows the
    // button beyond kTapMin at large system text.
    final barClearance =
        MediaQuery.paddingOf(context).bottom +
        AppSpacing.s3 +
        AppSpacing.s5 +
        math.max(kTapMin, MediaQuery.textScalerOf(context).scale(kTapMin));
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _HeroPhoto(detail: detail, openSource: openSource),
        _IdentityBlock(detail: detail),
        Padding(
          // The extra bottom padding keeps the last timeline entry
          // scrollable clear of the fixed "+ update" bar.
          padding: EdgeInsets.fromLTRB(
            AppSpacing.s5,
            AppSpacing.s4,
            AppSpacing.s5,
            AppSpacing.s6 + barClearance,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (detail.activeAlert != null) ...[
                _ActiveAlertBanner(alert: detail.activeAlert!),
                const SizedBox(height: AppSpacing.s4),
              ],
              _ThreeStatHeader(detail: detail),
              const SizedBox(height: AppSpacing.s4),
              _HistoryMediaSection(
                catId: detail.id,
                mediaCount: detail.mediaCount,
                isOwner: detail.isOwner,
                updates: state.updates,
                pending: pending,
                hasNextPage: state.hasNextPage,
                isLoadingMore: state.isLoadingMore,
                onLoadMore: () => ref
                    .read(catDetailProvider(detail.id).notifier)
                    .loadMoreUpdates(),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The cover photo (binding design docs/design/screens/cat-profile.html):
/// full width at a fixed 16:9, controlled crop (`cover`) — the ratio is
/// never distorted and the height never depends on the source image.
/// Tapping it opens the uncropped full-screen view; the design marks
/// tappability with a media counter (camera icon + count), backed since
/// issue #121 by [CatDetail.mediaCount] — the field the design's own
/// bottom-right pill previously had no real source for. The name/area
/// caption lives below the photo (see [_IdentityBlock]), not overlaid on
/// it — only the back, follow glass controls, and the counter pill sit on
/// the photo itself, matching the design's frames A/B.
class _HeroPhoto extends StatelessWidget {
  const _HeroPhoto({required this.detail, this.openSource});

  final CatDetail detail;
  final AnalyticsSource? openSource;

  @override
  Widget build(BuildContext context) {
    final photo = detail.primaryPhoto;
    return AspectRatio(
      aspectRatio: 16 / 9,
      // The detector wraps the whole cover so the tap target isn't blocked
      // by the scrim overlay; the back/follow buttons' own InkWells still
      // win their area of the stack.
      child: GestureDetector(
        onTap: photo == null ? null : () => _openFullScreen(context, photo),
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
            // scrim: keeps the back/follow glass controls readable over any
            // photo — top-only now that the caption has moved below.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x47000000), Colors.transparent],
                  stops: [0.0, 0.4],
                ),
              ),
            ),
            Positioned(
              // The cover sits at the very top of the scroll, with no app
              // bar above it — without the safe-area offset these glass
              // controls sit under the status bar/notch instead of below
              // it (issue #137), unlike every other back action on this
              // screen (_MessageScreen, _FullScreenPhoto).
              top: MediaQuery.of(context).padding.top + AppSpacing.s3,
              left: AppSpacing.s4,
              child: _BackCircleButton(onGlass: true),
            ),
            Positioned(
              top: MediaQuery.of(context).padding.top + AppSpacing.s3,
              right: AppSpacing.s4,
              child: FollowButton(
                catId: detail.id,
                source: openSource,
                glass: true,
              ),
            ),
            if (detail.mediaCount > 0)
              Positioned(
                right: AppSpacing.s3,
                bottom: AppSpacing.s2,
                child: _CoverPhotoCounter(count: detail.mediaCount),
              ),
          ],
        ),
      ),
    );
  }

  /// The full-screen view (binding design, frame D): dark surface, the
  /// photo `contain`ed with no crop, a single close action. "ana fotoğraf
  /// yap" (issue #156) belongs to the media archive grid's own tiles,
  /// which carry a media id this cover photo string alone doesn't — so
  /// the cover's own view still carries no action but closing.
  void _openFullScreen(BuildContext context, String photo) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _FullScreenPhoto(photo: photo),
      ),
    );
  }
}

/// The cover's bottom-right "tappable for more" indicator (binding design):
/// a camera glyph plus [count], the cat's [CatDetail.mediaCount] — never
/// shown at zero, since a zero pill would only advertise an archive with
/// nothing in it.
class _CoverPhotoCounter extends StatelessWidget {
  const _CoverPhotoCounter({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.camera_alt_outlined, size: 13, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// The cat's name and area, below the cover on the screen's own background
/// (binding design's "kimlik" block) rather than overlaid on the photo.
/// The design pairs this with a "N komşu bakıyor" follower-count line, but
/// that count has no backing field yet (docs/design/screens/cat-profile.html's
/// own recorded "açık kalan" item) — so only the placement moves here, the
/// count is not invented.
class _IdentityBlock extends StatelessWidget {
  const _IdentityBlock({required this.detail});

  final CatDetail detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s5,
        AppSpacing.s4,
        AppSpacing.s5,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(detail.name, style: Theme.of(context).textTheme.headlineSmall),
          if (detail.areaLabel != null) ...[
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.location_on, size: 13, color: AppColors.faint),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    detail.areaLabel!,
                    style: const TextStyle(
                      color: AppColors.faint,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The uncropped full-screen photo view (binding design frame D). `catId`/
/// `mediaId` are non-null only when opened from the media archive grid by
/// the cat's own owner (issue #156) — that's the one case that renders the
/// "ana fotoğraf yap" (make cover photo) action; the cover's own view and a
/// timeline thumbnail's both open this with those null, carrying no action
/// but closing, exactly as before.
class _FullScreenPhoto extends ConsumerStatefulWidget {
  const _FullScreenPhoto({
    required this.photo,
    this.catId,
    this.mediaId,
    this.isCover = false,
  });

  final String photo;
  final String? catId;
  final String? mediaId;
  final bool isCover;

  @override
  ConsumerState<_FullScreenPhoto> createState() => _FullScreenPhotoState();
}

class _FullScreenPhotoState extends ConsumerState<_FullScreenPhoto> {
  bool _submitting = false;

  Future<void> _setAsCover() async {
    final catId = widget.catId;
    final mediaId = widget.mediaId;
    if (catId == null || mediaId == null || widget.isCover || _submitting) {
      return;
    }
    setState(() => _submitting = true);
    try {
      await ref.read(catDetailProvider(catId).notifier).setCoverPhoto(mediaId);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kapak fotoğrafı değiştirilemedi')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final showCoverAction = widget.catId != null && widget.mediaId != null;
    return Scaffold(
      backgroundColor: const Color(0xFF141010),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: CachedNetworkImage(
              imageUrl: widget.photo,
              fit: BoxFit.contain,
              placeholder: (context, _) => const InlineSpinner(
                size: 28,
                color: AppColors.primarySoft,
                trackColor: Color(0x33FFFFFF),
              ),
              errorWidget: (context, _, _) => const Icon(
                Icons.pets,
                size: 56,
                color: AppColors.primarySoft,
              ),
            ),
          ),
          Positioned(
            top: AppSpacing.s3,
            left: AppSpacing.s4,
            child: SafeArea(
              child: Material(
                color: Colors.white.withValues(alpha: 0.14),
                shape: const CircleBorder(),
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: 'Kapat',
                  icon: const Icon(Icons.close, color: Colors.white),
                  constraints: const BoxConstraints(
                    minWidth: kTapMin,
                    minHeight: kTapMin,
                  ),
                ),
              ),
            ),
          ),
          if (showCoverAction)
            Positioned(
              left: AppSpacing.s4,
              right: AppSpacing.s4,
              bottom: AppSpacing.s5,
              child: SafeArea(
                top: false,
                child: _SetCoverButton(
                  isCover: widget.isCover,
                  isSubmitting: _submitting,
                  onPressed: _setAsCover,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The full-screen view's "ana fotoğraf yap" button (design frame D):
/// active until the shown photo is already the cover, at which point it
/// reads "ana fotoğraf" and goes passive — mirrors the design's own note
/// that an already-cover entry shows a disabled button, not a hidden one,
/// so the owner can tell at a glance which photo is currently the cover.
class _SetCoverButton extends StatelessWidget {
  const _SetCoverButton({
    required this.isCover,
    required this.isSubmitting,
    required this.onPressed,
  });

  final bool isCover;
  final bool isSubmitting;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final disabled = isCover || isSubmitting;
    return Material(
      color: disabled
          ? AppColors.primary.withValues(alpha: 0.5)
          : AppColors.primary,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: disabled ? null : onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kTapMin),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s4,
              vertical: AppSpacing.s3,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isSubmitting)
                  const InlineSpinner(
                    size: 17,
                    color: AppColors.primaryInk,
                    trackColor: Color(0x33FFFFFF),
                  )
                else
                  const Icon(
                    Icons.photo_outlined,
                    size: 17,
                    color: AppColors.primaryInk,
                  ),
                const SizedBox(width: 9),
                Text(
                  isCover ? 'ana fotoğraf' : 'ana fotoğraf yap',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primaryInk,
                  ),
                ),
              ],
            ),
          ),
        ),
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
            ? const InlineSpinner(
                size: 28,
                color: AppColors.primaryStrong,
                trackColor: AppColors.line,
              )
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
        onTap: () {
          // add-cat's success path (and a duplicate-candidate "bu zaten var"
          // pick) lands here via context.go, which replaces the whole stack
          // instead of pushing — so there is nothing to pop in that case.
          // Fall back to the map, the app's root destination.
          if (context.canPop()) {
            context.pop();
          } else {
            context.go('/');
          }
        },
        child: const SizedBox(
          width: kTapMin,
          height: kTapMin,
          child: Icon(Icons.chevron_left, color: AppColors.ink),
        ),
      ),
    );
  }
}

/// The active `yardıma ihtiyacı var` state (issue #4/#23; reshaped by the
/// #100 simplified help contract): one fixed title, the reporter's
/// optional note, and expiry context in the help color family, never
/// blended with the primary accent (docs/product/alerts.md) — the one
/// place on this screen an active state gets its loud emphasis. The
/// timeline below never repeats this treatment, active or expired (see
/// _NeedsHelpTag). Legacy help categories are never rendered here in any
/// form.
class _ActiveAlertBanner extends StatelessWidget {
  const _ActiveAlertBanner({required this.alert});

  final ActiveAlert alert;

  @override
  Widget build(BuildContext context) {
    final note = alert.comment;
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
                const Text(
                  'Yardıma ihtiyacı var',
                  style: TextStyle(
                    color: AppColors.helpStrong,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                if (note != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    note,
                    style: const TextStyle(
                      color: AppColors.helpStrong,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ],
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

/// The "üç soru şeridi" (three-stat header, binding design
/// docs/design/screens/cat-profile.html): one tile per structured status —
/// görüldü/mama/su — each showing that status's own most recent update
/// time, independent of the others. Replaces the old single generic
/// last-update pill, which conflated all three questions into one figure
/// (issue #121's "counters" parity gap). The design's water tile flips to
/// the help tint once "stale", but the product docs record no confirmed
/// staleness threshold yet (docs/product/review-2026-07.md) — so every
/// tile stays neutral here rather than guessing one.
class _ThreeStatHeader extends StatelessWidget {
  const _ThreeStatHeader({required this.detail});

  final CatDetail detail;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatTile(
            icon: Icons.visibility_outlined,
            label: 'görüldü',
            time: detail.lastSeenAt,
            color: AppColors.seenFg,
          ),
        ),
        const SizedBox(width: AppSpacing.s2),
        Expanded(
          child: _StatTile(
            icon: Icons.set_meal_outlined,
            label: 'mama',
            time: detail.lastFedAt,
            color: AppColors.fedFg,
          ),
        ),
        const SizedBox(width: AppSpacing.s2),
        Expanded(
          child: _StatTile(
            icon: Icons.water_drop_outlined,
            label: 'su',
            time: detail.lastWaterAt,
            color: AppColors.waterFg,
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.label,
    required this.time,
    required this.color,
  });

  final IconData icon;
  final String label;
  final DateTime? time;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s2,
        vertical: AppSpacing.s2,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            time != null ? relativeTimeTr(time!) : 'henüz yok',
            style: const TextStyle(fontSize: 13, color: AppColors.ink),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

enum _ProfileTab { history, media }

/// The "geçmiş / medya" segmented control (binding design's `.seg`) and its
/// switched content: the update timeline, or the photo archive (issue
/// #121's media-tab/archive parity gap). Which tab is selected is pure
/// local navigation state, not data to persist or reconcile against the
/// server. The medya side's count badge comes straight from
/// [CatDetail.mediaCount] (a real field); geçmiş shows no count, since the
/// timeline's own total isn't a field this api exposes (only one loaded
/// page at a time) — inventing one would repeat the exact mistake the
/// cover counter itself used to make before issue #121 gave it a real
/// source.
class _HistoryMediaSection extends ConsumerStatefulWidget {
  const _HistoryMediaSection({
    required this.catId,
    required this.mediaCount,
    required this.isOwner,
    required this.updates,
    required this.pending,
    required this.hasNextPage,
    required this.isLoadingMore,
    required this.onLoadMore,
  });

  final String catId;
  final int mediaCount;
  // isOwner (issue #156) gates the media grid's "ana fotoğraf yap" (make
  // cover photo) affordance — only the cat's own owner ever sees it.
  final bool isOwner;
  final List<CatUpdateEntry> updates;
  final PendingUpdate? pending;
  final bool hasNextPage;
  final bool isLoadingMore;
  final VoidCallback onLoadMore;

  @override
  ConsumerState<_HistoryMediaSection> createState() =>
      _HistoryMediaSectionState();
}

class _HistoryMediaSectionState extends ConsumerState<_HistoryMediaSection> {
  _ProfileTab _tab = _ProfileTab.history;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ProfileSegmentedControl(
          selected: _tab,
          mediaCount: widget.mediaCount,
          onChanged: (tab) => setState(() => _tab = tab),
        ),
        const SizedBox(height: AppSpacing.s3),
        if (_tab == _ProfileTab.history) _buildHistory() else _buildMedia(),
      ],
    );
  }

  Widget _buildHistory() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.pending != null) ...[
          OptimisticInlineRow(
            label: optimisticUpdateLabelTr(widget.pending!),
            status: widget.pending!.status,
          ),
          const SizedBox(height: AppSpacing.s3),
        ],
        if (widget.updates.isEmpty && widget.pending == null)
          const _EmptyHistory()
        else if (widget.updates.isNotEmpty) ...[
          for (var i = 0; i < widget.updates.length; i++)
            _TimelineItem(
              catId: widget.catId,
              update: widget.updates[i],
              isLast: i == widget.updates.length - 1 && !widget.hasNextPage,
            ),
          if (widget.hasNextPage) ...[
            const SizedBox(height: AppSpacing.s2),
            _LoadMoreButton(
              isLoading: widget.isLoadingMore,
              onPressed: widget.onLoadMore,
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildMedia() {
    final media = ref.watch(catMediaProvider(widget.catId));
    return media.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.s6),
        child: Center(
          child: InlineSpinner(
            size: 22,
            color: AppColors.primary,
            trackColor: AppColors.line,
          ),
        ),
      ),
      error: (_, _) => const _EmptyMedia(message: 'Medya yüklenemedi'),
      data: (items) {
        if (items.isEmpty) {
          return const _EmptyMedia(message: 'Henüz medya yok');
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: items.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: AppSpacing.s2,
                crossAxisSpacing: AppSpacing.s2,
                childAspectRatio: 1,
              ),
              itemBuilder: (context, i) => _MediaTile(
                catId: widget.catId,
                item: items[i],
                isOwner: widget.isOwner,
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
            const SizedBox(
              width: double.infinity,
              child: Text(
                'her görsel bir güncellemeye ait · dokun, tam ekran aç',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppColors.faint),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ProfileSegmentedControl extends StatelessWidget {
  const _ProfileSegmentedControl({
    required this.selected,
    required this.mediaCount,
    required this.onChanged,
  });

  final _ProfileTab selected;
  final int mediaCount;
  final ValueChanged<_ProfileTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ProfileSegment(
              label: 'geçmiş',
              isOn: selected == _ProfileTab.history,
              onTap: () => onChanged(_ProfileTab.history),
            ),
          ),
          Expanded(
            child: _ProfileSegment(
              label: 'medya',
              count: mediaCount,
              isOn: selected == _ProfileTab.media,
              onTap: () => onChanged(_ProfileTab.media),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileSegment extends StatelessWidget {
  const _ProfileSegment({
    required this.label,
    required this.isOn,
    required this.onTap,
    this.count,
  });

  final String label;
  final bool isOn;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isOn ? AppColors.surface : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.md),
      elevation: isOn ? 1 : 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        // A minimum, not a fixed, height — mirrors _UpdateBar's own
        // constraint — so the label can wrap taller at large system text
        // scale instead of clipping or overflowing the segment.
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kTapMin),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s2,
              vertical: AppSpacing.s2,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      color: isOn ? AppColors.ink : AppColors.faint,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (count != null) ...[
                  const SizedBox(width: 7),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: isOn ? AppColors.primary : AppColors.line,
                      borderRadius: BorderRadius.circular(AppRadius.full),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: isOn ? AppColors.primaryInk : AppColors.faint,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One entry of the "medya" archive grid (binding design's `.med.sm` tile):
/// square, rounded, tap opens the same uncropped full-screen view the cover
/// photo uses. [CatMediaItem.isCover] marks the cat's current cover photo
/// with the design's "ana" badge — never any other entry. The uploader
/// (issue #154's media-attribution parity gap) renders with the same
/// [_TimelineAvatar] the update timeline already uses, so a media entry's
/// attribution reads identically to a text update's — never a second
/// visual language just because the entry happens to carry a photo. Only
/// this grid's own full-screen view carries the "ana fotoğraf yap" (make
/// cover photo) action (issue #156, design frame D) — never the cover's
/// own view or a timeline thumbnail's, and only when [isOwner].
class _MediaTile extends StatelessWidget {
  const _MediaTile({
    required this.catId,
    required this.item,
    required this.isOwner,
  });

  final String catId;
  final CatMediaItem item;
  final bool isOwner;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => _FullScreenPhoto(
            photo: item.url,
            catId: isOwner ? catId : null,
            mediaId: isOwner ? item.id : null,
            isCover: item.isCover,
          ),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CachedNetworkImage(
              imageUrl: item.url,
              fit: BoxFit.cover,
              placeholder: (context, _) =>
                  const _HeroPlaceholder(loading: true),
              errorWidget: (context, _, _) => const _HeroPlaceholder(),
            ),
            if (item.isCover)
              Positioned(
                left: 6,
                top: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: const Text(
                    'ana',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primaryInk,
                    ),
                  ),
                ),
              ),
            Positioned(
              right: 6,
              bottom: 6,
              child: Tooltip(
                message: item.uploaderDisplayName ?? '',
                child: Transform.scale(
                  scale: 0.7,
                  alignment: Alignment.bottomRight,
                  child: _TimelineAvatar(name: item.uploaderDisplayName),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyMedia extends StatelessWidget {
  const _EmptyMedia({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s6),
      child: Row(
        children: [
          const Icon(
            Icons.photo_library_outlined,
            color: AppColors.faint,
            size: 22,
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppColors.muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// The screen's single primary action, fixed over the scroll (binding
/// design docs/design/screens/cat-profile.html: "ekranda tek bir birincil
/// buton var: + update" — "gördüm" is an option inside the composition
/// sheet this opens, never a competing button here). Supersedes issue
/// #43's separate one-tap "Gördüm" shortcut and, with it, issue #80's
/// derived already-seen disable, which only existed for that shortcut.
class _UpdateBar extends ConsumerWidget {
  const _UpdateBar({required this.catId});

  final String catId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(
      catUpdateComposerProvider(catId).select((s) => s.isSubmitting),
    );
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [AppColors.bg, AppColors.bg, Color(0x00F7F1E8)],
          stops: [0.0, 0.62, 1.0],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s4,
            AppSpacing.s3,
            AppSpacing.s4,
            AppSpacing.s5,
          ),
          child: ConstrainedBox(
            // A minimum, not a fixed height: the label may wrap taller at
            // large system text scale without overflowing the button.
            constraints: const BoxConstraints(
              minWidth: double.infinity,
              minHeight: kTapMin,
            ),
            child: ElevatedButton(
              onPressed: busy ? null : () => _gatedOpenComposer(context, ref),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.primaryInk,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                ),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15.5,
                ),
              ),
              child: const Text('+ update'),
            ),
          ),
        ),
      ),
    );
  }

  // Gate-at-intent (issue #65): the composition sheet may not open before
  // authentication succeeds. AuthGate itself is the only thing that
  // decides whether to show its prompt — already-authenticated callers
  // fall straight through with no extra ui.

  Future<void> _gatedOpenComposer(BuildContext context, WidgetRef ref) {
    return AuthGate.require(
      context,
      ref,
      contextText: 'Güncelleme paylaşmak için giriş yap',
      intent: AnalyticsAuthIntent.ordinaryUpdate,
      onAuthenticated: () => unawaited(_openComposer(context)),
    );
  }

  Future<void> _openComposer(BuildContext context) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CatUpdateSheet(catId: catId),
    );
    // Only a synchronous help submission pops true — an ordinary one pops
    // immediately and its optimistic row carries the feedback instead.
    if (result == true && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Güncelleme paylaşıldı')));
    }
  }
}

/// Background/foreground pair per status kind (binding design
/// docs/design/screens/cat-profile.html: each action chip is
/// color-coded independently — fed tan, seen green, water blue — never
/// sharing one generic pill). A status outside this map (future/legacy)
/// falls back to the app's default primary tint.
const _statusColorsTr = {
  'seen': (bg: AppColors.seenBg, fg: AppColors.seenFg),
  'fed': (bg: AppColors.fedBg, fg: AppColors.fedFg),
  'water_provided': (bg: AppColors.waterBg, fg: AppColors.waterFg),
};

class _StatusTag extends StatelessWidget {
  const _StatusTag({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final colors =
        _statusColorsTr[status] ??
        (bg: AppColors.primarySoft, fg: AppColors.primaryStrong);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s2,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: colors.bg,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Text(
        _statusLabelsTr[status] ?? status,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: colors.fg,
        ),
      ),
    );
  }
}

/// A help-carrying timeline entry's `yardım gerekiyor` chip (binding copy,
/// docs/design/screens/cat-profile.html) — one fixed label, never a
/// category (docs/product/alerts.md: legacy categories are never
/// reproduced, so a legacy record renders this same chip). Deliberately
/// never uses the loud help-red styling here, active or expired — that
/// emphasis lives solely in _ActiveAlertBanner above the timeline, so it
/// isn't duplicated per history entry. An expired entry additionally never
/// gets any active-looking accent.
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
        'yardım gerekiyor',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: isActive ? AppColors.helpStrong : AppColors.muted,
        ),
      ),
    );
  }
}

/// The timeline rail's per-entry author avatar (binding design's `.rail
/// .av`): a 34px colored circle carrying the author's own first letter,
/// lowercase — matching the design's own lowercase initials. [name] is
/// null for a pre-#65/seed row or an account that never set a display
/// name; that case falls back to a plain person glyph rather than
/// inventing an initial. The per-name color is a deterministic pick from
/// the app's own status palette, purely so adjacent authors read as
/// visually distinct — not a new design token. The design's own
/// "bakıcı işareti" (care) badge is a separate, still-open product item
/// (docs/design/screens/cat-profile.html's own recorded open question)
/// and is deliberately not rendered here.
class _TimelineAvatar extends StatelessWidget {
  const _TimelineAvatar({required this.name});

  final String? name;

  static const _palette = [
    AppColors.seenFg,
    AppColors.fedFg,
    AppColors.waterFg,
    AppColors.primaryStrong,
  ];

  @override
  Widget build(BuildContext context) {
    final trimmed = name?.trim();
    final hasName = trimmed != null && trimmed.isNotEmpty;
    final color = hasName
        ? _palette[trimmed.codeUnitAt(0) % _palette.length]
        : AppColors.faint;
    return Container(
      margin: const EdgeInsets.only(top: 2),
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: hasName
          ? Text(
              trimmed.substring(0, 1).toLowerCase(),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            )
          : const Icon(Icons.person_outline, size: 16, color: Colors.white),
    );
  }
}

/// One update's structured statuses and free-text comment render as two
/// visually distinct elements — status tags (bold pills) vs. plain (never
/// italic) muted body text — per issue #21's requirement that the two
/// never blur together.
class _TimelineItem extends StatelessWidget {
  const _TimelineItem({
    required this.catId,
    required this.update,
    required this.isLast,
  });

  final String catId;
  final CatUpdateEntry update;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 34,
            child: Column(
              children: [
                _TimelineAvatar(name: update.authorDisplayName),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 1.5,
                      margin: const EdgeInsets.only(top: 6),
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
                      // A combined update (statuses + the help mark, issue
                      // #101) is one timeline event: its chips render
                      // side by side on the same row, never as two
                      // entries.
                      Expanded(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            if (update.needsHelp) _NeedsHelpTag(update: update),
                            ...update.statuses.map(
                              (s) => _StatusTag(status: s),
                            ),
                          ],
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
                      // issue #80, extended by #101: only the author sees
                      // this, and only while their own update — ordinary
                      // or help-carrying — is still within its 10-minute
                      // correction window (correction_expires_at is only
                      // ever served on a correctable row; a legacy
                      // pre-#101 help record never gets one). A
                      // soft-deleted update never reaches this list at
                      // all, for any reader, so no separate "not deleted"
                      // check is needed here.
                      if (update.authorIsMe && update.isCorrectionOpen())
                        _CorrectionMenuButton(catId: catId, update: update),
                    ],
                  ),
                  if (update.comment != null) ...[
                    const SizedBox(height: 4),
                    // A help-carrying entry's comment is its help note —
                    // set apart on the soft help tint (the design's
                    // `.note.help` treatment), while an ordinary comment
                    // stays plain muted body text.
                    if (update.needsHelp)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.s3,
                          vertical: AppSpacing.s2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.helpSoft,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Text(
                          update.comment!,
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.helpStrong,
                            height: 1.4,
                          ),
                        ),
                      )
                    else
                      Text(
                        update.comment!,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.muted,
                          height: 1.4,
                        ),
                      ),
                  ],
                  if (update.photoUrl != null) ...[
                    const SizedBox(height: 11),
                    _TimelineThumbnail(
                      url: update.photoUrl!,
                      isVideo: update.isVideoMedia,
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

/// A timeline entry's inline media thumbnail (binding design's `.med`):
/// only rendered when [CatUpdateEntry.photoUrl] is set — issue #121 added
/// the read plumbing, issue #153 the write path (the update composer's
/// optional photo attachment, later extended to video). [isVideo] mirrors
/// [CatUpdateEntry.isVideoMedia] and picks the thumbnail/full-screen widget
/// pair: a photo opens the same uncropped full-screen view the cover photo
/// and media grid use, a video opens its own playing full-screen view — a
/// video is never eligible to become the cat's cover, so that view carries
/// no such action.
class _TimelineThumbnail extends StatelessWidget {
  const _TimelineThumbnail({required this.url, required this.isVideo});

  final String url;
  final bool isVideo;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => isVideo
              ? _FullScreenVideo(url: url)
              : _FullScreenPhoto(photo: url),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: SizedBox(
          width: 98,
          height: 98,
          child: isVideo
              ? _VideoThumbnail(url: url)
              : CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.cover,
                  placeholder: (context, _) =>
                      const _HeroPlaceholder(loading: true),
                  errorWidget: (context, _, _) => const _HeroPlaceholder(),
                ),
        ),
      ),
    );
  }
}

/// A video timeline entry's static thumbnail — the first decoded frame of
/// the uploaded video (via [VideoPlayerController], paused), with a
/// play-glyph overlay so it reads apart from a plain photo. Never decoded
/// from local bytes before upload (see [_MediaPicker]'s own doc for why);
/// this only ever renders an already-uploaded, network-hosted video.
class _VideoThumbnail extends StatefulWidget {
  const _VideoThumbnail({required this.url});

  final String url;

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  late final VideoPlayerController _controller;
  late final Future<void> _initialize;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _initialize = _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.bgElevated,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<void>(
            future: _initialize,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const _HeroPlaceholder(loading: true);
              }
              return FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _controller.value.size.width,
                  height: _controller.value.size.height,
                  child: VideoPlayer(_controller),
                ),
              );
            },
          ),
          const Center(
            child: Icon(Icons.play_circle_fill, size: 32, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

/// The full-screen view for a video timeline entry (issue #153's video
/// support) — mirrors [_FullScreenPhoto]'s dark surface and single close
/// action, autoplaying looped with a tap-to-pause/resume affordance
/// instead of a static `contain`ed image. Never carries a "make cover"
/// action: a video is never eligible to become the cat's cover.
class _FullScreenVideo extends StatefulWidget {
  const _FullScreenVideo({required this.url});

  final String url;

  @override
  State<_FullScreenVideo> createState() => _FullScreenVideoState();
}

class _FullScreenVideoState extends State<_FullScreenVideo> {
  late final VideoPlayerController _controller;
  late final Future<void> _initialize;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _initialize = _controller.initialize().then((_) {
      _controller.setLooping(true);
      _controller.play();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _togglePlay() {
    if (!_controller.value.isInitialized) return;
    setState(() {
      if (_controller.value.isPlaying) {
        _controller.pause();
      } else {
        _controller.play();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141010),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: FutureBuilder<void>(
              future: _initialize,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const InlineSpinner(
                    size: 28,
                    color: AppColors.primarySoft,
                    trackColor: Color(0x33FFFFFF),
                  );
                }
                return GestureDetector(
                  onTap: _togglePlay,
                  child: AspectRatio(
                    aspectRatio: _controller.value.aspectRatio,
                    child: VideoPlayer(_controller),
                  ),
                );
              },
            ),
          ),
          Positioned(
            top: AppSpacing.s3,
            left: AppSpacing.s4,
            child: SafeArea(
              child: Material(
                color: Colors.white.withValues(alpha: 0.14),
                shape: const CircleBorder(),
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: 'Kapat',
                  icon: const Icon(Icons.close, color: Colors.white),
                  constraints: const BoxConstraints(
                    minWidth: kTapMin,
                    minHeight: kTapMin,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The correction-window "⋮" affordance (issue #80) — only ever shown to an
/// update's own author, and only while it's still open (see the call site
/// in _TimelineItem above). No dedicated read-only state: once the window
/// closes, this button simply stops rendering rather than rendering
/// disabled, since there is nothing left it could still do.
class _CorrectionMenuButton extends StatelessWidget {
  const _CorrectionMenuButton({required this.catId, required this.update});

  final String catId;
  final CatUpdateEntry update;

  @override
  Widget build(BuildContext context) {
    // kTapMin-square tap target (this app's minimum touch target
    // everywhere else), even though the visible glyph stays small to fit
    // the timeline row's compact header.
    return SizedBox(
      width: kTapMin,
      height: kTapMin,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 16,
        icon: const Icon(Icons.more_vert, color: AppColors.faint),
        tooltip: 'Güncellemeyi düzelt',
        onPressed: () =>
            openUpdateCorrectionSheet(context, catId: catId, entry: update),
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
          Expanded(
            child: Text(
              'Henüz güncelleme yok',
              style: TextStyle(color: AppColors.muted),
            ),
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
