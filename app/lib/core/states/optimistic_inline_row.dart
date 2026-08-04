import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'inline_spinner.dart';

/// Whether an optimistic inline entry is still submitting or has failed.
enum InlineSaveStatus { saving, failed }

/// The shared optimistic inline row (docs/design/app-states.md, mutation
/// affordances): the entry drops into the list immediately and submits
/// in the background — "su verdin · kaydediliyor". On failure the row
/// turns to the help palette; it never disappears. The caller owns the
/// copy and keeps the row mounted in both states.
class OptimisticInlineRow extends StatelessWidget {
  const OptimisticInlineRow({
    super.key,
    required this.label,
    required this.status,
    this.leading,
  });

  /// The full row text, e.g. "su verdin · kaydediliyor".
  final String label;

  final InlineSaveStatus status;

  /// Optional thumbnail slot, sized by the caller.
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final failed = status == InlineSaveStatus.failed;
    return Container(
      constraints: const BoxConstraints(minHeight: kTapMin),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s3,
      ),
      decoration: BoxDecoration(
        color: failed ? AppColors.helpSoft : AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: AppSpacing.s3),
          ],
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: failed ? AppColors.helpStrong : AppColors.faint,
              ),
            ),
          ),
          if (!failed) ...[
            const SizedBox(width: AppSpacing.s3),
            const InlineSpinner(
              size: 15,
              color: AppColors.primaryStrong,
              trackColor: AppColors.line,
            ),
          ],
        ],
      ),
    );
  }
}
