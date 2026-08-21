import 'package:flutter/material.dart';

import 'initial_read_gate.dart';
import 'shimmer_sweep.dart';
import '../theme/app_theme.dart';

/// One skeleton shape: the app's own [AppColors.surfaceAlt] under the
/// shared [ShimmerSweep], never a generic grey box.
class SkeletonBone extends StatelessWidget {
  const SkeletonBone({
    super.key,
    this.width,
    required this.height,
    this.radius = AppRadius.sm,
    this.delay = Duration.zero,
  });

  final double? width;
  final double height;
  final double radius;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    return ShimmerSweep(
      delay: delay,
      borderRadius: borderRadius,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: borderRadius,
        ),
      ),
    );
  }
}

/// The generic initial-read skeleton for a screen whose content is a list
/// of rows: notifications, badges, blocked accounts, profile.
///
/// The contract is blunt about it (docs/design/app-states.md): "waiting is
/// never shown as a bare spinner screen: the screen's future layout stands
/// in as a skeleton, and small spinners appear only inside buttons and
/// inline rows." Eight screens shipped a centred spinner instead. Discover
/// already had a real skeleton with its own row geometry; this is for the
/// rest, whose rows are close enough in shape to share one.
///
/// Rows fade in decreasing opacity with a staggered shimmer, matching
/// discover's own treatment so the app has one waiting language rather
/// than two.
class ReadListSkeleton extends StatelessWidget {
  const ReadListSkeleton({
    super.key,
    this.rowCount = 5,
    this.hasLeading = true,
    this.rowHeight = 44,
  });

  /// How many rows stand in. Enough to fill a phone screen; more would
  /// only shimmer below the fold.
  final int rowCount;

  /// Whether the real row starts with a round avatar or icon disc.
  final bool hasLeading;

  final double rowHeight;

  static const _opacities = [1.0, 0.87, 0.74, 0.61, 0.48, 0.35];
  static const _titleFractions = [0.62, 0.48, 0.70, 0.54, 0.44, 0.60];

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s5,
          vertical: AppSpacing.s3,
        ),
        physics: const NeverScrollableScrollPhysics(),
        itemCount: rowCount,
        separatorBuilder: (_, _) =>
            const Divider(height: 1, color: AppColors.line),
        itemBuilder: (context, index) => Opacity(
          opacity: _opacities[index % _opacities.length],
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
            child: Row(
              children: [
                if (hasLeading) ...[
                  SkeletonBone(
                    width: rowHeight,
                    height: rowHeight,
                    radius: AppRadius.full,
                    delay: Duration(milliseconds: 120 * index),
                  ),
                  const SizedBox(width: AppSpacing.s3),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor:
                            _titleFractions[index % _titleFractions.length],
                        child: SkeletonBone(
                          height: 13,
                          delay: Duration(milliseconds: 120 * index),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s2),
                      FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: 0.35,
                        child: SkeletonBone(
                          height: 11,
                          delay: Duration(milliseconds: 120 * index),
                        ),
                      ),
                    ],
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

/// [ReadListSkeleton] behind the shared timing gate, for the common case:
/// a screen that is doing its initial read and has an error state to fall
/// back to at 6 s.
///
/// Wraps the two rules that always travel together — nothing before
/// 400 ms, and the wait ends at 6 s — so a screen adopting the contract
/// gets both rather than the half it remembered.
class GatedReadSkeleton extends StatefulWidget {
  const GatedReadSkeleton({
    super.key,
    required this.onRetry,
    required this.timedOutBuilder,
    this.rowCount = 5,
    this.hasLeading = true,
  });

  /// Re-runs the read behind this skeleton, for the 6 s fallback's action.
  final VoidCallback onRetry;

  /// The screen's own error state, shown once the wait ends. Passed rather
  /// than built here: each screen already has one, and inventing a second
  /// would give the same failure two different faces.
  final Widget Function(BuildContext context, VoidCallback onRetry)
  timedOutBuilder;

  final int rowCount;
  final bool hasLeading;

  @override
  State<GatedReadSkeleton> createState() => _GatedReadSkeletonState();
}

class _GatedReadSkeletonState extends State<GatedReadSkeleton> {
  /// Bumped on retry so the gate remounts and earns a fresh 400 ms of
  /// silence — without it the gate would still be sitting in its timed-out
  /// phase and the skeleton would never come back.
  int _attempt = 0;

  void _retry() {
    setState(() => _attempt++);
    widget.onRetry();
  }

  @override
  Widget build(BuildContext context) {
    return InitialReadGate(
      key: ValueKey(_attempt),
      reading: true,
      builder: (context, phase) {
        // 6 s+: the wait ends and the surface switches to its error state.
        // The read is never cancelled — this applies to bounded reads, and
        // the contract ends the wait, not the request.
        if (phase == InitialReadPhase.timedOut) {
          return widget.timedOutBuilder(context, _retry);
        }
        if (phase == InitialReadPhase.hidden) return const SizedBox.shrink();
        return ReadListSkeleton(
          rowCount: widget.rowCount,
          hasLeading: widget.hasLeading,
        );
      },
    );
  }
}
