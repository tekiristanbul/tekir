import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/images/decode_budget.dart';
import '../../../core/motion/tekir_motion.dart';
import '../../../core/theme/app_theme.dart';
import '../data/cat_marker.dart';
import 'fisheye.dart';

/// Concept 1's surface: the cats around a focus, drawn where they can be
/// read and told where they really are.
///
/// The layer is opened by a focus event on the map — a tap on a cluster,
/// or a long press anywhere — and lives entirely in screen space for as
/// long as that focus lasts. It never writes a position back, never moves
/// the camera, and never touches the marker set underneath; ending the
/// focus removes the layer and the map is exactly as it was.
///
/// Three things are drawn, in this order: a leader from each cat's real
/// position to the seat it was given, a mark on the real position itself,
/// and the pin at the seat. The leader is the honest part of the idea. A
/// displaced pin that draws nothing behind it is a map telling the user a
/// cat is somewhere it isn't; with the leader, the displacement reads as
/// what it is — a temporary reading position, with the real one still on
/// screen.
class ProximityFanLayer extends StatefulWidget {
  const ProximityFanLayer({
    super.key,
    required this.focus,
    required this.seats,
    required this.cats,
    required this.onSelect,
    required this.onDismiss,
  });

  final Offset focus;
  final List<FisheyeSeat> seats;
  final Map<String, CatMarker> cats;
  final ValueChanged<CatMarker> onSelect;
  final VoidCallback onDismiss;

  @override
  State<ProximityFanLayer> createState() => _ProximityFanLayerState();
}

class _ProximityFanLayerState extends State<ProximityFanLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: TekirMotion.surface,
    // The collapse is one step faster than the separation, per the motion
    // system: a slow exit reads as the app thinking, and this exit is a
    // release.
    reverseDuration: TekirMotion.state,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final motion = TekirMotion.of(context);
    _controller.duration = motion(TekirMotion.surface);
    _controller.reverseDuration = motion(TekirMotion.state);
    if (_controller.status == AnimationStatus.dismissed) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pinSize = fisheyeMinSpacing - 6;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = TekirMotion.enter.transform(_controller.value);
        return Stack(
          children: [
            // Ending the focus is a tap anywhere that isn't a cat. No
            // scrim: the neighbourhood the user was reading is the reason
            // they opened this, and dimming it to stage the pins would
            // trade the map away for the effect.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onDismiss,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _LeaderPainter(seats: widget.seats, progress: t),
                ),
              ),
            ),
            for (final seat in widget.seats)
              if (widget.cats[seat.id] case final cat?)
                Positioned(
                  left:
                      Offset.lerp(seat.origin, seat.seat, t)!.dx - pinSize / 2,
                  top: Offset.lerp(seat.origin, seat.seat, t)!.dy - pinSize / 2,
                  width: pinSize,
                  height: pinSize,
                  child: _FanPin(
                    cat: cat,
                    size: pinSize,
                    onTap: () => widget.onSelect(cat),
                  ),
                ),
          ],
        );
      },
    );
  }
}

/// The line back to the truth, plus a mark on it. One logical pixel, in the
/// map chrome's own line colour: it has to be followable and it must not
/// compete with the pins or with the streets under it.
class _LeaderPainter extends CustomPainter {
  const _LeaderPainter({required this.seats, required this.progress});

  final List<FisheyeSeat> seats;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = AppColors.lineStrong
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final anchor = Paint()..color = AppColors.lineStrong;

    for (final seat in seats) {
      // A cat that barely moved needs no leader; drawing one would add a
      // mark to the map for no information.
      if (seat.displacement < 8) continue;
      final head = Offset.lerp(seat.origin, seat.seat, progress)!;
      canvas.drawLine(seat.origin, head, line);
      canvas.drawCircle(seat.origin, 2.5, anchor);
    }
  }

  @override
  bool shouldRepaint(_LeaderPainter old) =>
      old.progress != progress || old.seats != seats;
}

/// The pin at a seat: the shipped marker's language — circular photo,
/// coloured ring, help red when the cat is marked — at the size the
/// separation was solved for.
class _FanPin extends StatelessWidget {
  const _FanPin({required this.cat, required this.size, required this.onTap});

  final CatMarker cat;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ring = cat.needsHelp ? AppColors.help : AppColors.primary;
    return Semantics(
      button: true,
      // The native marker under this has no semantics at all — a Google
      // Maps pin is a bitmap inside a platform view, invisible to
      // TalkBack and VoiceOver. Separating the group into real widgets is
      // the first time these cats are reachable by a screen reader, which
      // is a finding about the shipped map as much as about this concept.
      label: cat.needsHelp ? '${cat.name}, yardıma ihtiyacı var' : cat.name,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.surface,
            border: Border.all(color: ring, width: cat.needsHelp ? 3 : 2),
            boxShadow: const [
              BoxShadow(
                color: Color(0x332A1F1B),
                offset: Offset(0, 2),
                blurRadius: 6,
              ),
            ],
          ),
          child: ClipOval(
            child: cat.primaryPhoto.isEmpty
                ? const ColoredBox(
                    color: AppColors.primarySoft,
                    child: Icon(
                      Icons.pets,
                      size: 20,
                      color: AppColors.primaryStrong,
                    ),
                  )
                : CachedNetworkImage(
                    imageUrl: cat.primaryPhoto,
                    fit: BoxFit.cover,
                    memCacheWidth: decodeWidthFor(context, size),
                    errorWidget: (context, _, _) => const ColoredBox(
                      color: AppColors.primarySoft,
                      child: Icon(
                        Icons.pets,
                        size: 20,
                        color: AppColors.primaryStrong,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
