import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../data/cat_marker.dart';

/// A single cat marker: its photo in a circular frame, with a red ring for
/// cats currently needing help.
class CatPin extends StatelessWidget {
  const CatPin({super.key, required this.cat, required this.onTap});

  final CatMarker cat;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: cat.needsHelp ? Colors.red : AppColors.accent,
            width: cat.needsHelp ? 3 : 2,
          ),
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 4,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: ClipOval(child: _photo()),
      ),
    );
  }

  Widget _photo() {
    if (cat.primaryPhoto.isEmpty) {
      return const ColoredBox(color: AppColors.panel, child: Icon(Icons.pets));
    }
    return CachedNetworkImage(
      imageUrl: cat.primaryPhoto,
      fit: BoxFit.cover,
      placeholder: (_, _) =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      errorWidget: (_, _, _) =>
          const ColoredBox(color: AppColors.panel, child: Icon(Icons.pets)),
    );
  }
}

/// A cluster bubble showing how many cats it groups.
class CatClusterPin extends StatelessWidget {
  const CatClusterPin({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.accent,
        boxShadow: [
          BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        '$count',
        style: const TextStyle(
          color: AppColors.panel,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
