import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The photo-upload overlay (docs/design/app-states.md, mutation
/// affordances) — the only place a percentage is shown anywhere in the
/// app; no other progress bar exists. Rendered on top of the photo being
/// uploaded: a dark scrim, the percentage top-left, a thin bar along the
/// bottom. The 6 s read fallback never cancels this upload.
class PhotoUploadProgress extends StatelessWidget {
  const PhotoUploadProgress({super.key, required this.progress});

  /// Upload progress in 0..1; values outside the range are clamped.
  final double progress;

  @override
  Widget build(BuildContext context) {
    final value = progress.clamp(0.0, 1.0);
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(decoration: BoxDecoration(color: AppColors.overlay)),
        Positioned(
          left: AppSpacing.s3,
          top: AppSpacing.s3,
          child: Text(
            '%${(value * 100).round()}',
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: AppColors.primaryInk,
            ),
          ),
        ),
        Positioned(
          left: AppSpacing.s3,
          right: AppSpacing.s3,
          bottom: AppSpacing.s3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.full),
            child: SizedBox(
              height: 5,
              child: ColoredBox(
                color: AppColors.primaryInk.withValues(alpha: 0.35),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: value,
                  child: const ColoredBox(color: AppColors.primaryInk),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
