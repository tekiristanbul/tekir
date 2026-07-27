import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../data/cat_detail.dart';
import 'update_correction_notifier.dart';

const _statusLabelsTr = {
  'seen': 'Görüldü',
  'fed': 'Mama verildi',
  'water_provided': 'Su verildi',
};

/// The correction/delete sheet for the caller's own ordinary update, within
/// its fixed 10-minute window (issue #80, docs/product/updates.md). No
/// prototype screen exists for this flow — it's an original design
/// grounded in this app's existing idioms: [CatUpdateSheet]'s shell/status
/// pills and [NeedsHelpSheet]'s inline-error-banner pattern. Pops an
/// [UpdateCorrectionOutcome] on success so the caller (the timeline's "⋮"
/// affordance) shows the right toast from a context that outlives this
/// sheet, mirroring both of those sheets' own pop-then-toast convention.
class UpdateCorrectionSheet extends ConsumerStatefulWidget {
  const UpdateCorrectionSheet({
    super.key,
    required this.catId,
    required this.entry,
  });

  final String catId;
  final CatUpdateEntry entry;

  @override
  ConsumerState<UpdateCorrectionSheet> createState() =>
      _UpdateCorrectionSheetState();
}

class _UpdateCorrectionSheetState extends ConsumerState<UpdateCorrectionSheet> {
  Timer? _ticker;
  late final TextEditingController _commentController;

  ({String catId, String updateId}) get _key =>
      (catId: widget.catId, updateId: widget.entry.id);

  @override
  void initState() {
    super.initState();
    _commentController = TextEditingController(
      text: widget.entry.comment ?? '',
    );
    Future.microtask(
      () =>
          ref.read(updateCorrectionProvider(_key).notifier).seed(widget.entry),
    );
    // Refreshes the countdown chip once a minute — no need for
    // second-level precision on a 10-minute window, and a coarser tick
    // means far fewer rebuilds while the sheet is open.
    _ticker = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _commentController.dispose();
    super.dispose();
  }

  bool get _isExpired => !widget.entry.isCorrectionOpen();

  String get _countdownLabel {
    final expiresAt = widget.entry.correctionExpiresAt;
    if (expiresAt == null) return '';
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.isNegative) return 'Düzeltme süresi doldu';
    final minutes = remaining.inMinutes;
    if (minutes < 1) return 'Düzeltme için birazdan süre doluyor';
    return 'Düzeltme için $minutes dakikan kaldı';
  }

  Future<void> _save() async {
    final outcome = await ref
        .read(updateCorrectionProvider(_key).notifier)
        .save();
    if (outcome != null && mounted) Navigator.of(context).pop(outcome);
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Güncellemeyi sil'),
        content: const Text(
          'Bu güncellemeyi silmek istediğine emin misin? Bu işlem geri alınamaz.',
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

    final outcome = await ref
        .read(updateCorrectionProvider(_key).notifier)
        .delete();
    if (outcome != null && mounted) Navigator.of(context).pop(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(updateCorrectionProvider(_key));
    final expired = _isExpired || state.error == UpdateCorrectionError.expired;
    final actionsDisabled = expired || state.isSubmitting;

    return Padding(
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
                        'Güncellemeyi düzelt',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                      tooltip: 'Kapat',
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.s1),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s3,
                    vertical: AppSpacing.s2,
                  ),
                  decoration: BoxDecoration(
                    color: expired
                        ? AppColors.surfaceAlt
                        : AppColors.primarySoft,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.timer_outlined,
                        size: 16,
                        color: expired
                            ? AppColors.faint
                            : AppColors.primaryStrong,
                      ),
                      const SizedBox(width: AppSpacing.s2),
                      Flexible(
                        child: Text(
                          _countdownLabel,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: expired
                                ? AppColors.muted
                                : AppColors.primaryStrong,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.s4),
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
                  children: _statusLabelsTr.keys.map((status) {
                    return _StatusOption(
                      label: _statusLabelsTr[status]!,
                      selected: state.statuses.contains(status),
                      enabled: !actionsDisabled,
                      onTap: () => ref
                          .read(updateCorrectionProvider(_key).notifier)
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
                  controller: _commentController,
                  enabled: !actionsDisabled,
                  minLines: 2,
                  maxLines: 4,
                  onChanged: (value) => ref
                      .read(updateCorrectionProvider(_key).notifier)
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
                if (state.error != null || expired) ...[
                  const SizedBox(height: AppSpacing.s3),
                  _ErrorBanner(
                    message: state.error != null
                        ? updateCorrectionErrorMessageTr(state.error!)
                        : updateCorrectionErrorMessageTr(
                            UpdateCorrectionError.expired,
                          ),
                  ),
                ],
                const SizedBox(height: AppSpacing.s4),
                SizedBox(
                  height: kTapMin,
                  child: ElevatedButton(
                    onPressed: (state.canSubmit && !actionsDisabled)
                        ? _save
                        : null,
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
                        : Text(
                            state.error != null &&
                                    state.error !=
                                        UpdateCorrectionError.expired &&
                                    state.error !=
                                        UpdateCorrectionError.notAuthor
                                ? 'Tekrar dene'
                                : 'Kaydet',
                          ),
                  ),
                ),
                const SizedBox(height: AppSpacing.s2),
                SizedBox(
                  height: kTapMin,
                  child: OutlinedButton(
                    onPressed: actionsDisabled ? null : _confirmDelete,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.help,
                      side: const BorderSide(color: AppColors.help),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                    ),
                    child: const Text('Güncellemeyi sil'),
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

class _StatusOption extends StatelessWidget {
  const _StatusOption({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.primarySoft : AppColors.surfaceAlt,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.full),
        onTap: enabled ? onTap : null,
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

/// Opens [UpdateCorrectionSheet] and, on success, shows the matching toast
/// — mirrors [openNeedsHelpSheet]'s pop-then-toast shape exactly.
Future<void> openUpdateCorrectionSheet(
  BuildContext context, {
  required String catId,
  required CatUpdateEntry entry,
}) async {
  final outcome = await showModalBottomSheet<UpdateCorrectionOutcome>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => UpdateCorrectionSheet(catId: catId, entry: entry),
  );
  if (outcome == null || !context.mounted) return;

  final message = switch (outcome) {
    UpdateCorrectionOutcome.saved => 'Güncelleme güncellendi',
    UpdateCorrectionOutcome.deleted => 'Güncelleme silindi',
    UpdateCorrectionOutcome.alreadyGone => 'Bu güncelleme zaten silinmiş',
  };
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
