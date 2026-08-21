import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../../../core/analytics/analytics.dart';
import '../../../core/motion/hero_tags.dart';
import '../../../core/motion/press_response.dart';
import '../../../core/motion/tekir_haptics.dart';
import '../../../core/motion/tekir_motion.dart';
import '../../../core/states/initial_read_gate.dart';
import '../../../core/states/inline_spinner.dart';
import '../../../core/states/optimistic_inline_row.dart';
import '../../../core/states/shimmer_sweep.dart';
import '../../../core/states/tekir_snack.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/relative_time.dart';
import '../../auth/ui/auth_gate.dart';
import '../../follow/ui/follow_button.dart';
import '../data/cat_detail.dart';
import 'cat_detail_notifier.dart';
import 'cat_update_composer_notifier.dart';
import 'cat_update_sheet.dart';
import 'edit_cat_name_sheet.dart';
import '../../../core/images/decode_budget.dart';
import '../../blocks/ui/block_action.dart';
import '../../discover/ui/discover_notifier.dart';
import '../../map/ui/cats_map_notifier.dart';
import 'report_reason.dart';
import 'report_sheet.dart';
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
      return _DetailSkeleton(catId: widget.catId);
    }
    final detail = state.detail;
    if (detail == null) {
      return _DetailSkeleton(catId: widget.catId);
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
      // An ordinary submission never shows a snackbar — its optimistic row
      // is the feedback — so this transition is the only place the
      // confirmation haptic can fire. TekirHaptics.committed names "an
      // update posted" first in its own doc and, until now, was called
      // from nowhere but the follow button.
      final wasSaving = previous?.pending?.status == InlineSaveStatus.saving;
      if (wasSaving && next.pending == null) {
        unawaited(TekirHaptics.committed());
      }
      final failedNow =
          wasSaving && next.pending?.status == InlineSaveStatus.failed;
      final error = next.error;
      if (!failedNow || error == null) return;
      TekirSnack.failure(
        context,
        updateSubmitErrorMessageTr(error),
        clearsFixedBar: true,
      );
    });
    return Stack(
      children: [
        _buildScroll(context, ref, pending),
        // Pinned, not scrolled. These used to be the ListView's first
        // child, so scrolling took the only visible way back off screen
        // entirely — on a smaller phone within one flick. The system back
        // gesture still worked; nothing on screen said so.
        Positioned(
          top: MediaQuery.paddingOf(context).top + AppSpacing.s3,
          left: AppSpacing.s4,
          right: AppSpacing.s4,
          child: Row(
            children: [
              const _BackCircleButton(),
              const Spacer(),
              FollowButton(catId: detail.id, source: openSource, glass: true),
            ],
          ),
        ),
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
        _ProfileHeader(detail: detail, openSource: openSource),
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

/// The cat's profile photo and the two controls that used to live on the
/// old 16:9 cover (issue #236). The wide cover area is gone from the
/// product: a portrait phone photo cropped to 16:9 lost most of the cat,
/// and the cover/focal-point concept never matched how this product thinks
/// about a cat's identity. What replaces it is a circular avatar — the
/// same canonical image, `cover`-fit inside a circle so the aspect ratio is
/// never distorted, only cropped square.
///
/// Back and follow move into a plain row above it, since without a photo
/// behind them the glass treatment has nothing to sit on. Tapping the
/// avatar still opens the uncropped full-screen view, and the media
/// counter still marks that there is an archive behind it — now beside the
/// name rather than as a pill on a photo.
class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.detail, this.openSource});

  final CatDetail detail;
  final AnalyticsSource? openSource;

  static const double _diameter = 132;

  @override
  Widget build(BuildContext context) {
    final photo = detail.primaryPhoto;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.s4,
        MediaQuery.of(context).padding.top + AppSpacing.s3,
        AppSpacing.s4,
        0,
      ),
      child: Column(
        children: [
          // Clearance for the pinned back/follow row above this
          // (_CatDetailBody), which used to live here and scroll away.
          const SizedBox(height: kTapMin + AppSpacing.s4),
          // The other end of the map's marker-preview flight
          // (core/motion/hero_tags.dart). The shuttle is authored rather
          // than left to the default, because the two ends are different
          // shapes: without it the photo would carry the sheet's rounded
          // square the whole way and snap to a circle on arrival.
          Hero(
            tag: catPhotoHeroTag(detail.id),
            flightShuttleBuilder: (_, animation, direction, _, _) =>
                _CatPhotoFlight(
                  animation: animation,
                  direction: direction,
                  photo: photo,
                ),
            child: GestureDetector(
              onTap: photo == null
                  ? null
                  : () => _openFullScreen(context, photo),
              child: ClipOval(
                child: SizedBox(
                  width: _diameter,
                  height: _diameter,
                  child: photo == null
                      ? const _HeroPlaceholder()
                      : CachedNetworkImage(
                          imageUrl: photo,
                          fit: BoxFit.cover,
                          memCacheWidth: decodeWidthFor(context, _diameter),
                          placeholder: (context, _) =>
                              const _HeroPlaceholder(loading: true),
                          errorWidget: (context, _, _) =>
                              const _HeroPlaceholder(),
                        ),
                ),
              ),
            ),
          ),
          if (detail.mediaCount > 0) ...[
            const SizedBox(height: AppSpacing.s3),
            _MediaCountBadge(count: detail.mediaCount),
          ],
        ],
      ),
    );
  }

  /// The full-screen view (binding design, frame D): dark surface, the
  /// photo `contain`ed with no crop, a single close action. "profil
  /// fotoğrafı yap" (issue #156, renamed by #236) belongs to the media
  /// archive grid's own tiles, which carry a media id this profile photo
  /// string alone doesn't — so the profile photo's own view still carries
  /// no action but closing.
  void _openFullScreen(BuildContext context, String photo) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _FullScreenPhoto(photo: photo),
      ),
    );
  }
}

