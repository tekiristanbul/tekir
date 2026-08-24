import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../discover/ui/cat_search_panel.dart';
import '../data/cat_marker.dart';
import '../data/marker_tier.dart';

/// Picks one cat out of a group the map cannot pull apart (issue #285).
///
/// Cats are grouped by the screen cell they fall in, and a cell is about
/// seven metres across at the map's closest zoom. Two cats recorded from
/// the same doorway therefore share one cell for good: tapping the group
/// zooms in until there is no zoom left, and the cats inside stay
/// unreachable. Without this they simply could not be selected.
///
/// A list, not a fan or a spiral: the cats are in the same place, so
/// putting them somewhere they are not to make them tappable would be a
/// lie about where they live. The rows are the ones the search panel
/// already uses, so picking a cat out of a group and picking one out of a
/// search result look and behave the same.
class ClusterPickerSheet extends StatelessWidget {
  const ClusterPickerSheet({
    super.key,
    required this.cluster,
    required this.onPick,
  });

  final CatCluster cluster;
  final ValueChanged<CatMarker> onPick;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bgElevated,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      padding: EdgeInsets.only(
        top: AppSpacing.s2,
        bottom: AppSpacing.s5 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(bottom: AppSpacing.s3),
              decoration: BoxDecoration(
                color: AppColors.lineStrong,
                borderRadius: BorderRadius.circular(AppRadius.full),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s5,
              0,
              AppSpacing.s5,
              AppSpacing.s3,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'aynı yerde ${cluster.count} kedi',
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(fontSize: 20),
                ),
                const SizedBox(height: 2),
                const Text(
                  'hangisine bakmak istersin?',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.faint,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s5),
              itemCount: cluster.cats.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.s4),
              itemBuilder: (context, index) {
                final cat = cluster.cats[index];
                return CatResultRow(
                  name: cat.name,
                  primaryPhoto: cat.primaryPhoto,
                  areaLabel: cat.areaLabel,
                  activeAlert: cat.activeAlert,
                  lastUpdateAt: cat.lastUpdateAt,
                  // Every cat here is in the same place, so a distance
                  // would be the same number repeated down the list.
                  distanceMeters: null,
                  onTap: () => onPick(cat),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
