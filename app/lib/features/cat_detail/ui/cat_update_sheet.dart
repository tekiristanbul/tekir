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
                  children: catUpdateStatusOptions.map((status) {
                    return _StatusOption(
                      label: _statusLabelsTr[status]!,
                      selected: state.selectedStatuses.contains(status),
                      onTap: () => ref
                          .read(
                            catUpdateComposerProvider(widget.catId).notifier,
                          )
                          .toggleStatus(status),
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
                      .read(catUpdateComposerProvider(widget.catId).notifier)
                      .setComment(value),
                  decoration: InputDecoration(
                    hintText: 'Bir not ekle',
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
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.primaryInk,
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
                              color: AppColors.primaryInk,
                            ),
                          )
                        : const Text('Paylaş'),
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
