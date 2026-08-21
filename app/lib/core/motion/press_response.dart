import 'package:flutter/widgets.dart';

import 'tekir_motion.dart';

/// The one press behavior every tekir control shares: the control gives
/// slightly under the finger while it is held, and returns when released.
///
/// This is the difference between a control that acknowledges the *finger*
/// and one that only acknowledges the completed *tap*. Before this, nothing
/// in the app responded to touch-down at all — every control waited for
/// tap-up and the round trip that followed it.
///
/// Wraps rather than replaces. A [Listener] observes pointer events without
/// competing in hit testing, so the child's own `InkWell`/`GestureDetector`
/// still receives the tap, keeps its ink, and keeps its semantics. That
/// matters: this is applied over existing controls, and none of them change
/// shape, color, or behavior to accommodate it.
///
/// Under reduced motion the scale is dropped entirely — it is travel, not
/// state, and the control's own ink and color changes already carry the
/// feedback.
class PressResponse extends StatefulWidget {
  const PressResponse({
    super.key,
    required this.child,
    this.scale = 0.97,
    this.enabled = true,
  });

  final Widget child;

  /// How far the control gives. Deliberately small: at this size the effect
  /// is felt rather than watched, which is the point — a control that
  /// visibly shrinks reads as a toy.
  final double scale;

  /// False for a disabled control, which must not appear to respond.
  final bool enabled;

  @override
  State<PressResponse> createState() => _PressResponseState();
}

class _PressResponseState extends State<PressResponse> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (!widget.enabled || _pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final motion = TekirMotion.of(context);
    // Reduced motion: no transform at all, rather than a zero-duration jump
    // to a smaller size — the scale is pure travel, so it is removed, not
    // accelerated.
    final target = (_pressed && !motion.reduced) ? widget.scale : 1.0;

    return Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: target,
        duration: motion(TekirMotion.tap),
        curve: TekirMotion.enter,
        child: widget.child,
      ),
    );
  }
}
