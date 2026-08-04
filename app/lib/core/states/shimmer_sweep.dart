import 'dart:async';

import 'package:flutter/material.dart';

/// The shared skeleton shimmer (docs/design/app-states.md, states 13/14):
/// a soft highlight sweeping across a skeleton shape every 1.5 s. [delay]
/// staggers rows so a list doesn't flash in lockstep.
///
/// Under reduced motion (`MediaQuery.disableAnimations` or
/// `accessibleNavigation`) the sweep never runs: the child renders as its
/// settled frame, nothing hidden, nothing moving.
class ShimmerSweep extends StatefulWidget {
  const ShimmerSweep({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.borderRadius,
  });

  final Widget child;

  /// Stagger offset before this sweep starts repeating.
  final Duration delay;

  /// Clips the sweep overlay to the child's rounded shape.
  final BorderRadius? borderRadius;

  @override
  State<ShimmerSweep> createState() => _ShimmerSweepState();
}

class _ShimmerSweepState extends State<ShimmerSweep>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  Timer? _startTimer;
  bool _reduceMotion = false;

  // Reading MediaQuery here (not in build) both subscribes to changes and
  // keeps build side-effect free — mirrors _PulsingDot's convention
  // (cat_update_sheet.dart).
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    _reduceMotion = media.disableAnimations || media.accessibleNavigation;
    if (_reduceMotion) {
      _startTimer?.cancel();
      _startTimer = null;
      _controller.stop();
    } else if (!_controller.isAnimating && _startTimer == null) {
      _startTimer = Timer(widget.delay, () {
        if (mounted && !_reduceMotion) _controller.repeat();
      });
    }
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_reduceMotion) return widget.child;

    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: ClipRRect(
              borderRadius: widget.borderRadius ?? BorderRadius.zero,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final t = Curves.easeInOut.transform(_controller.value);
                  return Align(
                    alignment: Alignment(-1.5 + 3 * t, 0),
                    child: FractionallySizedBox(
                      widthFactor: 0.55,
                      heightFactor: 1,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Color(0x00FFFFFF),
                              Color(0xBFFFFFFF),
                              Color(0x00FFFFFF),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}
