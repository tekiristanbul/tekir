import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import '../../../core/motion/tekir_motion.dart';
import '../../../core/theme/app_theme.dart';
import '../data/cat_marker.dart';
import 'focus_lens.dart';
import 'map_projection.dart';

/// Concept 1's surface: every cat in view, drawn in Flutter over the map,
/// under a lens that follows the pointer.
///
/// ## Why the pins are not markers
///
/// A `google_maps_flutter` marker is a bitmap the platform draws, addressed
/// by coordinate. There is no per-frame transform on it: changing its size
/// means encoding a new png and pushing a new marker set across the
/// platform channel, and changing its position means moving the cat on the
/// map. Neither can happen sixty times a second, and neither should — the
/// cat has not moved. So the lens owns the drawing for as long as it is the
/// active concept: the basemap stays exactly the map it was, and the cat
/// layer becomes Flutter's.
///
/// Native clustering is left intact in the code and simply has nothing to
/// group while this concept is on, which is also why no count bubble
/// appears anywhere in this interaction. Switching the concept off restores
/// the marker set and the clusterer with it, unchanged.
///
/// ## The glass is drawn
///
/// The basemap cannot be magnified — it is a platform view, and its pixels
/// are not ours to sample — so the lens has to declare itself. A ring is
/// drawn at its rim, with a hairline just inside it for thickness, and the
/// magnification profile ends vertically at that ring. Together they make
/// the boundary a place on the map: cross it and a cat is at its own size,
/// exactly, on the far side of a line you can see.
///
/// Nothing is displaced, so nothing needs a leader back to the truth. Every
/// pin is on its own coordinate at every moment.
class FocusLensLayer extends StatefulWidget {
  const FocusLensLayer({
    super.key,
    required this.cats,
    required this.projection,
    required this.armed,
    required this.onSelect,
    required this.onZoom,
  });

  final List<CatMarker> cats;

  /// Rebuilt by the map screen on every camera frame, so the pins stay
  /// welded to the ground while the map moves under them.
  final MapProjection projection;

  /// Whether the glass is in the reader's hand.
  ///
  /// This is the whole answer to the gesture problem. Reading the pointer
  /// continuously means taking every pointer event before the map's own
  /// html element sees them, and a map whose panning has been
  /// re-implemented over a platform channel pans like a re-implementation.
  /// So the layer only takes them while the lens is actually up: with it
  /// down, nothing is intercepted except the pins themselves, and the map
  /// pans and zooms with its own native gestures, at its own speed.
  final bool armed;

  final ValueChanged<CatMarker> onSelect;

  /// Zoom the camera by a number of levels — only used while [armed], when
  /// the wheel would otherwise be swallowed with everything else.
  final ValueChanged<double> onZoom;

  @override
  State<FocusLensLayer> createState() => _FocusLensLayerState();
}