/// The "there is an archive behind this" indicator: a camera glyph plus
/// [count], the cat's [CatDetail.mediaCount] — never shown at zero, since
/// a zero pill would only advertise an archive with nothing in it. It used
/// to sit bottom-right on the cover photo; with the cover gone (issue
/// #236) it sits under the profile photo, keeping the same glyph so the
/// affordance stays recognisable.
class _MediaCountBadge extends StatelessWidget {
  const _MediaCountBadge({required this.count});

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
///
/// [CatDetail.isOwner] (issue #227) additionally gates a rename affordance
/// on the name itself — a non-owner never receives the trigger at all,
/// mirroring exactly how the media archive withholds (rather than
/// disables) its own owner-only "ana fotoğraf yap" affordance. Placement
/// and interaction mirror [ProfileScreen]'s own display-name edit
/// verbatim (product-owner review): the name becomes tappable with a small
/// faint edit glyph beside it, opening [EditCatNameSheet] as a
/// root-navigator bottom sheet.
///
/// [CatDetail.isOwner] (issue #228) also gates a trailing delete
/// affordance on this same row, next to the rename glyph (product-owner
/// review) — see [_DeleteCatButton].
class _IdentityBlock extends StatelessWidget {
  const _IdentityBlock({required this.detail});

  final CatDetail detail;

  Future<void> _openEditCatName(BuildContext context) async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      // CatDetailScreen is reached by a push from a persistent shell tab
      // (app_shell.dart) with its own nested Navigator — without this, the
      // sheet paints underneath the shell's persistent add-cat fab,
      // mirroring ProfileScreen's/map_screen.dart's identical fix.
      useRootNavigator: true,
      builder: (_) =>
          EditCatNameSheet(catId: detail.id, currentName: detail.name),
    );
  }

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
          Row(
            children: [
              Expanded(
                child: detail.isOwner
                    ? InkWell(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        onTap: () => _openEditCatName(context),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                detail.name,
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineSmall,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.s2),
                            const Icon(
                              Icons.edit_outlined,
                              size: 18,
                              color: AppColors.faint,
                            ),
                          ],
                        ),
                      )
                    : Text(
                        detail.name,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
              ),
              _ReportButton(
                targetType: ReportTargetType.cat,
                targetId: detail.id,
                tooltip: 'Kedi işlemleri',
                blockUserId: detail.isOwner ? null : detail.ownerUserId,
                evictCatId: detail.id,
              ),
              if (detail.isOwner) _DeleteCatButton(catId: detail.id),
            ],
          ),
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

/// The cat's own owner delete affordance (issue #228) — `DELETE
/// /v1/cats/{cat_id}` shipped in #200, but nothing in the app reached it
/// until now. Sits beside the rename glyph on [_IdentityBlock]'s own name
/// row (product-owner review), gated by [CatDetail.isOwner] exactly like
/// [EditCatNameSheet]'s own trigger. Confirmed before ever calling the
/// api — deletion is terminal, #200: no restore exists — via the same
/// confirm-dialog copy/shape [UpdateCorrectionSheet]'s own delete uses.
/// On success the screen pops off the stack (product-owner decision: back
/// to whichever screen opened it, never a forced destination); the
/// map/discover surfaces drop the cat from their own already-loaded state
/// in place rather than through a reload — see
/// [CatDetailNotifier.deleteCat].
class _DeleteCatButton extends ConsumerStatefulWidget {
  const _DeleteCatButton({required this.catId});

  final String catId;

  @override
  ConsumerState<_DeleteCatButton> createState() => _DeleteCatButtonState();
}

class _DeleteCatButtonState extends ConsumerState<_DeleteCatButton> {
  bool _isDeleting = false;

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kediyi sil'),
        content: const Text(
          'Bu kediyi silmek istediğine emin misin? Bu işlem geri alınamaz.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Vazgeç'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.help),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isDeleting = true);
    try {
      await ref.read(catDetailProvider(widget.catId).notifier).deleteCat();
      if (!mounted) return;
      // Captured before popping — this screen's own context is on its way
      // out, but MaterialApp's ScaffoldMessenger is shared app-wide, so the
      // toast still lands once the previous screen is back on top.
      final messenger = ScaffoldMessenger.of(context);
      context.pop();
      TekirSnack.showOn(messenger, 'Kedi silindi.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _isDeleting = false);
      TekirSnack.failure(context, 'Kedi silinemedi, tekrar dene.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: kTapMin,
      height: kTapMin,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 18,
        icon: _isDeleting
            ? const InlineSpinner(
                size: 16,
                color: AppColors.help,
                trackColor: AppColors.line,
              )
            : const Icon(Icons.delete_outline, color: AppColors.help),
        tooltip: 'Kediyi sil',
        onPressed: _isDeleting ? null : _confirmDelete,
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
      TekirSnack.failure(context, 'Kapak fotoğrafı değiştirilemedi');
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
              // The one place a photo is meant to be seen at size: still
              // capped at the screen's own pixel width, since decoding
              // beyond it buys nothing visible.
              memCacheWidth: decodeWidthFor(
                context,
                MediaQuery.sizeOf(context).width,
              ),
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
                  isCover ? 'profil fotoğrafı' : 'profil fotoğrafı yap',
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
  const _BackCircleButton();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      excludeSemantics: true,
      button: true,
      // A bare chevron glyph announces as "button" and nothing else. This
      // is also the only visible way back on the screen, so leaving it
      // unnamed left a screen reader user with no exit they could find.
      label: 'Geri',
      onTap: () => _goBack(context),
      child: Material(
        color: AppColors.surface,
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _goBack(context),
          child: const SizedBox(
            width: kTapMin,
            height: kTapMin,
            child: Icon(Icons.chevron_left, color: AppColors.ink),
          ),
        ),
      ),
    );
  }

  // add-cat's success path (and a duplicate-candidate "bu zaten var" pick)
  // lands here via context.go, which replaces the whole stack instead of
  // pushing — so there is nothing to pop in that case. Fall back to the
  // map, the app's root destination.
  void _goBack(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
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
            raisedColor: AppColors.seenBg,
          ),
        ),
        const SizedBox(width: AppSpacing.s2),
        Expanded(
          child: _StatTile(
            icon: Icons.set_meal_outlined,
            label: 'mama',
            time: detail.lastFedAt,
            color: AppColors.fedFg,
            raisedColor: AppColors.fedBg,
          ),
        ),
        const SizedBox(width: AppSpacing.s2),
        Expanded(
          child: _StatTile(
            icon: Icons.water_drop_outlined,
            label: 'su',
            time: detail.lastWaterAt,
            color: AppColors.waterFg,
            raisedColor: AppColors.waterBg,
          ),
        ),
      ],
    );
  }
}

