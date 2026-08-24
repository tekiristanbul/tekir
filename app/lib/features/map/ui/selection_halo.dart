import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/motion/tekir_motion.dart';
import '../../../core/theme/app_theme.dart';

/// The selected cat's halo: a dashed ring turning slowly around it, and a
/// single pulse leaving it (approved design, artboard 02 and the spec
/// block's `hareket` section).
///
/// Drawn as a flutter layer over the map rather than into the marker,
/// because a marker is a bitmap and a bitmap cannot turn. The design's own
/// google maps note says exactly this. There is only ever one of these on
/// screen, so the layer costs one widget and no platform traffic.
///
/// Pulse is reserved for two things in this app — help, and selection —
/// and nothing else pulses. Under reduced motion the ring holds still and
/// the pulse does not run: the state they mark is already carried by the
/// sheet that opened and by the marker's own selected rendering, so
/// removing the travel removes nothing a user needs.
class SelectionHalo extends StatefulWidget {
  const SelectionHalo({super.key, required this.center, required this.radius});

  /// Where the selected marker sits in the map widget's own logical
  /// pixels.
  final Offset center;

  /// Radius of the ring, measured from [center].
  final double radius;

  /// One turn of the dashed ring. Slow on purpose: at this speed it reads
  /// as attention resting on the cat rather than as something loading.
  static const rotationPeriod = Duration(seconds: 9);

  /// One pulse leaving the selected cat.
  static const pulsePeriod = Duration(milliseconds: 2200);

  @override
  State<SelectionHalo> createState() => _SelectionHaloState();
}

class _SelectionHaloState extends State<SelectionHalo>
    with TickerProviderStateMixin {
  late final AnimationController _rotation = AnimationController(
    vsync: this,
    duration: SelectionHalo.rotationPeriod,
  );
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: SelectionHalo.pulsePeriod,
  );

  bool _reduced = false;

  /// Driven from here and nowhere else.
  ///
  /// This used to be re-decided in `build` as well, which runs on every
  /// camera frame while the halo tracks its cat — and any rebuild that
  /// disagreed with the flag it was guarded by stopped the controllers.
  /// The ring turned once and then sat still. `didChangeDependencies` runs
  /// exactly when the motion preference can actually have changed, which is
  /// the only time this decision is worth making.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = TekirMotion.of(context).reduced;
    if (_reduced) {
      // Held at rest rather than stopped mid-turn, so the ring reads as a
      // deliberate mark instead of an animation someone paused — and so the
      // tree settles, which a repeating controller never lets it do.
      _rotation
        ..stop()
        ..value = 0;
      _pulse
        ..stop()
        ..value = 0;
      return;
    }
    if (!_rotation.isAnimating) _rotation.repeat();
    if (!_pulse.isAnimating) _pulse.repeat();
  }

  @override
  void dispose() {
    _rotation.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Room for the pulse at its widest, which travels past the ring.
    final extent = widget.radius * _HaloPainter.maxPulseScale;
    return Positioned(
      left: widget.center.dx - extent,
      top: widget.center.dy - extent,
      width: extent * 2,
      height: extent * 2,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: AnimatedBuilder(
            animation: Listenable.merge([_rotation, _pulse]),
            builder: (context, _) => CustomPaint(
              painter: _HaloPainter(
                radius: widget.radius,
                // Held at rest under reduced motion rather than stopped
                // mid-turn, so the ring reads as a deliberate mark instead
                // of an animation someone paused.
                turn: _reduced ? 0 : _rotation.value,
                pulse: _reduced ? null : _pulse.value,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HaloPainter extends CustomPainter {
  const _HaloPainter({
    required this.radius,
    required this.turn,
    required this.pulse,
  });

  /// How far past the ring one pulse travels before it is gone.
  static const maxPulseScale = 1.6;

  final double radius;
  final double turn;

  /// Null under reduced motion: the ring is drawn, the pulse is not.
  final double? pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    final progress = pulse;
    if (progress != null) {
      // The pulse fades as it grows, so it reads as something leaving the
      // cat rather than a second ring arriving.
      final scale = 1 + (maxPulseScale - 1) * progress;
      final opacity = (1 - progress) * 0.45;
      if (opacity > 0) {
        canvas.drawCircle(
          center,
          radius * scale,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = AppColors.primary.withValues(alpha: opacity),
        );
      }
    }

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(turn * 2 * math.pi);
    _paintDashedRing(canvas);
    canvas.restore();
  }

  /// A dashed circle, drawn arc by arc — flutter has no dash support on
  /// [Paint], and a `PathMetric`-based dasher would allocate a path every
  /// frame for a shape this simple.
  void _paintDashedRing(Canvas canvas) {
    const dashes = 24;
    const gapRatio = 0.62;
    final sweep = 2 * math.pi / dashes;
    final dash = sweep * (1 - gapRatio);
    final rect = Rect.fromCircle(center: Offset.zero, radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = AppColors.primary.withValues(alpha: 0.55);
    for (var i = 0; i < dashes; i++) {
      canvas.drawArc(rect, i * sweep, dash, false, paint);
    }
  }

  @override
  bool shouldRepaint(_HaloPainter old) =>
      old.turn != turn || old.pulse != pulse || old.radius != radius;
}
