import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../identity/session_identity.dart';

// Binding 12b palette (docs/design/app-states.md, states 12/12b; values
// from docs/design/screens/app-states.html) — deliberately local: the
// splash ground is the cream radial and the pads/tagline use the design
// file's literal colors, which are close to but not the same tokens as
// AppColors.
const _creamCenter = Color(0xFFFDF8F0);
const _creamEdge = Color(0xFFF2E2CD);
const _padInk = Color(0xFF2A211A);
const _pinBrick = Color(0xFFB5452F);
const _taglineFaint = Color(0xFF8A7563);
const _statusDim = Color(0xFFA08A70);

/// Launch splash for the adopted application-state contract's states 12 and
/// 12b (docs/design/app-states.md): the brand lockup — pin falls, paw pads
/// settle above it, the wordmark writes — on the cream radial ground,
/// superseding issue #85's full-terracotta lettermark composition (recorded
/// in docs/design/implementation-contract.md). The lockup is an app-state
/// illustration only, not a lasting brand change (gap 7): issue #24's
/// independent logo process stands.
///
/// Shown as an overlay above the router output (via MaterialApp.builder)
/// instead of a route of its own: deep links keep resolving underneath, and
/// dismissing is a fade — no navigation, so the restored-session/guest
/// destination logic stays exactly where it already lives. The gate holds
/// only until [sessionProvider]'s restore settles — no artificial minimum
/// display time, so a fast launch cuts the ~820 ms sequence mid-way (every
/// intermediate frame is presentable on its own) — capped at [_maxWait] so
/// an offline restore never pins the user here. The status line
/// ("yakındaki kediler getiriliyor…") appears only when launch exceeds
/// 1.6 s, per the timing contract.
///
/// Reduced motion (normative): with `disableAnimations` or
/// `accessibleNavigation` active nothing animates — the splash renders
/// 12b's settled composition and is removed without a fade the moment the
/// session settles.
///
/// On web this takes over seamlessly from the identical static splash in
/// web/index.html (removed on `flutter-first-frame`), which is what covers
/// the engine-download window where a white flash would otherwise show.
class SplashGate extends ConsumerStatefulWidget {
  const SplashGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends ConsumerState<SplashGate> {
  static const _maxWait = Duration(seconds: 2);
  static const _statusDelay = Duration(milliseconds: 1600);
  static const _fade = Duration(milliseconds: 200);

  Timer? _cap;
  Timer? _statusTimer;
  bool _capElapsed = false;
  bool _statusElapsed = false;
  bool _removed = false;

  @override
  void initState() {
    super.initState();
    // Already settled on first build (warm remount, or an
    // already-restored session provided from above): skip the overlay
    // entirely — AnimatedOpacity would start at 0 without ever
    // animating, so onEnd would never fire to remove it.
    if (!ref.read(sessionProvider).isLoading) {
      _removed = true;
      return;
    }
    _cap = Timer(_maxWait, () {
      if (mounted) setState(() => _capElapsed = true);
    });
    _statusTimer = Timer(_statusDelay, () {
      if (mounted) setState(() => _statusElapsed = true);
    });
  }

  @override
  void dispose() {
    _cap?.cancel();
    _statusTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Settled means restore finished (either way — a failed restore falls
    // back to guest inside SessionIdentityService, so AsyncError still
    // means "destination known") or the cap fired.
    final settled = !ref.watch(sessionProvider).isLoading || _capElapsed;
    final media = MediaQuery.of(context);
    final reduceMotion = media.disableAnimations || media.accessibleNavigation;
    // Reduced motion: the fade is an animation too — the overlay jumps
    // away the moment the session settles instead of fading.
    final gone = _removed || (settled && reduceMotion);
    return Stack(
      children: [
        widget.child,
        if (!gone)
          IgnorePointer(
            ignoring: settled,
            child: AnimatedOpacity(
              opacity: settled ? 0 : 1,
              duration: _fade,
              onEnd: () {
                if (mounted) setState(() => _removed = true);
              },
              child: _SplashView(showStatus: _statusElapsed),
            ),
          ),
      ],
    );
  }
}

/// The 12/12b composition: cream radial ground, the animated lockup, the
/// wordmark and tagline, and — past 1.6 s — the status line.
class _SplashView extends StatefulWidget {
  const _SplashView({required this.showStatus});

  final bool showStatus;

  @override
  State<_SplashView> createState() => _SplashViewState();
}

class _SplashViewState extends State<_SplashView>
    with SingleTickerProviderStateMixin {
  // The product target from state 12 — the reference page stretches the
  // same keyframe fractions to 3.4 s only so the sheet lift is visible.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 820),
  );

  bool _reduceMotion = false;

  // Reading MediaQuery here (not in build) both subscribes to changes and
  // keeps build side-effect free — mirrors _PulsingDot
  // (cat_update_sheet.dart). Reduced motion jumps straight to the settled
  // 12b frame.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    _reduceMotion = media.disableAnimations || media.accessibleNavigation;
    if (_reduceMotion) {
      _controller.stop();
      _controller.value = 1;
    } else if (!_controller.isAnimating && !_controller.isCompleted) {
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
    return Container(
      decoration: const BoxDecoration(
        // Approximates the reference's elliptical
        // `radial-gradient(120% 80% at 50% 34%)` — Flutter's radial
        // gradient is circular, so the center and reach carry the intent.
        gradient: RadialGradient(
          center: Alignment(0, -0.32),
          radius: 1.2,
          colors: [_creamCenter, _creamEdge],
        ),
      ),
      child: Stack(
        children: [
          Center(
            child: Padding(
              // The block sits above vertical center (12b: the reference
              // composition carries padding-bottom 70).
              padding: const EdgeInsets.only(bottom: 70),
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final t = _controller.value;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CustomPaint(
                        size: const Size(112, 123),
                        painter: _LockupPainter(t),
                      ),
                      const SizedBox(height: 26),
                      _Keyframed(
                        opacity: _seg(t, 0.44, 0.55),
                        dy: 9 * (1 - _seg(t, 0.44, 0.55)),
                        child: const Text(
                          'tekir',
                          textScaler: TextScaler.noScaling,
                          style: TextStyle(
                            fontFamily: 'Fraunces',
                            fontWeight: FontWeight.w600,
                            fontSize: 46,
                            height: 1.0,
                            letterSpacing: 46 * -0.045,
                            color: _padInk,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _Keyframed(
                        opacity: _seg(t, 0.50, 0.61),
                        dy: 0,
                        child: const Text(
                          'kim görüldü, kim beslendi',
                          textScaler: TextScaler.noScaling,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 13 * 0.04,
                            color: _taglineFaint,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          if (widget.showStatus)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 78,
              child: _StatusHint(),
            ),
        ],
      ),
    );
  }
}

/// Progress of the [a, b] slice of the timeline, clamped to 0..1.
double _seg(double t, double a, double b) => ((t - a) / (b - a)).clamp(0, 1);

class _Keyframed extends StatelessWidget {
  const _Keyframed({
    required this.opacity,
    required this.dy,
    required this.child,
  });

  final double opacity;
  final double dy;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: Transform.translate(offset: Offset(0, dy), child: child),
    );
  }
}

/// Draws the 112 × 123 lockup (200 × 220 viewBox: four ink paw pads over
/// the brick pin) at timeline position [t], reproducing the reference
/// keyframes: the pin falls with a bounce (tkPinFall), a landing ring
/// expands and fades (tkLand), then the pads settle in a stagger
/// (tkPad1–4). t = 1 is exactly the settled 12b frame.
class _LockupPainter extends CustomPainter {
  const _LockupPainter(this.t);

  final double t;

  static const _pads = [
    (cx: 40.0, cy: 78.0, rx: 15.5, ry: 20.0, deg: -30.0, start: 0.20),
    (cx: 79.0, cy: 51.0, rx: 17.5, ry: 22.6, deg: -11.0, start: 0.23),
    (cx: 122.0, cy: 51.5, rx: 17.5, ry: 22.6, deg: 12.0, start: 0.26),
    (cx: 161.0, cy: 79.0, rx: 15.5, ry: 20.0, deg: 31.0, start: 0.29),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 200;
    canvas.scale(scale, scale);

    // Landing ring: 120 px circle centered at (50%, 70%) of the lockup
    // box, expanding .2 → 2.6 while fading .5 → 0 (tkLand, 13–28%).
    final ringT = _seg(t, 0.13, 0.28);
    if (t >= 0.13 && ringT < 1) {
      // Display-px metrics (120 px circle, 2.5 px stroke) converted into
      // the 200-unit viewBox this canvas is scaled to.
      const toViewBox = 200 / 112;
      final ringPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5 * toViewBox
        ..color = _pinBrick.withValues(alpha: 0.5 * (1 - ringT));
      final ringScale = 0.2 + (2.6 - 0.2) * ringT;
      canvas.drawCircle(
        const Offset(100, 154),
        60 * toViewBox * ringScale,
        ringPaint,
      );
    }

    // Pin (tkPinFall, 4–20%): falls in from above with a small bounce.
    final pinOpacity = _seg(t, 0.04, 0.14);
    if (pinOpacity > 0) {
      final double dy;
      final double s;
      if (t < 0.14) {
        final k = _seg(t, 0.04, 0.14);
        dy = -120 + 127 * k;
        s = 0.55 + 0.52 * k;
      } else if (t < 0.17) {
        final k = _seg(t, 0.14, 0.17);
        dy = 7 - 10 * k;
        s = 1.07 - 0.09 * k;
      } else {
        final k = _seg(t, 0.17, 0.20);
        dy = -3 + 3 * k;
        s = 0.98 + 0.02 * k;
      }
      canvas.save();
      // The pin path's own center (viewBox units) — scale about it so the
      // bounce reads as the reference's transform-origin: center.
      const cx = 100.4, cy = 142.5;
      canvas.translate(cx, cy + dy);
      canvas.scale(s, s);
      canvas.translate(-cx, -cy);
      canvas.drawPath(
        _pinPath,
        Paint()..color = _pinBrick.withValues(alpha: pinOpacity),
      );
      canvas.restore();
    }

    // Paw pads (tkPad1–4): staggered rise, 10 px up, fading in.
    for (final pad in _pads) {
      final k = _seg(t, pad.start, pad.start + 0.11);
      if (k == 0) continue;
      canvas.save();
      canvas.translate(pad.cx, pad.cy + 10 * (1 - k));
      canvas.rotate(pad.deg * (3.1415926535 / 180));
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset.zero,
          width: pad.rx * 2,
          height: pad.ry * 2,
        ),
        Paint()..color = _padInk.withValues(alpha: k),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_LockupPainter oldDelegate) => oldDelegate.t != t;
}

/// The pin outline from the design's 200 × 220 viewBox, ported segment by
/// segment from the reference SVG path.
final Path _pinPath = Path()
  ..moveTo(100.5, 88)
  ..relativeCubicTo(30.5, 0, 49.5, 21, 48.8, 42.2)
  ..relativeCubicTo(-0.7, 21, -16.6, 36.6, -30.3, 51.2)
  ..relativeCubicTo(-6, 6.4, -11.9, 15.6, -18.6, 15.6)
  ..relativeCubicTo(-6.8, 0, -12.2, -9.4, -18.4, -15.9)
  ..cubicTo(68, 166.6, 51.5, 151, 51.5, 130.2)
  ..cubicTo(51.5, 109, 70, 88, 100.5, 88)
  ..close();

/// The late status line (timing contract: appears only past 1.6 s): three
/// breathing brick dots over "yakındaki kediler getiriliyor…". Reduced
/// motion renders the dots statically — nothing is hidden, nothing
/// breathes.
class _StatusHint extends StatefulWidget {
  const _StatusHint();

  @override
  State<_StatusHint> createState() => _StatusHintState();
}

class _StatusHintState extends State<_StatusHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    _reduceMotion = media.disableAnimations || media.accessibleNavigation;
    if (_reduceMotion) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _breathe(double phase) {
    if (_reduceMotion) return 1;
    // tkBreathe: 0%/100% at .45, 50% at 1 — a phase-shifted triangle wave
    // smoothed by the ease curve.
    final v = (_controller.value + phase) % 1.0;
    final tri = v < 0.5 ? v * 2 : (1 - v) * 2;
    return 0.45 + 0.55 * Curves.easeInOut.transform(tri);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(width: 7),
                  Opacity(
                    opacity: _breathe(-i * 0.125),
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        color: _pinBrick,
                        shape: BoxShape.circle,
                      ),
                      child: SizedBox(width: 7, height: 7),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 14),
        const Text(
          'yakındaki kediler getiriliyor…',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: _statusDim,
          ),
        ),
      ],
    );
  }
}