/// Whether a change in a [_StatTile]'s timestamp is one the tile may
/// acknowledge with its raise animation.
///
/// Only a timestamp moving *forward* qualifies — an answer arriving, or a
/// newer one replacing it. A tile that raised on any change would also
/// raise on the answer being *lost*, which is exactly what shipped while
/// `CatDetailNotifier.prependUpdate` was dropping these fields: posting an
/// update reset all three tiles to "henüz yok" and all three lit up in
/// their status tint to celebrate it. That data bug is fixed, but the
/// animation must not be capable of making the same mistake for the next
/// one — motion in this app confirms what the user did, and losing an
/// answer is never that.
///
/// Public and file-level so it can be tested directly; the widget it
/// serves is private.
bool isAcknowledgeableStatTimeChange(DateTime? previous, DateTime? current) {
  if (current == null) return false;
  if (previous == null) return true;
  return current.isAfter(previous);
}

/// One tile of the three-question strip, and the app's clearest piece of
/// causality: this tile is the answer to "when was this cat last fed", and
/// the user's own update is what changed it.
///
/// When [time] changes the tile briefly raises to its own status tint —
/// the [AppColors.seenBg]/[AppColors.fedBg]/[AppColors.waterBg] pair that
/// already exists for this status — then settles back to the neutral
/// surface. Nothing new is introduced: it borrows the color the timeline's
/// own chip for this status already uses, for about half a second, and
/// gives it back.
///
/// Only a change raises it, never the first build — arriving on a screen
/// is not an event, and a tile that flashed on open would be decoration.
///
/// Under reduced motion the raise still happens (it is a state change, not
/// travel) but crosses instantly instead of fading.
class _StatTile extends StatefulWidget {
  const _StatTile({
    required this.icon,
    required this.label,
    required this.time,
    required this.color,
    required this.raisedColor,
  });

  final IconData icon;
  final String label;
  final DateTime? time;
  final Color color;

  /// This status's own soft tint, held while the tile acknowledges a
  /// change.
  final Color raisedColor;

  @override
  State<_StatTile> createState() => _StatTileState();
}

class _StatTileState extends State<_StatTile> {
  /// How long the tile holds its tint before settling. Long enough to be
  /// read after a glance moves back from the sheet that just closed, short
  /// enough that it never becomes the tile's resting state.
  static const _hold = Duration(milliseconds: 600);

  bool _raised = false;
  Timer? _settle;

