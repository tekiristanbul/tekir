import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/images/decode_budget.dart';
import '../../../core/motion/hero_tags.dart';
import '../../../core/motion/tekir_motion.dart';
import '../../../core/theme/app_theme.dart';
import '../data/cat_marker.dart';
import '../ui/cat_preview_sheet.dart';

/// Concept 3's two pieces: a preview surface a shared element can actually
/// fly into, and the pin on the map that it flies from.
///
/// ## The defect this concept starts from
///
/// The shipped app already tags the preview sheet's photo and the cat
/// detail's avatar with the same hero tag
/// (core/motion/hero_tags.dart), and map_screen.dart keeps the sheet on
/// the stack for 500 ms after pushing the detail specifically so "the
/// shared photo's flight has a source to leave from". That flight has
/// never happened. Flutter's [HeroController] starts a flight only when
/// *both* routes are [PageRoute]s:
///
///     if (toRoute == fromRoute || toRoute is! PageRoute || fromRoute is! PageRoute) return;
///
/// and `showModalBottomSheet` pushes a `ModalBottomSheetRoute`, which
/// extends `PopupRoute`, not `PageRoute`. The sheet retreats and the detail
/// arrives; the two photos have never been connected. This is verified in
/// test/features/map/spike/cat_carry_test.dart rather than asserted.
///
/// ## What this route changes
///
/// [CatPreviewPageRoute] presents the same [CatPreviewSheet] widget,
/// unmodified, as a non-opaque [PageRoute]. That single change makes both
/// legs of the journey work with the machinery already in the app: the pin
/// on the map flies into the sheet's photo, and the sheet's photo flies on
/// into the detail's avatar, with the detail's own `flightShuttleBuilder`
/// rounding the square into a circle exactly as it was written to.
///
/// What it costs is the material sheet's built-in drag-to-dismiss, which
/// is reimplemented below, and the sheet's platform-owned presentation.
/// That trade is the concept's main open question, not a detail — see
/// docs/design/interaction-spike-280.md.
class CatPreviewPageRoute<T> extends PageRoute<T> {
  CatPreviewPageRoute({required this.cat, required this.onOpenDetail});

  final CatMarker cat;
  final VoidCallback onOpenDetail;

  @override
  Color get barrierColor => AppColors.overlay;

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => 'kapat';

  @override
  bool get opaque => false;

  @override
  bool get maintainState => true;

  // Read once at push time rather than per-frame: a route's transition
  // duration is consulted when the animation is created, so the
  // reduced-motion gate has to be applied by whoever pushes it. See
  // [CatPreviewPageRoute.push].
  Duration _duration = TekirMotion.surface;

  @override
  Duration get transitionDuration => _duration;

  @override
  Duration get reverseTransitionDuration => _duration;

  /// Pushes the preview for [cat], with the reduced-motion gate applied to
  /// the route's own transition. Returns the route so the caller can wait
  /// out the return flight before restoring the map's real marker.
  static CatPreviewPageRoute<void> push(
    BuildContext context, {
    required CatMarker cat,
    required VoidCallback onOpenDetail,
  }) {
    final motion = TekirMotion.of(context);
    final route = CatPreviewPageRoute<void>(
      cat: cat,
      onOpenDetail: onOpenDetail,
    ).._duration = motion(TekirMotion.surface);
    Navigator.of(context, rootNavigator: true).push(route);
    return route;
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _DragToDismiss(
      child: Align(
        alignment: Alignment.bottomCenter,
        // The shipped sheet itself, not a copy: the concept changes how
        // this surface arrives, never what it says, and reusing the real
        // widget is what keeps that claim true as the sheet's content
        // changes.
        child: CatPreviewSheet(cat: cat, onOpenDetail: onOpenDetail),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // The surface rises; it does not fade. A fading sheet reads as an
    // overlay appearing, and this one is arriving from somewhere.
    return SlideTransition(
      position: Tween(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).chain(CurveTween(curve: TekirMotion.enter)).animate(animation),
      child: child,
    );
  }
}

/// Drag-down dismissal, which the material sheet gave for free and a
/// [PageRoute] does not. Deliberately minimal — enough to evaluate the
/// concept, not a replacement for the platform behaviour.
class _DragToDismiss extends StatefulWidget {
  const _DragToDismiss({required this.child});

  final Widget child;

  @override
  State<_DragToDismiss> createState() => _DragToDismissState();
}

class _DragToDismissState extends State<_DragToDismiss> {
  double _offset = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragUpdate: (details) {
        setState(() => _offset = (_offset + details.delta.dy).clamp(0, 400));
      },
      onVerticalDragEnd: (details) {
        final flung =
            details.primaryVelocity != null && details.primaryVelocity! > 700;
        if (flung || _offset > 88) {
          Navigator.of(context).maybePop();
        } else {
          setState(() => _offset = 0);
        }
      },
      child: Transform.translate(
        offset: Offset(0, _offset),
        child: widget.child,
      ),
    );
  }
}

