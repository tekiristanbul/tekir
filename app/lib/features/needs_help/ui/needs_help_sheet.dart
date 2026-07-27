import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import 'needs_help_notifier.dart';

/// Needs-help report flow (issue #78): cat_detail_screen's warm "Yardıma
/// ihtiyacı var" callout opens this over the content, mirroring
/// [CatUpdateSheet]'s pattern and the approved prototype's `renderHelp`
/// screen (prototype/app.js:531-560) — same cat header row, body copy,
/// single-select category grid, optional comment, and submit copy. Pops
/// `true` on a successful submission so the caller shows the toast from a
/// context that outlives this sheet. The notification opt-in prompt is a
/// separate, follow-triggered flow (see FollowButton) — the approved
/// prototype/docs/product/notifications.md tie it to following a cat, not
/// to reporting needs-help.
class NeedsHelpSheet extends ConsumerStatefulWidget {
  const NeedsHelpSheet({
    super.key,
    required this.catId,
    required this.catName,
    this.catPhotoUrl,
  });

  final String catId;
  final String catName;
  final String? catPhotoUrl;

  @override
  ConsumerState<NeedsHelpSheet> createState() => _NeedsHelpSheetState();
}

class _NeedsHelpSheetState extends ConsumerState<NeedsHelpSheet> {
  @override
  void initState() {
    super.initState();
    // A previous open dismissed without submitting (or a stale error from
    // one) must not leak into this fresh open.
    Future.microtask(
      () => ref.read(needsHelpProvider(widget.catId).notifier).reset(),
    );
  }

  Future<void> _submit() async {
    final ok = await ref
        .read(needsHelpProvider(widget.catId).notifier)
        .submit();
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(needsHelpProvider(widget.catId));

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
                        'Yardım bildir',
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
                Row(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: AppColors.surfaceAlt,
                      backgroundImage: widget.catPhotoUrl != null
                          ? CachedNetworkImageProvider(widget.catPhotoUrl!)
                          : null,
                      child: widget.catPhotoUrl == null
                          ? const Icon(
                              Icons.pets,
                              size: 14,
                              color: AppColors.muted,
                            )
                          : null,
                    ),
                    const SizedBox(width: AppSpacing.s2),
                    Text(
                      widget.catName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.s3),
                const Text(
                  'Takip edenlere bildirim gider. Bildirim 72 saat sonra kendiliğinden kalkar.',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: AppSpacing.s4),
                const Text(
                  'Durum ne?',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: AppSpacing.s2),
                Wrap(
                  spacing: AppSpacing.s2,
                  runSpacing: AppSpacing.s2,
                  children: needsHelpCategoryOptions.map((option) {
                    return _CategoryOption(
                      option: option,
                      selected: state.category == option.id,
                      onTap: () => ref
                          .read(needsHelpProvider(widget.catId).notifier)
                          .selectCategory(option.id),
                    );
                  }).toList(),
                ),
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
                  onChanged: (value) => ref
                      .read(needsHelpProvider(widget.catId).notifier)
                      .setComment(value),
                  decoration: InputDecoration(
                    hintText: 'Örn. sağ arka ayağını basamıyor…',
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
                    message: needsHelpSubmitErrorMessageTr(state.error!),
                  ),
                ],
                const SizedBox(height: AppSpacing.s4),
                SizedBox(
                  height: kTapMin,
                  child: ElevatedButton(
                    onPressed: state.canSubmit ? _submit : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.help,
                      foregroundColor: AppColors.helpInk,
                      disabledBackgroundColor: AppColors.lineStrong,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      textStyle: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    child: state.isSubmitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.helpInk,
                            ),
                          )
                        : Text(
                            state.error != null
                                ? 'Tekrar dene'
                                : 'Yardım bildirimini gönder',
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

/// Opens [NeedsHelpSheet] and, on a successful submission, shows the
/// success toast. The caller (cat_detail_screen's gated callout) is
/// responsible for running this through [AuthGate] first.
Future<void> openNeedsHelpSheet(
  BuildContext context, {
  required String catId,
  required String catName,
  String? catPhotoUrl,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => NeedsHelpSheet(
      catId: catId,
      catName: catName,
      catPhotoUrl: catPhotoUrl,
    ),
  );
  if (result != true || !context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(const SnackBar(content: Text('Yardım bildirimi paylaşıldı')));
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

/// A single-select category pill — same interactive-pill shape as
/// [CatUpdateSheet]'s `_StatusOption`, but the "warm"/help color family
/// (never the primary accent) and radio (single-select), not checkbox
/// (multi-select), semantics — matching the approved prototype's
/// `status-option.is-warm` treatment.
class _CategoryOption extends StatelessWidget {
  const _CategoryOption({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final NeedsHelpCategoryOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.helpSoft : AppColors.surfaceAlt,
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
                option.icon,
                size: 16,
                color: selected ? AppColors.helpStrong : AppColors.muted,
              ),
              const SizedBox(width: AppSpacing.s1),
              Flexible(
                child: Text(
                  option.label,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: selected ? AppColors.helpStrong : AppColors.muted,
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
