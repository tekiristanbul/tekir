import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/relative_time.dart';
import '../data/cat_marker.dart';

/// Marker-tap preview sheet (issue #21 prototype-parity correction):
/// tapping a map marker opens this over the map instead of navigating
/// straight to the cat-detail screen — matching prototype/app.js's
/// `openSheet` (photo, name, human-readable area, last update, a needs-help
/// mark when active, and a single "detaya git" action). Content comes
/// entirely from the already-fetched [CatMarker] — opening this never
/// triggers a second network request.
class CatPreviewSheet extends StatelessWidget {
  const CatPreviewSheet({
    super.key,
    required this.cat,
    required this.onOpenDetail,
  });

  final CatMarker cat;
  final VoidCallback onOpenDetail;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bgElevated,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      padding: EdgeInsets.only(
        left: AppSpacing.s5,
        right: AppSpacing.s5,
        top: AppSpacing.s2,
        bottom: AppSpacing.s6 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: AppSpacing.s3),
              decoration: BoxDecoration(
                color: AppColors.lineStrong,
                borderRadius: BorderRadius.circular(AppRadius.full),
              ),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PreviewPhoto(url: cat.primaryPhoto),
              const SizedBox(width: AppSpacing.s4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cat.name,
                      style: Theme.of(context).textTheme.titleLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (cat.areaLabel != null) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(
                            Icons.location_on,
                            size: 14,
                            color: AppColors.muted,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              cat.areaLabel!,
                              style: Theme.of(context).textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 6),
                    if (cat.needsHelp)
                      const _NeedsHelpBadge()
                    else if (cat.lastUpdateAt != null)
                      Row(
                        children: [
                          const Icon(
                            Icons.access_time,
                            size: 13,
                            color: AppColors.faint,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            relativeTimeTr(cat.lastUpdateAt!),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s4),
          SizedBox(
            height: kTapMin,
            child: ElevatedButton(
              onPressed: onOpenDetail,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.primaryInk,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontFamily: 'Work Sans',
                ),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Detaya git'),
                  SizedBox(width: 6),
                  Icon(Icons.chevron_right, size: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NeedsHelpBadge extends StatelessWidget {
  const _NeedsHelpBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s2,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: AppColors.help,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, size: 12, color: AppColors.helpInk),
          SizedBox(width: 4),
          Text(
            'yardım gerekiyor',
            style: TextStyle(
              color: AppColors.helpInk,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewPhoto extends StatelessWidget {
  const _PreviewPhoto({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadius.lg);
    if (url.isEmpty) {
      return ClipRRect(borderRadius: radius, child: const _PhotoPlaceholder());
    }
    return ClipRRect(
      borderRadius: radius,
      child: CachedNetworkImage(
        imageUrl: url,
        width: 92,
        height: 92,
        fit: BoxFit.cover,
        placeholder: (context, _) => const SizedBox(
          width: 92,
          height: 92,
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
        errorWidget: (context, _, _) => const _PhotoPlaceholder(),
      ),
    );
  }
}

class _PhotoPlaceholder extends StatelessWidget {
  const _PhotoPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 92,
      height: 92,
      color: AppColors.primarySoft,
      child: const Icon(Icons.pets, size: 32, color: AppColors.primaryStrong),
    );
  }
}
