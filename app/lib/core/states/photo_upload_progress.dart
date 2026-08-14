import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The photo-upload overlay (docs/design/app-states.md, mutation
/// affordances) — the only place a percentage is shown anywhere in the
/// app; no other progress bar exists. Rendered on top of the photo being
/// uploaded: a dark scrim, the percentage top-left, a thin bar along the
/// bottom. The 6 s read fallback never cancels this upload.
class PhotoUploadProgress extends StatelessWidget {
  const PhotoUploadProgress({
    super.key,
    required this.progress,
    this.checking = false,
  });

  /// Upload progress in 0..1; values outside the range are clamped.
  final double progress;

  /// True once the file itself has fully left the device but the request
  /// hasn't resolved yet — the same in-flight request is now waiting on the
  /// server's own work (issue #241's pre-publication content check, among
  /// anything else the endpoint does before answering). There is no
  /// separate request or polling for this: it's the tail of the same
  /// upload, so the bar stays full and only the label swaps from a
  /// percentage to "kontrol ediliyor" — never a new screen or a full-screen
  /// block.
  final bool checking;

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
            checking ? 'kontrol ediliyor' : '%${(value * 100).round()}',
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
