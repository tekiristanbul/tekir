import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
        _HeroPhoto(detail: detail),
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
              if (detail.lastUpdateAt != null) ...[
                _LastUpdateRow(time: detail.lastUpdateAt!),
                const SizedBox(height: AppSpacing.s4),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: FollowButton(catId: detail.id, source: openSource),
              ),
              const SizedBox(height: AppSpacing.s6),
              Text(
                'Son güncellemeler',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.s2),
              if (pending != null) ...[
                OptimisticInlineRow(
                  label: optimisticUpdateLabelTr(pending),
                  status: pending.status,
                ),
                const SizedBox(height: AppSpacing.s3),
              ],
              if (state.updates.isEmpty && pending == null)
                const _EmptyHistory()
              else if (state.updates.isNotEmpty) ...[
                for (var i = 0; i < state.updates.length; i++)
                  _TimelineItem(
                    catId: detail.id,
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

/// The cover photo (binding design docs/design/screens/cat-profile.html):
/// full width at a fixed 16:9, controlled crop (`cover`) — the ratio is
/// never distorted and the height never depends on the source image.
/// Tapping it opens the uncropped full-screen view; the design marks
/// tappability with a media counter, but its count must come from a real
/// total whose source field the design leaves unverified ("açık kalan"),
/// so no counter is rendered yet.
class _HeroPhoto extends StatelessWidget {
  const _HeroPhoto({required this.detail});

  final CatDetail detail;

  @override
  Widget build(BuildContext context) {
    final photo = detail.primaryPhoto;
    return AspectRatio(
      aspectRatio: 16 / 9,
      // The detector wraps the whole cover so the tap target isn't blocked
      // by the scrim overlay; the back button's own InkWell still wins its
      // area of the stack.
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
      ),
    );
  }

  /// The full-screen view (binding design, frame D): dark surface, the
  /// photo `contain`ed with no crop, a single close action. "ana fotoğraf
  /// yap" belongs to the media archive's per-update items and its media
  /// api — out of 0.2 scope — so the cover's own view carries no action
  /// but closing.
  void _openFullScreen(BuildContext context, String photo) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _FullScreenPhoto(photo: photo),
      ),
    );
  }
}

class _FullScreenPhoto extends StatelessWidget {
  const _FullScreenPhoto({required this.photo});

  final String photo;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141010),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: CachedNetworkImage(
              imageUrl: photo,
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
          // Wraps instead of overflowing when the label outgrows the pill
          // (large text scale on a narrow phone — app-states global rules).
          Flexible(
            child: Text(
              'Son güncelleme: ${relativeTimeTr(time)}',
              style: const TextStyle(fontSize: 13, color: AppColors.muted),
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
                ],
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