class _FocusLensLayerState extends State<FocusLensLayer>
    with SingleTickerProviderStateMixin {
  /// Ramps the lens in and out. Not the lens's movement — that follows the
  /// pointer with no smoothing at all, because a lens that lags the finger
  /// stops being a lens — only its arrival and departure.
  late final AnimationController _strength = AnimationController(
    vsync: this,
    duration: TekirMotion.state,
    // Out faster than in, per the motion system: releasing is a release,
    // and a slow return reads as the app deciding something.
    reverseDuration: TekirMotion.tap,
  );

  Offset? _focus;
  Offset? _pressedAt;
  final _photos = <String, ImageProvider>{};

  @override
  void didUpdateWidget(FocusLensLayer old) {
    super.didUpdateWidget(old);
    // Putting the glass down settles every pin back onto its coordinate,
    // exactly as lifting a finger does.
    if (old.armed && !widget.armed) _endFocus();
  }

  @override
  void dispose() {
    _strength.dispose();
    super.dispose();
  }

  void _moveFocus(Offset position) {
    setState(() => _focus = position);
    if (TekirMotion.of(context).reduced) {
      // Immediate, in this frame: reduced motion asks for the scale and
      // displacement changes without the travel, and a zero-duration
      // controller would still cost a tick to get there.
      _strength.value = 1;
      return;
    }
    if (_strength.status != AnimationStatus.forward && _strength.value != 1.0) {
      _strength.forward();
    }
  }

  void _endFocus() {
    if (TekirMotion.of(context).reduced) {
      setState(() {
        _strength.value = 0;
        _focus = null;
      });
      return;
    }
    // The pins settle back along the same path they came out on; the focus
    // point itself is kept until the ramp finishes, so nothing snaps.
    _strength.reverse().whenCompleteOrCancel(() {
      if (mounted && _strength.value == 0) setState(() => _focus = null);
    });
  }

  /// Resolves a release into a selection, when the press stayed put and
  /// landed on a magnified pin. Done here rather than by the pins because
  /// the glass is above them and takes the pointer first.
  void _tapped(
    List<LensPlacement> placements,
    Map<String, CatMarker> byId,
    Offset position,
  ) {
    final pressed = _pressedAt;
    _pressedAt = null;
    // A press that travelled was reading the map, not choosing a cat.
    if (pressed == null || (position - pressed).distance > 12) return;
    LensPlacement? hit;
    var nearest = double.infinity;
    for (final placement in placements) {
      final distance = (placement.position - position).distance;
      if (distance > lensBasePin * placement.scale / 2) continue;
      if (distance >= nearest) continue;
      nearest = distance;
      hit = placement;
    }
    if (hit == null) return;
    if (byId[hit.id] case final cat?) widget.onSelect(cat);
  }

  ImageProvider? _photoOf(CatMarker cat) {
    if (cat.primaryPhoto.isEmpty) return null;
    // Held per cat and never rebuilt at a new decode size: the pin changes
    // size every frame under the lens, and re-decoding on each step would
    // make the lens cost a photo decode per pin per frame.
    return _photos.putIfAbsent(
      cat.primaryPhoto,
      () => CachedNetworkImageProvider(cat.primaryPhoto),
    );
  }

  @override
  Widget build(BuildContext context) {
    final motion = TekirMotion.of(context);
    // Reduced motion keeps the lens — it is the reading mechanism, not
    // decoration — and drops only the ramp, so engaging and releasing the
    // focus are immediate scale and position changes in one frame.
    _strength.duration = motion(TekirMotion.state);
    _strength.reverseDuration = motion(TekirMotion.tap);

    final projected = <({String id, Offset point})>[
      for (final cat in widget.cats)
        (
          id: cat.id,
          point: widget.projection.toScreen(LatLng(cat.lat, cat.lng)),
        ),
    ];
    final byId = {for (final cat in widget.cats) cat.id: cat};

    return AnimatedBuilder(
      animation: _strength,
      builder: (context, _) {
        final placements = lensPlacements(
          focus: _focus,
          strength: _strength.value,
          cats: projected,
        );
        return Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _GlassPainter(
                    focus: _focus,
                    strength: _strength.value,
                  ),
                ),
              ),
            ),
            // Back to front, nearest the focus last: the cat the glass is
            // actually over is the largest one *and* the one on top, which
            // is what lets a sweep read a stack one cat at a time.
            for (final placement in placements)
              if (byId[placement.id] case final cat?)
                _LensPin(
                  key: ValueKey(cat.id),
                  cat: cat,
                  placement: placement,
                  photo: _photoOf(cat),
                  // While the glass is up the sheet on top owns every
                  // pointer and resolves taps to pins itself.
                  onTap: widget.armed ? null : () => widget.onSelect(cat),
                ),
            // The glass itself, over everything it magnifies. It has to be
            // the topmost thing: a pin catching the press first would mean
            // the lens never came up over the very cats it exists for.
            // Taps are therefore resolved here, against the placements
            // this frame actually drew.
            if (widget.armed)
              Positioned.fill(
                child: PointerInterceptor(
                  child: MouseRegion(
                    // Where hover exists the lens needs no gesture at all:
                    // it is wherever the cursor is.
                    onHover: (event) => _moveFocus(event.localPosition),
                    onExit: (_) => _endFocus(),
                    child: Listener(
                      // Opaque: an empty box hit-tests to nothing, and a
                      // listener that defers to its child would then never
                      // see a pointer at all.
                      behavior: HitTestBehavior.opaque,
                      // And where it does not — every touch screen — the
                      // finger is the lens for as long as it is down.
                      onPointerDown: (event) {
                        _pressedAt = event.localPosition;
                        _moveFocus(event.localPosition);
                      },
                      onPointerMove: (event) => _moveFocus(event.localPosition),
                      onPointerUp: (event) {
                        _tapped(placements, byId, event.localPosition);
                        _endFocus();
                      },
                      onPointerCancel: (_) {
                        _pressedAt = null;
                        _endFocus();
                      },
                      // The wheel is swallowed with everything else while
                      // armed, so it is handed back to the camera.
                      onPointerSignal: (event) {
                        if (event is PointerScrollEvent) {
                          widget.onZoom(-event.scrollDelta.dy / 220);
                        }
                      },
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A pin's own tap target, present only while the glass is down.
class _PinHitTarget extends StatelessWidget {
  const _PinHitTarget({required this.onTap, required this.child});

  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (onTap == null) return IgnorePointer(child: child);
    return PointerInterceptor(
      child: GestureDetector(onTap: onTap, child: child),
    );
  }
}

/// The glass itself. Two hairlines, no fill and no blur: the rim, and a
/// second line just inside it that reads as the thickness of a disc lying
/// on the map. Enough to say where the lens is; not enough to compete with
/// the streets it sits on.
class _GlassPainter extends CustomPainter {
  const _GlassPainter({required this.focus, required this.strength});

  final Offset? focus;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = focus;
    if (centre == null || strength <= 0) return;
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = AppColors.ink.withValues(alpha: 0.22 * strength);
    final inner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = AppColors.surface.withValues(alpha: 0.55 * strength);

    canvas.drawCircle(centre, lensRadius, rim);
    canvas.drawCircle(centre, lensRadius - 3, inner);
  }

  @override
  bool shouldRepaint(_GlassPainter old) =>
      old.focus != focus || old.strength != strength;
}

/// One cat under the lens: the shipped marker's language — circular photo,
/// coloured ring, help red when the cat is marked — at whatever size the
/// lens currently gives it.
class _LensPin extends StatelessWidget {
  const _LensPin({
    super.key,
    required this.cat,
    required this.placement,
    required this.photo,
    required this.onTap,
  });

  final CatMarker cat;
  final LensPlacement placement;
  final ImageProvider? photo;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final size = lensBasePin * placement.scale;
    final ring = cat.needsHelp ? AppColors.help : AppColors.primary;
    return Positioned(
      left: placement.position.dx - size / 2,
      top: placement.position.dy - size / 2,
      width: size,
      height: size,
      child: Semantics(
        button: true,
        // Native markers are bitmaps inside a platform view and carry no
        // semantics at all. Drawing the cats in Flutter is the first time
        // they are reachable by a screen reader — a side effect of the
        // concept, and a finding about the shipped map.
        label: cat.needsHelp ? '${cat.name}, yardıma ihtiyacı var' : cat.name,
        // With the glass down nothing else is taking events, and a flutter
        // widget over a platform view is not tappable on web without an
        // interceptor of its own. With it up the sheet above owns the
        // pointer and this is a drawing, so it takes nothing.
        child: _PinHitTarget(
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surface,
              border: Border.all(
                color: ring,
                // The ring grows with the pin but not proportionally: a
                // stroke that scaled with it would read as a different pin
                // rather than the same one, closer.
                width: cat.needsHelp
                    ? 2 + placement.scale
                    : 1 + placement.scale,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0x332A1F1B),
                  // The shadow is the only cue that carries depth rather
                  // than size: a magnified pin sits further off the map
                  // than its neighbours, and reads as lifted instead of
                  // merely bigger.
                  offset: Offset(0, placement.scale),
                  blurRadius: 3 * placement.scale,
                ),
              ],
            ),
            child: ClipOval(
              child: photo == null
                  ? const ColoredBox(
                      color: AppColors.primarySoft,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Padding(
                          padding: EdgeInsets.all(6),
                          child: Icon(
                            Icons.pets,
                            size: 20,
                            color: AppColors.primaryStrong,
                          ),
                        ),
                      ),
                    )
                  : Image(image: photo!, fit: BoxFit.cover),
            ),
          ),
        ),
      ),
    );
  }
}
