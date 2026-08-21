import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'inline_spinner.dart';

/// The shared in-place submitting button (docs/design/app-states.md,
/// mutation affordances). While [submitting] is true the button stays in
/// place at a fixed width, its label changes, its color darkens one
/// tone, and a small spinner joins the label. This is a mutation: the
/// 400 ms rule never applies — set [submitting] synchronously in the tap
/// handler so feedback starts in the same frame as the tap.
///
/// Duplicate submissions are prevented here: taps are ignored while
/// [submitting] is true.
class SubmittingButton extends StatelessWidget {
  const SubmittingButton({
    super.key,
    required this.label,
    required this.submittingLabel,
    required this.submitting,
    required this.onPressed,
    this.background = AppColors.primary,
    this.submittingBackground = AppColors.primaryStrong,
    this.foreground = AppColors.primaryInk,
  });

  /// The resting call to action, e.g. "haritaya ekle".
  final String label;

  /// The in-flight label, e.g. "haritaya ekleniyor".
  final String submittingLabel;

  final bool submitting;
  final VoidCallback? onPressed;

  final Color background;

  /// One tone darker than [background], shown while submitting.
  final Color submittingBackground;

  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kTapMin,
      width: double.infinity,
      child: ElevatedButton(
        onPressed: submitting ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          // Two different disabled states share this slot. While
          // submitting, the button keeps its own colours and only darkens.
          // Genuinely disabled, it must still be readable: Material's
          // default (onSurface at 38% over lineStrong) lands at 2.09:1,
          // where the label explaining what is missing cannot be read.
          disabledBackgroundColor: submitting
              ? submittingBackground
              : AppColors.surfaceAlt,
          disabledForegroundColor: submitting ? foreground : AppColors.muted,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
        child: submitting
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InlineSpinner(
                    size: 16,
                    color: foreground,
                    trackColor: foreground.withValues(alpha: 0.3),
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  Text(submittingLabel),
                ],
              )
            : Text(label),
      ),
    );
  }
}
