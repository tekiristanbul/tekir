import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The one line both location-aware surfaces show when they are running on
/// the fixed istanbul center instead of a real position — permission
/// denied, location services off, a resolve timeout, or a position outside
/// the product's istanbul area. Losing location never blocks a screen and
/// never renders as an error: the map still opens on greater istanbul and
/// discover still lists cats, this note just says which point those results
/// are anchored to and offers the one action that can change it.
///
/// Shared rather than duplicated so the map and discover can't drift apart
/// in copy or in what the action does.
class FallbackLocationNote extends StatelessWidget {
  const FallbackLocationNote({super.key, required this.onEnableLocation});

  final VoidCallback onEnableLocation;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.only(
          left: AppSpacing.s3,
          right: AppSpacing.s2,
          top: AppSpacing.s2,
          bottom: AppSpacing.s2,
        ),
        child: Row(
          children: [
            const Icon(
              Icons.location_off_outlined,
              size: 18,
              color: AppColors.faint,
            ),
            const SizedBox(width: AppSpacing.s2),
            const Expanded(
              child: Text(
                'konum yok — istanbul merkezi gösteriliyor',
                style: TextStyle(fontSize: 13, color: AppColors.muted),
              ),
            ),
            TextButton(
              onPressed: onEnableLocation,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s2),
                minimumSize: const Size(0, kTapMin),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: const Text('konum iznini aç'),
            ),
          ],
        ),
      ),
    );
  }
}
