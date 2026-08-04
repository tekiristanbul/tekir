import 'package:flutter/material.dart';

/// The one small spinner the state contract allows: inside buttons and
/// inline rows only — waiting is never shown as a bare spinner screen
/// (docs/design/app-states.md). Under reduced motion it renders as a
/// static quarter arc: still visible, never spinning.
class InlineSpinner extends StatelessWidget {
  const InlineSpinner({
    super.key,
    required this.size,
    required this.color,
    required this.trackColor,
  });

  final double size;
  final Color color;
  final Color trackColor;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final reduceMotion = media.disableAnimations || media.accessibleNavigation;
    return SizedBox(
      width: size,
      height: size,
      child: ExcludeSemantics(
        child: CircularProgressIndicator(
          value: reduceMotion ? 0.25 : null,
          strokeWidth: 2.5,
          color: color,
          backgroundColor: trackColor,
        ),
      ),
    );
  }
}