  @override
  void didUpdateWidget(_StatTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!isAcknowledgeableStatTimeChange(oldWidget.time, widget.time)) return;
    _settle?.cancel();
    setState(() => _raised = true);
    _settle = Timer(_hold, () {
      if (mounted) setState(() => _raised = false);
    });
  }

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final motion = TekirMotion.of(context);
    final icon = widget.icon;
    final label = widget.label;
    final time = widget.time;
    final color = widget.color;

    return AnimatedContainer(
      // Rising is the acknowledgment and settling is the release, so the
      // return is deliberately the slower of the two — the inverse of the
      // usual enter/exit relationship, and the reason the settle token
      // exists.
      duration: _raised
          ? motion(TekirMotion.state)
          : motion(TekirMotion.settle),
      curve: _raised ? TekirMotion.enter : TekirMotion.exit,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s2,
        vertical: AppSpacing.s2,
      ),
      decoration: BoxDecoration(
        color: _raised ? widget.raisedColor : AppColors.surfaceAlt,
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
            time != null ? relativeTimeTr(time) : 'henüz yok',
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
          onChanged: (tab) {
            if (tab == _tab) return;
            unawaited(TekirHaptics.acknowledge());
            setState(() => _tab = tab);
          },
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
          _EmptyHistory(catId: widget.catId)
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
      error: (_, _) => _EmptyMedia(
        catId: widget.catId,
        onRetry: () => ref.invalidate(catMediaProvider(widget.catId)),
      ),
      data: (items) {
        if (items.isEmpty) {
          return _EmptyMedia(catId: widget.catId);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: items.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _mediaGridColumns,
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
    // `geçmiş` and `medya` announced identically whichever was open: the
    // active one is carried by a white fill and one step of elevation,
    // neither of which reaches a screen reader.
    return Semantics(
      container: true,
      excludeSemantics: true,
      button: true,
      selected: isOn,
      label: count == null ? label : '$label, $count',
      onTap: onTap,
      child: PressResponse(
        child: Material(
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
                    // Zero is not worth a badge: a filled pill reading
                    // "0" reads as an unread count. The avatar's own media
                    // badge already hides at zero; this one did not.
                    if (count != null && count! > 0) ...[
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
                            color: isOn
                                ? AppColors.primaryInk
                                : AppColors.faint,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One entry of the "medya" archive grid (binding design's `.med.sm` tile):
/// square, rounded, tap opens the same uncropped full-screen view the cover
/// photo uses — or, for a video entry, the timeline's own playing
/// full-screen video view (issue #179's gallery-content-type parity gap,
/// mirroring [_TimelineThumbnail]'s isVideo split). [CatMediaItem.isCover]
/// marks the cat's current cover photo with the design's "ana" badge —
/// never any other entry. The uploader (issue #154's media-attribution
/// parity gap) renders with the same [_TimelineAvatar] the update timeline
/// already uses, so a media entry's attribution reads identically to a text
/// update's — never a second visual language just because the entry
/// happens to carry a photo. Only this grid's own full-screen photo view
/// carries the "ana fotoğraf yap" (make cover photo) action (issue #156,
/// design frame D) — never the cover's own view, a timeline thumbnail's, or
/// a video entry's full-screen view (a video can never become the cover),
/// and only when [isOwner].
/// The media archive grid's column count. Named because [_MediaTile]'s
/// decode budget is derived from it — a grid that changed shape without the
/// budget following would silently start decoding at the wrong size again.
const int _mediaGridColumns = 3;

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
          builder: (_) => item.isVideoMedia
              ? _FullScreenVideo(url: item.url, muted: item.mediaMuted)
              : _FullScreenPhoto(
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
            if (item.isVideoMedia)
              _VideoThumbnail(url: item.url)
            else
              CachedNetworkImage(
                imageUrl: item.url,
                fit: BoxFit.cover,
                memCacheWidth: decodeWidthFor(
                  context,
                  MediaQuery.sizeOf(context).width / _mediaGridColumns,
                ),
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
                    'profil',
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
            Positioned(
              right: 4,
              top: 4,
              child: _ReportMediaBadge(
                catId: catId,
                mediaId: item.id,
                uploaderUserId: item.uploaderUserId,
                uploaderDisplayName: item.uploaderDisplayName,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The media tile's own "bildir" affordance (issue #233) — a compact
/// translucent circle overlay, mirroring [_FullScreenPhoto]'s own top-left
/// close-button shape/opacity, scaled down to fit a grid tile the same way
/// [_TimelineAvatar] is already scaled down for the uploader badge below
/// it. A distinct hit-testable [Material]/[InkWell], not part of the
/// tile's own full-area [GestureDetector] — tapping it opens the report
/// sheet instead of the tile's full-screen view.
class _ReportMediaBadge extends ConsumerWidget {
  const _ReportMediaBadge({
    required this.catId,
    required this.mediaId,
    this.uploaderUserId,
    this.uploaderDisplayName,
  });

  final String catId;
  final String mediaId;

  /// The account that uploaded this media (issue #234) — null for media
  /// predating account attribution, and then the badge stays a single
  /// report action.
  final String? uploaderUserId;
  final String? uploaderDisplayName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const glyph = Padding(
      padding: EdgeInsets.all(3),
      child: Icon(Icons.more_vert, size: 14, color: Colors.white),
    );

    if (uploaderUserId == null) {
      return Material(
        color: Colors.black.withValues(alpha: 0.35),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => openReportSheet(
            context,
            ref,
            targetType: ReportTargetType.media,
            targetId: mediaId,
          ),
          child: glyph,
        ),
      );
    }

    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      shape: const CircleBorder(),
      child: PopupMenuButton<_ContentAction>(
        padding: EdgeInsets.zero,
        tooltip: 'Medya işlemleri',
        onSelected: (action) => switch (action) {
          _ContentAction.report => openReportSheet(
            context,
            ref,
            targetType: ReportTargetType.media,
            targetId: mediaId,
          ),
          _ContentAction.block => confirmAndBlock(
            context,
            ref,
            userId: uploaderUserId!,
            displayName: uploaderDisplayName,
          ),
        },
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: _ContentAction.report,
            child: Text('Şikayet et'),
          ),
          PopupMenuItem(value: _ContentAction.block, child: Text('Engelle')),
        ],
        child: glyph,
      ),
    );
  }
}

/// The media tab with nothing in it, and the same tab when its own read
/// fails — two situations that must not look alike, which is why the
/// failure keeps its retry and the emptiness gets an invitation.
///
/// The invitation's action stays quiet rather than brick: this is a
/// secondary tab, and the screen's one primary action already lives in
/// the fixed bar below (contract: one primary, an optional secondary that
/// stays visually quiet).
class _EmptyMedia extends ConsumerWidget {
  const _EmptyMedia({required this.catId, this.onRetry});

  final String catId;

  /// Set when this is a failed read rather than an empty archive.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final failed = onRetry != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s4,
        AppSpacing.s5,
        AppSpacing.s4,
        AppSpacing.s6,
      ),
      child: Column(
        children: [
          DecoratedBox(
            decoration: const BoxDecoration(
              color: AppColors.surfaceAlt,
              shape: BoxShape.circle,
            ),
            child: SizedBox(
              width: 88,
              height: 88,
              child: Icon(
                failed
                    ? Icons.cloud_off_outlined
                    : Icons.photo_library_outlined,
                size: 34,
                color: AppColors.faint,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s5),
          Text(
            failed ? 'medya yüklenemedi' : 'henüz fotoğraf yok',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontSize: 21, height: 1.3),
          ),
          const SizedBox(height: AppSpacing.s3),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Text(
              failed
                  ? 'bağlantını kontrol edip tekrar dene.'
                  : 'güncelleme paylaşırken fotoğraf veya video '
                        'ekleyebilirsin.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.faint,
                height: 1.6,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s5),
          Material(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              onTap:
                  onRetry ?? () => openCatUpdateComposer(context, ref, catId),
              child: Container(
                constraints: const BoxConstraints(minHeight: kTapMin),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s5,
                  vertical: AppSpacing.s3,
                ),
                child: Text(
                  failed ? 'tekrar dene' : 'güncelleme ekle',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: AppColors.muted,
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
    return PressResponse(
      child: DecoratedBox(
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
                onPressed: busy
                    ? null
                    : () => openCatUpdateComposer(context, ref, catId),
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
      ),
    );
  }
}

/// Opens the update composer for [catId], gated at the point of intent.
///
/// File-level rather than private to [_UpdateBar] because the screen now
/// has two doors onto the same action: the fixed bar, and the empty
/// history state's own invitation. They must be the same door — same auth
/// gate, same draft reset, same confirmation — or the empty state would be
/// a second, subtly different way to post an update.
///
/// Gate-at-intent (issue #65): the composition sheet may not open before
/// authentication succeeds. AuthGate itself is the only thing that decides
/// whether to show its prompt — already-authenticated callers fall
/// straight through with no extra ui.
Future<void> openCatUpdateComposer(
  BuildContext context,
  WidgetRef ref,
  String catId,
) {
  return AuthGate.require(
    context,
    ref,
    contextText: 'Güncelleme paylaşmak için giriş yap',
    intent: AnalyticsAuthIntent.ordinaryUpdate,
    onAuthenticated: () => unawaited(_openComposer(context, ref, catId)),
  );
}

Future<void> _openComposer(
  BuildContext context,
  WidgetRef ref,
  String catId,
) async {
  // Reset synchronously, before the sheet ever mounts (issue #202) — a
  // dismissed-without-submitting draft, including any picked media, must
  // never be visible even for a single frame of a fresh open, whether
  // that's this same cat again or (via each cat's own composer instance)
  // a different one. See CatUpdateComposerNotifier.reset's own doc for
  // why a failed attempt's draft is the one exception kept whole.
  ref.read(catUpdateComposerProvider(catId).notifier).reset();
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => CatUpdateSheet(catId: catId),
  );
  // Only a synchronous help submission pops true — an ordinary one pops
  // immediately and its optimistic row carries the feedback instead.
  if (result == true && context.mounted) {
    TekirSnack.show(context, 'Güncelleme paylaşıldı', clearsFixedBar: true);
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
                      // Symmetric, so the connector sits centred in the
                      // gap between two avatars. It had 6 px above and the
                      // row's own 12 px below, which read as a rail
                      // leaning toward the next entry.
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      color: AppColors.line,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (update.authorDisplayName?.trim().isNotEmpty ?? false) ...[
                    Text(
                      update.authorDisplayName!.trim(),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                  ],
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
                        _CorrectionMenuButton(catId: catId, update: update)
                      else
                        _ReportButton(
                          targetType: ReportTargetType.update,
                          targetId: update.id,
                          tooltip: 'Güncelleme işlemleri',
                          iconSize: 16,
                          blockUserId: update.authorIsMe
                              ? null
                              : update.authorUserId,
                          blockDisplayName: update.authorDisplayName,
                        ),
                    ],
                  ),
                  if (update.comment != null) ...[
                    // Bound to the entry above it, not floating between
                    // two: this was 4 px from its own chip and 12 px from
                    // the next avatar, so which entry a free-text note
                    // belonged to was genuinely ambiguous.
                    const SizedBox(height: AppSpacing.s2),
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
                      muted: update.mediaMuted ?? true,
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
  const _TimelineThumbnail({
    required this.url,
    required this.isVideo,
    required this.muted,
  });

  final String url;
  final bool isVideo;

  /// The attached video's stored audio choice (issue #194) — passed
  /// through to the full-screen view unmute affordance; ignored for a
  /// photo entry.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => isVideo
              ? _FullScreenVideo(url: url, muted: muted)
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
                  memCacheWidth: decodeWidthFor(context, 98),
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
///
/// [VideoPlayerController.initialize] alone only decodes the container's
/// metadata (duration, size) — the platform player's own texture stays
/// blank/white until playback actually advances at least once (issue #198:
/// this is what made an uploaded video's thumbnail look broken/unfinished).
/// [_VideoThumbnailState] forces a real frame by playing for an instant and
/// immediately pausing right after initialize completes, and falls back to
/// [_HeroPlaceholder]'s non-loading state — never a blank texture — if
/// initialization itself fails.
class _VideoThumbnail extends StatefulWidget {
  const _VideoThumbnail({required this.url});

  final String url;

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  VideoPlayerController? _controller;
  Future<void>? _initialize;
  ScrollPosition? _scrollPosition;

  // The update history isn't a lazy list — it's a plain Column, so every
  // _VideoThumbnail in it mounts up front. Starting a
  // VideoPlayerController.initialize() for each one at once meant up to
  // ~20 concurrent video buffer/decode inits just to show a paused frame.
  // Instead, only start the controller once this thumbnail's own bounds
  // actually overlap the screen, and re-check on every scroll.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (!identical(position, _scrollPosition)) {
      _scrollPosition?.removeListener(_maybeInitialize);
      _scrollPosition = position;
      _scrollPosition?.addListener(_maybeInitialize);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeInitialize());
  }

  void _maybeInitialize() {
    if (_controller != null || !mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final top = box.localToGlobal(Offset.zero).dy;
    final screenHeight = MediaQuery.sizeOf(context).height;
    if (top >= screenHeight || top + box.size.height <= 0) return;
    final controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    final initialize = _initializeAndDecodeFirstFrame(controller);
    // A failure can land before this widget's next build ever gives
    // FutureBuilder a chance to attach its own listener below — without
    // this, that race reports as an unhandled async error (a real
    // decode failure would still surface correctly, just noisily).
    // ignore() only suppresses that report; FutureBuilder's own listener
    // still sees the same error once it attaches.
    initialize.ignore();
    setState(() {
      _controller = controller;
      _initialize = initialize;
    });
  }

  // initialize() alone decodes the container's metadata, not a pixel
  // frame — the platform player's own texture stays blank until playback
  // actually advances (see this class's own doc). Playing for an instant
  // and immediately pausing forces a real frame to decode, which then
  // stays on screen paused as the thumbnail.
  Future<void> _initializeAndDecodeFirstFrame(
    VideoPlayerController controller,
  ) async {
    await controller.initialize();
    await controller.play();
    await controller.pause();
  }

  @override
  void dispose() {
    _scrollPosition?.removeListener(_maybeInitialize);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return ColoredBox(
      color: AppColors.bgElevated,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (controller == null)
            const _HeroPlaceholder(loading: true)
          else
            FutureBuilder<void>(
              future: _initialize,
              builder: (context, snapshot) {
                // A genuinely failed decode (issue #198's fallback
                // requirement) gets the same non-loading placeholder a
                // failed photo load already uses — never a blank texture
                // built from a controller that never actually initialized.
                if (snapshot.hasError) {
                  return const _HeroPlaceholder();
                }
                if (snapshot.connectionState != ConnectionState.done) {
                  return const _HeroPlaceholder(loading: true);
                }
                return FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: controller.value.size.width,
                    height: controller.value.size.height,
                    child: VideoPlayer(controller),
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
///
/// Every playback surface starts muted (issue #194's playback-level
/// default, independent of the stored flag): [_controller]'s volume is
/// always initialized to 0. [muted] — the media's own stored `muted` flag
/// (issue #194's product decision) — decides whether an unmute affordance
/// is offered at all: when true, the uploader's own choice was silence, so
/// the toggle is never shown and this view stays silent for the whole
/// playback; when false, the uploader opted the video into audio and the
/// viewer may unmute (and re-mute) while watching.
class _FullScreenVideo extends StatefulWidget {
  const _FullScreenVideo({required this.url, required this.muted});

  final String url;
  final bool muted;

  @override
  State<_FullScreenVideo> createState() => _FullScreenVideoState();
}

class _FullScreenVideoState extends State<_FullScreenVideo> {
  late final VideoPlayerController _controller;
  late final Future<void> _initialize;
  bool _unmuted = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _initialize = _controller.initialize().then((_) {
      _controller.setLooping(true);
      _controller.setVolume(0);
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

  void _toggleMute() {
    if (widget.muted || !_controller.value.isInitialized) return;
    setState(() {
      _unmuted = !_unmuted;
      _controller.setVolume(_unmuted ? 1 : 0);
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
          // The unmute affordance only ever appears when the uploader's own
          // stored choice (issue #194) allows it — a muted video never
          // offers a way around that from the viewer side.
          if (!widget.muted)
            Positioned(
              top: AppSpacing.s3,
              right: AppSpacing.s4,
              child: SafeArea(
                child: Material(
                  color: Colors.white.withValues(alpha: 0.14),
                  shape: const CircleBorder(),
                  child: IconButton(
                    onPressed: _toggleMute,
                    tooltip: _unmuted ? 'Sesi kapat' : 'Sesi aç',
                    icon: Icon(
                      _unmuted ? Icons.volume_up : Icons.volume_off,
                      color: Colors.white,
                    ),
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

/// The shared "bildir" affordance (issue #233) for a cat, an update, or a
/// media item — a `more_vert` icon opening [ReportSheet], mirroring
/// [_CorrectionMenuButton]'s exact single-action shape and `kTapMin`-square
/// tap target.
class _ReportButton extends ConsumerWidget {
  const _ReportButton({
    required this.targetType,
    required this.targetId,
    required this.tooltip,
    this.iconSize = 18,
    this.blockUserId,
    this.blockDisplayName,
    this.evictCatId,
  });

  final ReportTargetType targetType;
  final String targetId;
  final String tooltip;
  final double iconSize;

  /// The account behind this content — the cat's owner, the update's author,
  /// the media's uploader (issue #234). Null when it is unknown (a seed cat,
  /// content predating accounts) or when it is the caller themselves, and
  /// then this stays the single-action report button it has always been.
  final String? blockUserId;
  final String? blockDisplayName;

  /// Set on the cat-detail header only: blocking the owner makes this very
  /// cat unreachable, so on success the screen goes back and the map and
  /// discover caches drop it in place. Invalidating those providers instead
  /// would empty their screens rather than refresh them (issue #230). The
  /// owner's *other* cats disappear on those screens' next fetch — the
  /// server is already filtering them by then.
  final String? evictCatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final icon = Icon(Icons.more_vert, size: iconSize, color: AppColors.faint);

    if (blockUserId == null) {
      return SizedBox(
        width: kTapMin,
        height: kTapMin,
        child: IconButton(
          padding: EdgeInsets.zero,
          iconSize: iconSize,
          icon: icon,
          tooltip: tooltip,
          onPressed: () => openReportSheet(
            context,
            ref,
            targetType: targetType,
            targetId: targetId,
          ),
        ),
      );
    }

    return SizedBox(
      width: kTapMin,
      height: kTapMin,
      child: PopupMenuButton<_ContentAction>(
        padding: EdgeInsets.zero,
        tooltip: tooltip,
        icon: icon,
        iconSize: iconSize,
        onSelected: (action) => switch (action) {
          _ContentAction.report => openReportSheet(
            context,
            ref,
            targetType: targetType,
            targetId: targetId,
          ),
          _ContentAction.block => confirmAndBlock(
            context,
            ref,
            userId: blockUserId!,
            displayName: blockDisplayName,
            onBlocked: evictCatId == null
                ? null
                : () {
                    ref.read(catsMapProvider.notifier).removeCat(evictCatId!);
                    ref.read(discoverProvider.notifier).removeCat(evictCatId!);
                    context.pop();
                  },
          ),
        },
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: _ContentAction.report,
            child: Text('Şikayet et'),
          ),
          PopupMenuItem(value: _ContentAction.block, child: Text('Engelle')),
        ],
      ),
    );
  }
}

/// The two actions the "⋮" menu offers on someone else's content (issue
/// #234). Reporting flags one item for review; blocking hides every cat the
/// account owns — deliberately different scopes, which is why they are two
/// entries and not one.
enum _ContentAction { report, block }

/// The state a just-created cat lands in — the highest-intent moment on
/// this screen, and the one it used to answer with a grey row reading
/// "Henüz güncelleme yok" beside a glyph that means *history disabled*.
///
/// The contract is explicit (docs/design/app-states.md, global rules): an
/// empty state is an invitation, not a failure; the title says what
/// happened, the sub-line says why it matters, and there is exactly one
/// primary action. Shape and proportions follow discover's own
/// `_EmptyFollows`, which already ships this contract, rather than a new
/// treatment.
///
/// Its action is the same door the fixed `+ update` bar opens — the same
/// auth gate, the same draft reset — never a second path onto the same
/// mutation.
class _EmptyHistory extends ConsumerWidget {
  const _EmptyHistory({required this.catId});

  final String catId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s4,
        AppSpacing.s5,
        AppSpacing.s4,
        AppSpacing.s6,
      ),
      child: Column(
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              shape: BoxShape.circle,
            ),
            child: SizedBox(
              width: 88,
              height: 88,
              child: Icon(Icons.edit_note, size: 34, color: AppColors.faint),
            ),
          ),
          const SizedBox(height: AppSpacing.s5),
          Text(
            'henüz güncelleme yok',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontSize: 21, height: 1.3),
          ),
          const SizedBox(height: AppSpacing.s3),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: const Text(
              'ilk güncellemeyi sen ekle; bu kediye bakan herkes '
              'durumunu bilsin.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.faint,
                height: 1.6,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s5),
          // Quiet, not brick. The contract allows one primary per state and
          // the fixed "+ update" bar below is already it — a second brick
          // button stacked directly above it, opening the same composer,
          // read as the same button printed twice. The invitation lives in
          // the copy; this is the shortcut to it.
          Material(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              onTap: () => openCatUpdateComposer(context, ref, catId),
              child: Container(
                constraints: const BoxConstraints(minHeight: kTapMin),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s5,
                  vertical: AppSpacing.s3,
                ),
                child: const Text(
                  'güncelleme ekle',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: AppColors.muted,
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
            ? const InlineSpinner(
                size: 18,
                color: AppColors.primary,
                trackColor: AppColors.line,
              )
            : const Text(
                'Daha fazla göster',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
      ),
    );
  }
}

/// Not-found / generic-error screen — no photo hero yet, so the back
/// action gets its own small top-left circle instead of the hero's
/// on-photo one. The initial read is not routed here: waiting is never a
/// bare spinner screen (docs/design/app-states.md), it is
/// [_DetailSkeleton].
class _MessageScreen extends StatelessWidget {
  const _MessageScreen({
    this.icon,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData? icon;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Center(
          child: Padding(
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

/// The cat-detail initial read (docs/design/app-states.md, state 14).
///
/// Replaces the bare centred spinner this screen used to show, which broke
/// two rules of the state contract at once: waiting is never a spinner
/// screen, and nothing loading-related may appear before 400 ms. Here the
/// screen's own future layout stands in for itself, and [InitialReadGate]
/// owns when it may appear.
///
/// The header is deliberately outside the gate. It carries the photo the
/// map's preview sheet is flying across (core/motion/hero_tags.dart), and a
/// shared element needs its destination present in the first frame — a
/// header withheld for 400 ms would give the flight nothing to land on.
/// Showing it immediately costs nothing either way: it is the one piece of
/// this screen already known before the request resolves.
///
/// The photo comes from the map's already-fetched marker for this cat, not
/// from a new request or an invented placeholder. Opened from anywhere else
/// — discover, a deep link — there is no marker and the avatar renders as
/// the branded placeholder, exactly as it would for a cat with no photo.
class _DetailSkeleton extends ConsumerStatefulWidget {
  const _DetailSkeleton({required this.catId});

  final String catId;

  @override
  ConsumerState<_DetailSkeleton> createState() => _DetailSkeletonState();
}

class _DetailSkeletonState extends ConsumerState<_DetailSkeleton> {
  static const double _diameter = 132;

  /// Bumped on retry so the gate remounts and earns a fresh 400 ms of
  /// silence, mirroring the map's own attempt counter — without it the
  /// gate would still be sitting in its timed-out phase and the skeleton
  /// would never return.
  int _attempt = 0;

  void _retry() {
    setState(() => _attempt++);
    ref.read(catDetailProvider(widget.catId).notifier).load();
  }

  @override
  Widget build(BuildContext context) {
    final catId = widget.catId;
    final photo = ref.watch(
      catsMapProvider.select((state) {
        for (final marker in state.markers) {
          if (marker.id == catId) return marker.primaryPhoto;
        }
        return null;
      }),
    );
    final hasPhoto = photo != null && photo.isNotEmpty;

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.s4,
            MediaQuery.of(context).padding.top + AppSpacing.s3,
            AppSpacing.s4,
            0,
          ),
          child: Column(
            children: [
              const Row(children: [_BackCircleButton()]),
              const SizedBox(height: AppSpacing.s4),
              Hero(
                tag: catPhotoHeroTag(catId),
                flightShuttleBuilder: (_, animation, direction, _, _) =>
                    _CatPhotoFlight(
                      animation: animation,
                      direction: direction,
                      photo: hasPhoto ? photo : null,
                    ),
                child: ClipOval(
                  child: SizedBox(
                    width: _diameter,
                    height: _diameter,
                    child: hasPhoto
                        ? CachedNetworkImage(
                            imageUrl: photo,
                            fit: BoxFit.cover,
                            memCacheWidth: decodeWidthFor(context, _diameter),
                            placeholder: (context, _) =>
                                const _HeroPlaceholder(loading: true),
                            errorWidget: (context, _, _) =>
                                const _HeroPlaceholder(),
                          )
                        : const _HeroPlaceholder(loading: true),
                  ),
                ),
              ),
            ],
          ),
        ),
        InitialReadGate(
          key: ValueKey(_attempt),
          reading: true,
          builder: (context, phase) {
            // 6 s+: "the wait ends: switch to the error or offline state"
            // (docs/design/app-states.md, timing contract). Bounded reads
            // only — the request is never cancelled, the wait is what
            // ends, so a late response still lands and replaces this. The
            // header above stays put, exactly as the map keeps its ground
            // visible behind its own fallback banner.
            if (phase == InitialReadPhase.timedOut) {
              return _ReadTimeoutNotice(onRetry: _retry);
            }
            if (phase == InitialReadPhase.hidden) {
              return const SizedBox.shrink();
            }
            return const _DetailSkeletonBody();
          },
        ),
      ],
    );
  }
}

/// The skeleton's shape below the header: the name line, the three-question
/// strip, and the first timeline rows — the screen's real layout drawn as
/// blocks, so the content that arrives replaces something the same size
/// rather than pushing a spinner out of the way.
/// The initial read's 6 s fallback (docs/design/app-states.md, timing
/// contract): the wait ends and the surface switches to its error state.
///
/// Reuses the copy and the single action the screen's own load failure
/// already uses, because to the reader these are the same situation — the
/// cat did not arrive. Nothing here cancels the request: the contract ends
/// the wait, not the read, so a response arriving at 8 s still replaces
/// this with the real screen.
class _ReadTimeoutNotice extends StatelessWidget {
  const _ReadTimeoutNotice({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s5,
        AppSpacing.s8,
        AppSpacing.s5,
        AppSpacing.s6,
      ),
      child: Column(
        children: [
          const Icon(Icons.error_outline, size: 40, color: AppColors.faint),
          const SizedBox(height: AppSpacing.s3),
          const Text(
            'Kedi yüklenemedi',
            style: TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: AppSpacing.s3),
          OutlinedButton(
            onPressed: onRetry,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.ink,
              side: const BorderSide(color: AppColors.lineStrong),
              minimumSize: const Size(0, kTapMin),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
            ),
            child: const Text('Tekrar dene'),
          ),
        ],
      ),
    );
  }
}

class _DetailSkeletonBody extends StatelessWidget {
  const _DetailSkeletonBody();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s5,
        AppSpacing.s5,
        AppSpacing.s5,
        AppSpacing.s6,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SkeletonBlock(width: 168, height: 24),
          const SizedBox(height: AppSpacing.s2),
          const _SkeletonBlock(width: 104, height: 13),
          const SizedBox(height: AppSpacing.s5),
          const Row(
            children: [
              Expanded(child: _SkeletonBlock(height: 52)),
              SizedBox(width: AppSpacing.s2),
              Expanded(
                child: _SkeletonBlock(
                  height: 52,
                  delay: Duration(milliseconds: 120),
                ),
              ),
              SizedBox(width: AppSpacing.s2),
              Expanded(
                child: _SkeletonBlock(
                  height: 52,
                  delay: Duration(milliseconds: 240),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s5),
          const _SkeletonBlock(height: kTapMin, radius: AppRadius.lg),
          const SizedBox(height: AppSpacing.s5),
          // Three timeline rows, staggered so the list does not flash in
          // lockstep (ShimmerSweep's own convention).
          for (var i = 0; i < 3; i++) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SkeletonBlock(
                  width: 34,
                  height: 34,
                  radius: AppRadius.full,
                  delay: Duration(milliseconds: 160 * i),
                ),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SkeletonBlock(
                        width: 96,
                        height: 12,
                        delay: Duration(milliseconds: 160 * i),
                      ),
                      const SizedBox(height: AppSpacing.s2),
                      _SkeletonBlock(
                        height: 14,
                        delay: Duration(milliseconds: 160 * i),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s5),
          ],
        ],
      ),
    );
  }
}

/// One skeleton shape: the app's own [AppColors.surfaceAlt] under the
/// shared [ShimmerSweep], never a generic grey box.
class _SkeletonBlock extends StatelessWidget {
  const _SkeletonBlock({
    this.width,
    required this.height,
    this.radius = AppRadius.sm,
    this.delay = Duration.zero,
  });

  final double? width;
  final double height;
  final double radius;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    return ShimmerSweep(
      delay: delay,
      borderRadius: borderRadius,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: borderRadius,
        ),
      ),
    );
  }
}

/// What actually flies between the map's preview sheet and this screen.
///
/// The default shuttle carries the source widget unchanged, which would
/// mean the sheet's rounded square growing to 132 pt and only then becoming
/// a circle. This draws the photo itself and interpolates the corner radius
/// from the sheet's [AppRadius.lg] to a full circle across the flight, so
/// the shape change is part of the travel rather than a cut at the end.
///
/// Reversed on pop, so returning to the map runs the same change backwards
/// instead of a second, differently-shaped animation.
class _CatPhotoFlight extends StatelessWidget {
  const _CatPhotoFlight({
    required this.animation,
    required this.direction,
    required this.photo,
  });

  final Animation<double> animation;
  final HeroFlightDirection direction;
  final String? photo;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The flight's own rect drives the target radius: "a circle" is
        // half of whatever side the photo currently occupies, so this stays
        // correct if either end is ever resized.
        final side = math.min(constraints.maxWidth, constraints.maxHeight);
        final circle = side / 2;
        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final progress = direction == HeroFlightDirection.push
                ? animation.value
                : 1 - animation.value;
            final t = TekirMotion.enter.transform(progress.clamp(0.0, 1.0));
            return ClipRRect(
              borderRadius: BorderRadius.circular(
                AppRadius.lg + (circle - AppRadius.lg) * t,
              ),
              child: child,
            );
          },
          child: photo == null
              ? const _HeroPlaceholder()
              : CachedNetworkImage(
                  imageUrl: photo!,
                  fit: BoxFit.cover,
                  errorWidget: (context, _, _) => const _HeroPlaceholder(),
                ),
        );
      },
    );
  }
}
