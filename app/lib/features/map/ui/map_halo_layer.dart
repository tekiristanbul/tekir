import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../../core/motion/tekir_motion.dart';
import '../data/marker_bitmap_builder.dart';
import '../../../core/theme/app_theme.dart';

/// Everything on this map that pulses, drawn as one layer over it
/// (approved design, artboards 01–02 and the spec block's `hareket`).
///
/// Two things pulse and nothing else does: a cat waiting for help, and the
/// cat you just selected. The design gives them the same shape and
/// different rhythms — a ring leaving the cat, 2.6s for help and 2.2s for
/// selection — with a slowly turning dashed ring added to the selected one.
///
/// A marker is a bitmap and a bitmap cannot pulse, so these are painted in
/// flutter at each cat's own screen position. One layer, one painter and
/// three controllers for the whole map: a dozen help marks cost the same
/// tickers as one, which is what makes drawing them at all affordable.
class MapHaloLayer extends StatefulWidget {
  const MapHaloLayer({
    super.key,
    required this.helpCentres,
    required this.selectedCentre,
  });

  /// Where each cat waiting for help sits, in the map widget's own logical
  /// pixels. Only cats drawn as their own face are here: at the zooms where
  /// a cat is a dot, a screenful of expanding rings is weather, not a
  /// signal.
  final List<Offset> helpCentres;

  /// Where the selected cat sits, or null when nothing is selected or it
  /// has been panned out of view.
  final Offset? selectedCentre;

  /// One ring leaving a cat that needs help.
  static const helpPeriod = Duration(milliseconds: 2600);

  /// One ring leaving the selected cat. Faster than help, so the two never
  /// read as the same event even on the same cat.
  static const selectionPeriod = Duration(milliseconds: 2200);

  /// One turn of the selected cat's dashed ring. Slow on purpose: at this
  /// speed it reads as attention resting on the cat rather than as
  /// something loading.
  static const rotationPeriod = Duration(seconds: 9);

  /// Radius the help ring starts from: the avatar marker's own edge, so
  /// the pulse reads as leaving the cat rather than as a second ring
  /// hovering around it.
  static const helpRadius = MarkerBitmapBuilder.avatarSize / 2;

  /// Radius the selection ring starts from, and the dashed ring's own.
  static const selectionRadius = 39.0;
  static const dashedRingRadius = 43.0;

  @override
  State<MapHaloLayer> createState() => _MapHaloLayerState();
}