/// The pin the flight leaves from: the same cat, at the same place on
/// screen the native marker occupied, drawn in Flutter so a hero can pick
/// it up. The map hides its own marker for this cat while this exists, so
/// there is never a moment with two of the same cat on screen.
class CarryGhostPin extends StatelessWidget {
  const CarryGhostPin({
    super.key,
    required this.cat,
    required this.center,
    this.size = 66,
  });

  final CatMarker cat;

  /// Where the native marker was, in logical pixels, from the map's own
  /// projection.
  final Offset center;

  final double size;

  @override
  Widget build(BuildContext context) {
    final motion = TekirMotion.of(context);
    return Positioned(
      left: center.dx - size / 2,
      top: center.dy - size / 2,
      width: size,
      height: size,
      child: IgnorePointer(
        // Reduced motion removes the flight, not the destination: with
        // heroes off the preview simply appears with its photo in place,
        // which is the shipped behaviour, and nothing travels.
        child: HeroMode(
          enabled: !motion.reduced,
          child: Hero(
            tag: catPhotoHeroTag(cat.id),
            createRectTween: (begin, end) =>
                MaterialRectCenterArcTween(begin: begin, end: end),
            flightShuttleBuilder: (_, animation, direction, _, _) =>
                _CarryShuttle(
                  animation: animation,
                  direction: direction,
                  photo: cat.primaryPhoto,
                ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: cat.needsHelp ? AppColors.help : AppColors.primary,
                  width: cat.needsHelp ? 4 : 2,
                ),
              ),
              child: ClipOval(
                child: _CarriedPhoto(url: cat.primaryPhoto, size: size),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The in-flight photo. Rounds from the pin's circle to the preview's
/// rounded square across the flight, in the same direction-aware way the
/// cat detail's own shuttle does.
class _CarryShuttle extends StatelessWidget {
  const _CarryShuttle({
    required this.animation,
    required this.direction,
    required this.photo,
  });

  final Animation<double> animation;
  final HeroFlightDirection direction;
  final String photo;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.biggest.shortestSide;
        final circle = side / 2;
        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final progress = direction == HeroFlightDirection.push
                ? animation.value
                : 1 - animation.value;
            final t = TekirMotion.enter.transform(progress.clamp(0.0, 1.0));
            return ClipRRect(
              borderRadius: BorderRadius.circular(
                circle + (AppRadius.lg - circle) * t,
              ),
              child: child,
            );
          },
          child: _CarriedPhoto(url: photo, size: side),
        );
      },
    );
  }
}

class _CarriedPhoto extends StatelessWidget {
  const _CarriedPhoto({required this.url, required this.size});

  final String url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      color: AppColors.primarySoft,
      child: const Icon(Icons.pets, size: 28, color: AppColors.primaryStrong),
    );
    if (url.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        memCacheWidth: decodeWidthFor(context, size),
        errorWidget: (context, _, _) => fallback,
      ),
    );
  }
}
