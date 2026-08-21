import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/analytics/analytics.dart';
import '../../../core/states/submitting_button.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/ui/auth_gate.dart';
import 'report_notifier.dart';
import 'report_reason.dart';

/// The reporting sheet for a cat/update/media target (issue #233). No
/// prototype screen exists for this flow — built on the same shell
/// [UpdateCorrectionSheet] already established: drag handle, title row
/// with a close button, an inline error banner, and a submitting-state
/// submit button. The reason picker is a vertical list (not
/// [UpdateCorrectionSheet]'s `Wrap` of pills) since only one reason may be
/// selected at a time and "spam / tekrar eden icerik" / "kisisel gizlilik
/// ihlali" are too long to read comfortably as short pills.
class ReportSheet extends ConsumerWidget {
  const ReportSheet({
    super.key,
    required this.targetType,
    required this.targetId,
  });

  final ReportTargetType targetType;
  final String targetId;

  ({ReportTargetType targetType, String targetId}) get _key =>
      (targetType: targetType, targetId: targetId);

  Future<void> _submit(BuildContext context, WidgetRef ref) async {
    final ok = await ref.read(reportProvider(_key).notifier).submit();
    if (ok && context.mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(reportProvider(_key));
    final noteRequired = state.reason == ReportReason.other;

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
                const Center(child: _ReportDragHandle()),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'İçeriği bildir',
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
                const SizedBox(height: AppSpacing.s2),
                const Text(
                  'Neden',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: AppSpacing.s2),
                for (final reason in ReportReason.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.s2),
                    child: _ReasonOption(
                      label: reason.labelTr,
                      helperText: reportReasonHelperTextTr(reason),
                      selected: state.reason == reason,
                      enabled: !state.isSubmitting,
                      onTap: () => ref
                          .read(reportProvider(_key).notifier)
                          .selectReason(reason),
                    ),
                  ),
                const SizedBox(height: AppSpacing.s2),
                Text(
                  noteRequired ? 'Not (zorunlu)' : 'Not (opsiyonel)',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: AppSpacing.s2),
                TextField(
                  enabled: !state.isSubmitting,
                  minLines: 2,
                  maxLines: 4,
                  onChanged: (value) =>
                      ref.read(reportProvider(_key).notifier).setNote(value),
                  decoration: InputDecoration(
                    hintText: 'Kısaca açıkla',
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
                  _ReportErrorBanner(
                    message: reportSubmitErrorMessageTr(state.error!),
                  ),
                ],
                const SizedBox(height: AppSpacing.s4),
                SubmittingButton(
                  label: 'Gönder',
                  submittingLabel: 'Gönderiliyor',
                  submitting: state.isSubmitting,
                  onPressed: state.canSubmit
                      ? () => _submit(context, ref)
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReportDragHandle extends StatelessWidget {
  const _ReportDragHandle();

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

class _ReasonOption extends StatelessWidget {
  const _ReasonOption({
    required this.label,
    required this.helperText,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final String? helperText;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.primarySoft : AppColors.surfaceAlt,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: enabled ? onTap : null,
        child: Container(
          constraints: const BoxConstraints(minHeight: kTapMin),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s3,
            vertical: AppSpacing.s2,
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
                color: selected ? AppColors.primaryStrong : AppColors.faint,
              ),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: selected
                            ? AppColors.primaryStrong
                            : AppColors.ink,
                      ),
                    ),
                    if (helperText != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          helperText!,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.faint,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReportErrorBanner extends StatelessWidget {
  const _ReportErrorBanner({required this.message});

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

/// Gates the report sheet behind [AuthGate] (issue #233: reporting requires
/// an authenticated account, same as following or posting an update), then
/// opens it and shows the confirmation toast on success — mirrors
/// [openUpdateCorrectionSheet]'s pop-then-toast shape, from a context that
/// outlives the sheet.
Future<void> openReportSheet(
  BuildContext context,
  WidgetRef ref, {
  required ReportTargetType targetType,
  required String targetId,
}) {
  return AuthGate.require(
    context,
    ref,
    contextText: 'İçeriği bildirmek için giriş yap',
    intent: AnalyticsAuthIntent.report,
    onAuthenticated: () => unawaited(
      _openReportSheetAuthenticated(
        context,
        targetType: targetType,
        targetId: targetId,
      ),
    ),
  );
}

Future<void> _openReportSheetAuthenticated(
  BuildContext context, {
  required ReportTargetType targetType,
  required String targetId,
}) async {
  final submitted = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (_) => ReportSheet(targetType: targetType, targetId: targetId),
  );
  if (submitted == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Bildirimin alındı, teşekkürler.')),
    );
  }
}
