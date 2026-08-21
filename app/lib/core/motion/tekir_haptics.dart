import 'package:flutter/services.dart';

/// tekir's haptic vocabulary, named by meaning rather than by intensity.
///
/// Haptics acknowledge *contribution* — an update, a help mark, a follow —
/// never navigation. Opening a screen is not an act of care and does not
/// earn a tap on the wrist; recording that a cat was fed does.
///
/// Routing every call through this class is what makes the product rule
/// "a help mark is felt harder than a görüldü" enforceable rather than a
/// convention each call site re-decides, and it keeps the whole channel
/// mutable from one place.
///
/// Reduced motion never silences these. A haptic is feedback confirming an
/// action, not movement, and the accessibility contract
/// (docs/design/app-states.md) removes travel, not confirmation. The
/// platform's own haptics switch is respected underneath: both
/// `selectionClick` and the impact calls go through the OS feedback APIs,
/// which no-op when the user has turned system haptics off.
class TekirHaptics {
  const TekirHaptics._();

  /// A discrete selection changed: a status pill toggled, a segment
  /// switched, a marker selected, a tab changed. The lightest thing in the
  /// vocabulary — it says "registered", not "done".
  static Future<void> acknowledge() => HapticFeedback.selectionClick();

  /// A write the user asked for has been confirmed by the server: an
  /// update posted, a follow persisted, a photo uploaded. The moment the
  /// optimistic guess turns out to have been right.
  static Future<void> committed() => HapticFeedback.lightImpact();

  /// The loudest signal in the app, reserved for the `yardıma ihtiyacı var`
  /// mark. This is the one action that pages other people
  /// (docs/product/alerts.md), and it must not feel like "görüldü" in the
  /// hand any more than it looks like it on screen.
  static Future<void> raised() => HapticFeedback.heavyImpact();

  /// Something the user asked for did not happen: a failed submission, a
  /// reverted optimistic toggle. Paired with the visible error, never a
  /// substitute for it.
  static Future<void> refused() => HapticFeedback.mediumImpact();
}
