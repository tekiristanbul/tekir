import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/motion/press_response.dart';
import 'package:app/core/motion/tekir_motion.dart';

Widget _wrap({
  required Widget child,
  bool disableAnimations = false,
  bool accessibleNavigation = false,
}) {
  return MediaQuery(
    data: MediaQueryData(
      disableAnimations: disableAnimations,
      accessibleNavigation: accessibleNavigation,
    ),
    child: Directionality(textDirection: TextDirection.ltr, child: child),
  );
}

/// PressResponse defers hit testing to its child, exactly as it does over a
/// real control — so the child here is an actual tappable one rather than a
/// bare box, which would never receive the pointer at all.
Widget _pressable({VoidCallback? onTap}) {
  return Material(
    child: PressResponse(
      child: InkWell(
        onTap: onTap ?? () {},
        child: const SizedBox(width: 80, height: 44),
      ),
    ),
  );
}

/// The scale PressResponse is currently driving toward. Read from the
/// widget rather than the rendered matrix: what belongs to this component
/// is the target and the duration it is given — the interpolation between
/// them is the framework's.
AnimatedScale _scaleWidget(WidgetTester tester) {
  return tester.widget<AnimatedScale>(
    find.descendant(
      of: find.byType(PressResponse),
      matching: find.byType(AnimatedScale),
    ),
  );
}

void main() {
  group('TekirMotion', () {
    testWidgets('hands out its real durations by default', (tester) async {
      late TekirMotion motion;
      await tester.pumpWidget(
        _wrap(
          child: Builder(
            builder: (context) {
              motion = TekirMotion.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(motion.reduced, isFalse);
      expect(motion(TekirMotion.state), TekirMotion.state);
      expect(motion(TekirMotion.surface), TekirMotion.surface);
    });

    testWidgets('collapses every duration when animations are disabled', (
      tester,
    ) async {
      late TekirMotion motion;
      await tester.pumpWidget(
        _wrap(
          disableAnimations: true,
          child: Builder(
            builder: (context) {
              motion = TekirMotion.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(motion.reduced, isTrue);
      expect(motion(TekirMotion.state), Duration.zero);
      expect(motion(TekirMotion.settle), Duration.zero);
    });

    // accessibleNavigation is the screen-reader signal, and the state
    // contract names it alongside disableAnimations — a widget that checked
    // only the latter (as cat_update_sheet's pulsing dot once did) keeps
    // animating under VoiceOver/TalkBack.
    testWidgets('treats accessibleNavigation as reduced motion too', (
      tester,
    ) async {
      late TekirMotion motion;
      await tester.pumpWidget(
        _wrap(
          accessibleNavigation: true,
          child: Builder(
            builder: (context) {
              motion = TekirMotion.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(motion.reduced, isTrue);
      expect(motion(TekirMotion.tap), Duration.zero);
    });
  });

  group('PressResponse', () {
    testWidgets('gives under the finger and returns on release', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(child: _pressable()));

      expect(_scaleWidget(tester).scale, 1.0);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(InkWell)),
      );
      await tester.pump();
      expect(_scaleWidget(tester).scale, lessThan(1.0));
      expect(_scaleWidget(tester).duration, TekirMotion.tap);

      await gesture.up();
      await tester.pump();
      expect(_scaleWidget(tester).scale, 1.0);
    });

    testWidgets('never moves under reduced motion', (tester) async {
      await tester.pumpWidget(
        _wrap(disableAnimations: true, child: _pressable()),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(InkWell)),
      );
      await tester.pump();
      expect(_scaleWidget(tester).scale, 1.0);
      expect(_scaleWidget(tester).duration, Duration.zero);

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('lets the wrapped control keep receiving taps', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_wrap(child: _pressable(onTap: () => taps++)));

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();

      expect(taps, 1);
    });
  });
}
