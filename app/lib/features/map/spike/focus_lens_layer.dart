import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import '../../../core/motion/tekir_haptics.dart';
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
/// ## What the reader gets back
///
/// Magnification without a way back would be a map lying about where cats
/// are. Every pin the lens has moved keeps a hairline drawn to its real
/// position and a small anchor sitting on it, so the true geography is on
/// screen the whole time and the displacement reads as a temporary lens
/// artefact rather than as a location.
/// How long a press has to hold still before it becomes the lens. Roughly
/// the platform long-press, which is what a reader already expects to mean
/// "look closer" rather than "move this".
const Duration _holdToLens = Duration(milliseconds: 220);

/// How far a press may wander in that time and still count as holding
/// still.
const double _panSlop = 12;

enum _Pointer { idle, deciding, panning, lens }

class FocusLensLayer extends StatefulWidget {
  const FocusLensLayer({
    super.key,
    required this.cats,
    required this.projection,
    required this.onSelect,
    required this.onPan,
    required this.onZoom,
  });

  final List<CatMarker> cats;

  /// Rebuilt by the map screen on every camera frame, so the pins stay
  /// welded to the ground while the map moves under them.
  final MapProjection projection;

  final ValueChanged<CatMarker> onSelect;

  /// Drag the camera by a screen delta. The lens has to take every pointer
  /// event to see hover at all, so panning and zooming are handed back to
  /// the map from here rather than left to it.
  final ValueChanged<Offset> onPan;

  /// Zoom the camera by a number of levels.
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

  /// What the pointer currently down is doing. Deciding until the press
  /// either holds still long enough to be a lens or moves far enough to be
  /// a pan.
  _Pointer _pointer = _Pointer.idle;
  Offset _pressAt = Offset.zero;
  Offset _lastAt = Offset.zero;
  Timer? _holdTimer;

  final _photos = <String, ImageProvider>{};

  @override
  void dispose() {
    _holdTimer?.cancel();
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

    return MouseRegion(
      // Where hover exists it needs no gesture at all: the lens is
      // wherever the cursor is, which is the closest a mouse gets to a
      // finger resting on glass. Suppressed while a press is deciding or
      // panning, so a drag does not drag a lens with it.
      onHover: (event) {
        if (_pointer != _Pointer.idle) return;
        _moveFocus(event.localPosition);
      },
      onExit: (_) => _endFocus(),
      child: Listener(
        // The lens and the map both want the same drag, and which one the
        // user meant cannot be read off the device: a trackpad, a touch
        // screen and a mouse all arrive here, and Flutter web does not
        // report them consistently enough to branch on. So the press
        // itself decides, the way a magnifier does everywhere else — hold
        // still and the glass comes up under your finger, move off and you
        // are dragging the map.
        onPointerDown: (event) {
          _endFocus();
          _pointer = _Pointer.deciding;
          _pressAt = event.localPosition;
          _lastAt = event.localPosition;
          _holdTimer?.cancel();
          _holdTimer = Timer(_holdToLens, () {
            if (!mounted || _pointer != _Pointer.deciding) return;
            _pointer = _Pointer.lens;
            // The hand is what confirms the lens came up; the pins take a
            // frame or two to say so.
            unawaited(TekirHaptics.acknowledge());
            _moveFocus(_lastAt);
          });
        },
        onPointerMove: (event) {
          final position = event.localPosition;
          switch (_pointer) {
            case _Pointer.deciding:
              _lastAt = position;
              if ((position - _pressAt).distance <= _panSlop) return;
              _holdTimer?.cancel();
              _pointer = _Pointer.panning;
              widget.onPan(position - _pressAt);
              _lastAt = position;
            case _Pointer.panning:
              widget.onPan(position - _lastAt);
              _lastAt = position;
            case _Pointer.lens:
              _moveFocus(position);
            case _Pointer.idle:
              break;
          }
        },
        onPointerUp: (_) {
          _holdTimer?.cancel();
          if (_pointer == _Pointer.lens) _endFocus();
          _pointer = _Pointer.idle;
        },
        onPointerCancel: (_) {
          _holdTimer?.cancel();
          if (_pointer == _Pointer.lens) _endFocus();
          _pointer = _Pointer.idle;
        },
        // The wheel keeps zooming the map: a lens that took the scroll
        // wheel away would trade one way of reading the map for another.
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            widget.onZoom(-event.scrollDelta.dy / 220);
          }
        },
        child: AnimatedBuilder(
          animation: _strength,
          builder: (context, _) {
            final placements = lensPlacements(
              focus: _focus,
              strength: _strength.value,
              cats: projected,
            );
            return Stack(
              children: [
                // Catches the pointer over the whole map area. Without it
                // the lens would only track while the cursor happens to be
                // over a pin.
                const Positioned.fill(
                  child: ColoredBox(color: Color(0x00000000)),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _LeaderPainter(placements: placements),
                    ),
                  ),
                ),
                for (final placement in placements)
                  if (byId[placement.id] case final cat?)
                    _LensPin(
                      key: ValueKey(cat.id),
                      cat: cat,
                      placement: placement,
                      photo: _photoOf(cat),
                      onTap: () => widget.onSelect(cat),
                    ),
                // Drawn last, over the pins: the anchor is the answer to
                // "where is this cat really", and a pin sitting on top of
                // it would take that answer away exactly when the
                // displacement is largest.
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _AnchorPainter(placements: placements),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The line home. One logical pixel in the map chrome's own line colour,
/// with a small filled anchor on the cat's real coordinate: enough to
/// follow, quiet enough to sit under the pins without competing with the
/// streets.
class _LeaderPainter extends CustomPainter {
  const _LeaderPainter({required this.placements});

  final List<LensPlacement> placements;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = AppColors.lineStrong
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    for (final placement in placements) {
      if (placement.displacement < 4) continue;
      canvas.drawLine(placement.origin, placement.position, line);
    }
  }

  @override
  bool shouldRepaint(_LeaderPainter old) => old.placements != placements;
}

/// The true coordinates, over everything. A ring of page colour around each
/// one so it survives being drawn on top of a photograph.
class _AnchorPainter extends CustomPainter {
  const _AnchorPainter({required this.placements});

  final List<LensPlacement> placements;

  @override
  void paint(Canvas canvas, Size size) {
    final halo = Paint()..color = AppColors.bg;
    final anchor = Paint()..color = AppColors.ink;

    for (final placement in placements) {
      if (placement.displacement < 4) continue;
      canvas.drawCircle(placement.origin, 4, halo);
      canvas.drawCircle(placement.origin, 2.5, anchor);
    }
  }

  @override
  bool shouldRepaint(_AnchorPainter old) => old.placements != placements;
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
  final VoidCallback onTap;

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
        child: GestureDetector(
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
