import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import 'cat_update_composer_notifier.dart';

const _statusLabelsTr = {
  'seen': 'Görüldü',
  'fed': 'Mama verildi',
  'water_provided': 'Su verildi',
};

/// Compact multi-status composition flow (issue #43): cat_detail_screen's
/// secondary "Güncelleme ekle" action opens this over the content instead
/// of navigating to a full screen, matching the map's marker-preview sheet
/// pattern (cat_preview_sheet.dart). Pops `true` on a successful
/// submission so the caller shows the lightweight, non-blocking success
/// toast itself, from a context that outlives this sheet.
///
/// Since issue #102 (the #100 simplified help contract), `yardıma ihtiyacı
/// var` is one of the options here — a single help mark beside the status
/// pills, no categories — per the binding design at
/// docs/design/screens/cat-profile.html (frame C): selecting it reveals
/// the takipçilere-bildirim banner, changes the note field's invitation,
/// and turns the submit action into the help-red `yardım çağrısıyla
/// paylaş`.
class CatUpdateSheet extends ConsumerStatefulWidget {
  const CatUpdateSheet({super.key, required this.catId});

  final String catId;

  @override
  ConsumerState<CatUpdateSheet> createState() => _CatUpdateSheetState();
}

class _CatUpdateSheetState extends ConsumerState<CatUpdateSheet> {
  @override
  void initState() {
    super.initState();
    // A previous open dismissed without submitting (or a stale error from
    // one) must not leak into this fresh open.
    Future.microtask(
      () => ref.read(catUpdateComposerProvider(widget.catId).notifier).reset(),
    );
  }

  Future<void> _submit() async {
    final ok = await ref
        .read(catUpdateComposerProvider(widget.catId).notifier)
        .submit();
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(catUpdateComposerProvider(widget.catId));

    return Padding(
      // Keeps the comment field and submit button above the keyboard.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.bgElevated,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.xl),
          ),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s5,
              AppSpacing.s2,
              AppSpacing.s5,
              AppSpacing.s5,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: _DragHandle()),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Güncelleme ekle',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      icon: const Icon(Icons.close),
                      tooltip: 'Kapat',
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.s1),
                const Text(
                  'Durumu seç',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: AppSpacing.s2),
                Wrap(
                  spacing: AppSpacing.s2,
                  runSpacing: AppSpacing.s2,
                  children: [
                    ...catUpdateStatusOptions.map((status) {
                      return _StatusOption(
                        label: _statusLabelsTr[status]!,
                        selected: state.selectedStatuses.contains(status),
                        onTap: () => ref
                            .read(
                              catUpdateComposerProvider(widget.catId).notifier,
                            )
                            .toggleStatus(status),
                      );
                    }),
                    _HelpOption(
                      selected: state.needsHelp,
                      onTap: () => ref
                          .read(
                            catUpdateComposerProvider(widget.catId).notifier,
                          )
                          .toggleNeedsHelp(),
                    ),
                  ],
                ),
                if (state.needsHelp) ...[
                  const SizedBox(height: AppSpacing.s3),
                  const _HelpNotifyBanner(),
                ],
                const SizedBox(height: AppSpacing.s4),
                const Text(
                  'Yorum (opsiyonel)',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: AppSpacing.s2),
                TextField(
                  enabled: !state.isSubmitting,
                  minLines: 2,
                  maxLines: 4,
                  // The 500-character cap applies to the help note only
                  // (docs/product/alerts.md, decision 4) — an ordinary
                  // comment stays uncapped.
                  maxLength: state.needsHelp ? helpNoteMaxLength : null,
                  onChanged: (value) => ref
                      .read(catUpdateComposerProvider(widget.catId).notifier)
                      .setComment(value),
                  decoration: InputDecoration(
                    hintText: state.needsHelp
                        ? 'ne oldu? kısaca yaz — yardıma gelen anlasın'
                        : 'Bir not ekle',
                    filled: true,
                    fillColor: AppColors.surfaceAlt,
                    contentPadding: const EdgeInsets.all(AppSpacing.s3),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                if (state.error != null) ...[
                  const SizedBox(height: AppSpacing.s3),
                  _ErrorBanner(
                    message: updateSubmitErrorMessageTr(state.error!),
                  ),
                ],
                const SizedBox(height: AppSpacing.s4),
                SizedBox(
                  height: kTapMin,
                  child: ElevatedButton(
                    onPressed: state.canSubmit ? _submit : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: state.needsHelp
                          ? AppColors.helpStrong
                          : AppColors.primary,
                      foregroundColor: state.needsHelp
                          ? AppColors.helpInk
                          : AppColors.primaryInk,
                      disabledBackgroundColor: AppColors.lineStrong,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      textStyle: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    child: state.isSubmitting
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: state.needsHelp
                                  ? AppColors.helpInk
                                  : AppColors.primaryInk,
                            ),
                          )
                        : Text(
                            state.error != null
                                ? 'Tekrar dene'
                                : state.needsHelp
                                ? 'yardım çağrısıyla paylaş'
                                : 'Paylaş',
                          ),
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

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 4,
      margin: const EdgeInsets.only(bottom: AppSpacing.s3),
      decoration: BoxDecoration(
        color: AppColors.lineStrong,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
    );
  }
}

/// A toggleable status pill — same bold-pill visual language as the
/// timeline's read-only _StatusTag (cat_detail_screen.dart), but
/// interactive and sized to the 44px minimum touch target.
class _StatusOption extends StatelessWidget {
  const _StatusOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.primarySoft : AppColors.surfaceAlt,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.full),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: kTapMin),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                const Icon(
                  Icons.check,
                  size: 16,
                  color: AppColors.primaryStrong,
                ),
                const SizedBox(width: AppSpacing.s1),
              ],
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: selected ? AppColors.primaryStrong : AppColors.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The single `yardım` mark (binding copy, docs/design/screens/
/// cat-profile.html) — the help color family, never the primary accent,
/// in both states so it always reads apart from the work-done statuses
/// beside it: soft help tint unselected, deep help red selected.
class _HelpOption extends StatelessWidget {
  const _HelpOption({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.helpStrong : AppColors.helpSoft,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.full),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: kTapMin),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: selected ? AppColors.helpInk : AppColors.helpStrong,
              ),
              const SizedBox(width: AppSpacing.s1),
              Flexible(
                child: Text(
                  'yardım',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: selected ? AppColors.helpInk : AppColors.helpStrong,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown only while the help mark is selected: submitting will notify the
/// cat's followers (binding copy). The dot pulses to carry the "this goes
/// out" weight — statically rendered when the platform asks for reduced
/// motion.
class _HelpNotifyBanner extends StatelessWidget {
  const _HelpNotifyBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s3,
      ),
      decoration: BoxDecoration(
        color: AppColors.helpSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: const Row(
        children: [
          _PulsingDot(),
          SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text(
              'takipçilere bildirim gider',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.helpStrong,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Reduced motion: a static dot, no repeating animation at all.
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    if (reduceMotion) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }

    const dot = DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.helpStrong,
        shape: BoxShape.circle,
      ),
      child: SizedBox(width: 8, height: 8),
    );
    if (reduceMotion) return dot;

    return SizedBox(
      width: 8,
      height: 8,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = Curves.easeOut.transform(_controller.value);
              return Transform.scale(
                scale: 0.4 + t * 2.4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.help.withValues(alpha: (1 - t) * 0.5),
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox(width: 8, height: 8),
                ),
              );
            },
          ),
          dot,
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
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
          const Icon(Icons.error_outline, size: 18, color: AppColors.help),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppColors.helpStrong, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
