import 'package:flutter/material.dart';

import '../../../core/states/shimmer_sweep.dart';
import '../../../core/theme/app_theme.dart';

/// State 14 · liste iskeleti (docs/design/app-states.md): the discover
/// list's initial-read skeleton. Each row has the real cat row's exact
/// geometry — same 44 px round photo, same vertical padding, same
/// two-line text block and right-aligned meta column — so nothing jumps
/// when data arrives. Rows fade in decreasing opacity with a staggered
/// shimmer; the gate that owns the 400 ms rule decides when this is
/// visible at all.
class DiscoverListSkeleton extends StatelessWidget {
  const DiscoverListSkeleton({super.key});

  static const _opacities = [1.0, 0.87, 0.74, 0.61, 0.48, 0.35];
  static const _nameFractions = [0.62, 0.48, 0.70, 0.54, 0.44, 0.60];

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s5),
        physics: const NeverScrollableScrollPhysics(),
        itemCount: _opacities.length,
        separatorBuilder: (_, _) =>
            const Divider(height: 1, color: AppColors.line),
        itemBuilder: (context, index) => Opacity(
          opacity: _opacities[index],
          child: ShimmerSweep(
            delay: Duration(milliseconds: 120 * index),
            child: _SkeletonRow(nameFraction: _nameFractions[index]),
          ),
        ),
      ),
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow({required this.nameFraction});

  final double nameFraction;

  // The reference's lighter secondary bone tone (app-states.html state 14).
  static const _boneLight = Color(0xFFF2EAE0);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
      child: Row(
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              shape: BoxShape.circle,
            ),
            child: SizedBox(width: 44, height: 44),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FractionallySizedBox(
                  widthFactor: nameFraction,
                  child: const _Bone(height: 13, color: AppColors.surfaceAlt),
                ),
                const SizedBox(height: 6),
                const FractionallySizedBox(
                  widthFactor: 0.3,
                  child: _Bone(height: 11, color: _boneLight),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.s2),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _Bone(height: 11, width: 34, color: AppColors.surfaceAlt),
              SizedBox(height: 6),
              _Bone(height: 11, width: 34, color: _boneLight),
            ],
          ),
        ],
      ),
    );
  }
}

class _Bone extends StatelessWidget {
  const _Bone({required this.height, required this.color, this.width});

  final double height;
  final double? width;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: SizedBox(height: height, width: width),
    );
  }
}