class _MapHaloLayerState extends State<MapHaloLayer>
    with TickerProviderStateMixin {
  late final AnimationController _help = AnimationController(
    vsync: this,
    duration: MapHaloLayer.helpPeriod,
  );
  late final AnimationController _selection = AnimationController(
    vsync: this,
    duration: MapHaloLayer.selectionPeriod,
  );
  late final AnimationController _rotation = AnimationController(
    vsync: this,
    duration: MapHaloLayer.rotationPeriod,
  );

  bool _reduced = false;

  /// True while there is anything to draw at all.
  bool get _hasWork =>
      widget.helpCentres.isNotEmpty || widget.selectedCentre != null;

  /// Driven from here and [didUpdateWidget], never from `build` — which
  /// runs on every frame of a camera movement, because these rings track
  /// their cats. Deciding it there let any rebuild that disagreed stop the
  /// controllers: the ring turned once and then sat still.
  ///
  /// The layer itself is mounted for as long as the map is, so this state
  /// — and the turn the ring is part-way through — survives a moment with
  /// nothing to draw. Mounting it only when it had work restarted every
  /// controller from zero each time, which is what made the selected cat's
  /// ring look like it kept beginning again.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = TekirMotion.of(context).reduced;
    _syncControllers();
  }

  @override
  void didUpdateWidget(MapHaloLayer old) {
    super.didUpdateWidget(old);
    _syncControllers();
  }

  void _syncControllers() {
    final running = _hasWork && !_reduced;
    for (final controller in [_help, _selection, _rotation]) {
      if (running) {
        if (!controller.isAnimating) controller.repeat();
      } else if (controller.isAnimating) {
        // Stopped where it stands, not reset: the cat this ring belongs to
        // may still be selected a frame later, and a ring that jumped back
        // to zero would read as a new mark rather than the same one.
        controller.stop();
      }
    }
    // Reduced motion is the one case that does reset, so the ring rests in
    // a deliberate position rather than wherever it happened to stop.
    if (_reduced) {
      for (final controller in [_help, _selection, _rotation]) {
        controller.value = 0;
      }
    }
  }

  @override
  void dispose() {
    _help.dispose();
    _selection.dispose();
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasWork) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        // Decoration: which cat needs help and which one is selected are
        // both carried by the marker itself and by the surfaces that open
        // with them. A ring must never be the only thing saying so, and
        // must never swallow a tap meant for the map.
        child: ExcludeSemantics(
          child: AnimatedBuilder(
            animation: Listenable.merge([_help, _selection, _rotation]),
            builder: (context, _) => CustomPaint(
              painter: MapHaloPainter(
                helpCentres: widget.helpCentres,
                selectedCentre: widget.selectedCentre,
                helpPulse: _reduced ? null : _help.value,
                selectionPulse: _reduced ? null : _selection.value,
                turn: _reduced ? 0 : _rotation.value,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Public so a test can hold it and check it is being handed new values —
/// the thing that broke when this was decided in `build`.
class MapHaloPainter extends CustomPainter {
  const MapHaloPainter({
    required this.helpCentres,
    required this.selectedCentre,
    required this.helpPulse,
    required this.selectionPulse,
    required this.turn,
  });

  /// The design's own sonar: a ring grows out of the cat and is gone
  /// before it reaches full size, leaving a rest — so the eye reads
  /// something leaving the cat rather than a ring arriving.
  ///
  /// It starts at the marker's own edge, not inside it. The artboard can
  /// start its ring at half radius because the cat's face is a sibling
  /// drawn over it; here the map is a platform view and every flutter
  /// layer is above it, so a ring that started inside would cross the
  /// photo instead of appearing from behind it.
  static const _pulseFromScale = 1.0;
  static const _pulseToScale = 2.6;
  static const _pulseFadesBy = 0.7;
  static const _pulseFromOpacity = 0.5;

  final List<Offset> helpCentres;
  final Offset? selectedCentre;

  /// Null under reduced motion: the ring is drawn at rest, the pulse is
  /// not drawn at all.
  final double? helpPulse;
  final double? selectionPulse;
  final double turn;

  /// Where a ring sits at [progress] through its cycle, as a multiple of
  /// the marker's radius — the shape of the pulse, exposed so a test can
  /// assert it leaves from the marker's edge rather than from inside it.
  static double debugPulseScaleAt(double progress) =>
      _pulseFromScale + (_pulseToScale - _pulseFromScale) * progress;

  /// The point in a cycle by which a ring has faded to nothing.
  static const debugPulseFadesBy = _pulseFadesBy;

  @override
  void paint(Canvas canvas, Size size) {
    // Only the pulse. The ring at rest is drawn into the marker bitmap
    // itself, at every resolution and whatever the motion preference —
    // which is what keeps the help mark on screen when this layer draws
    // nothing at all.
    for (final centre in helpCentres) {
      _paintPulse(
        canvas,
        centre,
        MapHaloLayer.helpRadius,
        AppColors.help,
        helpPulse,
      );
    }

    final selected = selectedCentre;
    if (selected == null) return;
    _paintPulse(
      canvas,
      selected,
      MapHaloLayer.selectionRadius,
      AppColors.primary,
      selectionPulse,
    );
    // The dashed ring is the selection's own resting mark: it turns for as
    // long as the cat is selected and never fades. The pulse comes and
    // goes around it — without this the cat would be unmarked for the rest
    // between two pulses, which read as the animation ending.
    canvas.save();
    canvas.translate(selected.dx, selected.dy);
    canvas.rotate(turn * 2 * math.pi);
    _paintDashedRing(canvas);
    canvas.restore();
  }

  void _paintPulse(
    Canvas canvas,
    Offset centre,
    double radius,
    Color colour,
    double? progress,
  ) {
    if (progress == null) return;
    final scale = debugPulseScaleAt(progress);
    final fade = (1 - progress / _pulseFadesBy).clamp(0.0, 1.0);
    final opacity = _pulseFromOpacity * fade;
    if (opacity <= 0) return;
    canvas.drawCircle(
      centre,
      radius * scale,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = colour.withValues(alpha: opacity),
    );
  }

  /// A dashed circle, drawn arc by arc — flutter has no dash support on
  /// [Paint], and a `PathMetric`-based dasher would allocate a path every
  /// frame for a shape this simple.
  void _paintDashedRing(Canvas canvas) {
    const dashes = 24;
    const gapRatio = 0.62;
    const radius = MapHaloLayer.dashedRingRadius;
    final sweep = 2 * math.pi / dashes;
    final dash = sweep * (1 - gapRatio);
    const rect = Rect.fromLTRB(-radius, -radius, radius, radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = AppColors.primary.withValues(alpha: 0.8);
    for (var i = 0; i < dashes; i++) {
      canvas.drawArc(rect, i * sweep, dash, false, paint);
    }
  }

  @override
  bool shouldRepaint(MapHaloPainter old) =>
      old.turn != turn ||
      old.helpPulse != helpPulse ||
      old.selectionPulse != selectionPulse ||
      old.selectedCentre != selectedCentre ||
      !listEquals(old.helpCentres, helpCentres);
}
