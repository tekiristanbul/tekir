import 'package:flutter/widgets.dart';

/// tekir's motion tokens and the single reduced-motion gate every animated
/// surface routes through.
///
/// Durations express distance and consequence, not taste: a press
/// acknowledges in [tap], a value changes in [state], a surface arrives in
/// [surface], and something that just landed settles back down over
/// [settle]. Arrivals decelerate ([enter]); exits leave one step faster
/// ([exit]), because a slow exit reads as latency.
///
/// The reduced-motion condition (`MediaQuery.disableAnimations ||
/// accessibleNavigation`, normative per docs/design/app-states.md) is
/// defined here once. Widgets ask [TekirMotion.of] for a duration rather
/// than re-deriving the condition themselves — the drift that convention
/// prevents already happened once, in cat_update_sheet.dart's `_PulsingDot`,
/// which checks only `disableAnimations` and keeps pulsing under a screen
/// reader.
///
/// Reduced motion means *fewer and gentler* animations, not silence: a
/// duration collapses to zero so the state change still happens, in the
/// same frame. Feedback that confirms an action — a color change, an icon
/// swap, a haptic — is never removed by this gate, only its travel is.
@immutable
class TekirMotion {
  const TekirMotion._(this.animate);

  /// False when the platform asks for reduced motion; every duration this
  /// instance hands out is then [Duration.zero].
  final bool animate;

  /// Immediate acknowledgment of a touch: press scale, ink, tick.
  static const tap = Duration(milliseconds: 120);

  /// A routine state change: a value updating, a selection moving, a tint
  /// rising.
  static const state = Duration(milliseconds: 200);

  /// A surface arriving or leaving: sheet, overlay, view transition.
  static const surface = Duration(milliseconds: 320);

  /// Something that just landed returning to rest — deliberately the
  /// slowest step, so a settle reads as release rather than as another
  /// event.
  static const settle = Duration(milliseconds: 420);

  /// Confident arrival. Never a bounce or elastic curve: an update is a
  /// record being entered, not a reward.
  static const enter = Curves.easeOutCubic;

  /// Departure, paired with a shorter duration than the entrance it undoes.
  static const exit = Curves.easeInCubic;

  /// Resolves the platform's reduced-motion preference. Subscribes to it,
  /// so a widget built with this rebuilds when the user flips the setting
  /// mid-session.
  factory TekirMotion.of(BuildContext context) {
    final media = MediaQuery.of(context);
    return TekirMotion._(
      !(media.disableAnimations || media.accessibleNavigation),
    );
  }

  /// [duration], or [Duration.zero] under reduced motion.
  Duration call(Duration duration) => animate ? duration : Duration.zero;

  /// True when the platform asks for reduced motion — for the cases that
  /// need to drop an effect entirely (a repeating loop, a travelling
  /// transform) rather than merely run it in zero time.
  bool get reduced => !animate;
}
