import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/splash/splash_gate.dart';
import 'package:app/core/theme/app_theme.dart';

/// Session restore that stays pending until [complete] is called, so tests
/// control exactly when the splash is allowed to settle.
class _ControlledSessionService implements SessionIdentityService {
  final _completer = Completer<SessionIdentity?>();

  void complete() => _completer.complete(null);

  @override
  SessionIdentity? get cached => null;

  @override
  Future<SessionIdentity?> restore() => _completer.future;

  @override
  Future<SessionIdentity?> refreshIfExpired() async => null;

  @override
  Future<void> save(SessionIdentity identity) async {}

  @override
  Future<void> logout({String? deviceToken}) async {}
}

Widget _app(SessionIdentityService service, {bool reduceMotion = false}) {
  return ProviderScope(
    overrides: [sessionIdentityServiceProvider.overrideWithValue(service)],
    child: MaterialApp(
      theme: AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: const SplashGate(child: Text('underlying app')),
    ),
  );
}

void main() {
  testWidgets('shows the 12b lockup composition while restoring', (
    tester,
  ) async {
    final service = _ControlledSessionService();
    await tester.pumpWidget(_app(service));
    // Let the ~820 ms sequence finish so the settled frame is asserted.
    await tester.pump(const Duration(milliseconds: 900));

    expect(find.text('tekir'), findsOneWidget);
    expect(find.text('kim görüldü, kim beslendi'), findsOneWidget);
    // issue #85's superseded composition is gone.
    expect(
      find.text("İstanbul'un sokak kedilerini keşfet, onlara göz kulak ol."),
      findsNothing,
    );

    service.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('fades out as soon as session restore settles', (tester) async {
    final service = _ControlledSessionService();
    await tester.pumpWidget(_app(service));
    expect(find.text('tekir'), findsOneWidget);

    service.complete();
    await tester.pump(); // restore future resolves
    await tester.pump(); // AsyncData lands, fade starts
    await tester.pump(const Duration(milliseconds: 250)); // fade runs out
    await tester.pump(); // onEnd removes the overlay

    expect(find.text('tekir'), findsNothing);
    expect(find.text('underlying app'), findsOneWidget);
  });

  testWidgets('the status line appears only when launch exceeds 1.6 s', (
    tester,
  ) async {
    final service = _ControlledSessionService();
    await tester.pumpWidget(_app(service));

    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('yakındaki kediler getiriliyor…'), findsNothing);

    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('yakındaki kediler getiriliyor…'), findsOneWidget);

    service.complete();
    // Bounded pumps: the status dots breathe on a repeating controller,
    // so pumpAndSettle would hang while they're visible.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(find.text('yakındaki kediler getiriliyor…'), findsNothing);
  });

  testWidgets(
    'the status line never pops in during the fade when restore settles '
    'just before 1.6 s',
    (tester) async {
      final service = _ControlledSessionService();
      await tester.pumpWidget(_app(service));

      await tester.pump(const Duration(milliseconds: 1500));
      service.complete();
      await tester.pump(); // restore future resolves
      await tester.pump(); // AsyncData lands, fade starts
      // The 1.6 s timer fires mid-fade — the line must stay absent.
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('yakındaki kediler getiriliyor…'), findsNothing);

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('tekir'), findsNothing);
    },
  );

  testWidgets('never outlives the cap when restore hangs', (tester) async {
    final service = _ControlledSessionService();
    await tester.pumpWidget(_app(service));

    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('tekir'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 600)); // cap at 2s
    await tester.pump(const Duration(milliseconds: 250)); // fade
    await tester.pump();

    expect(find.text('tekir'), findsNothing);
    expect(find.text('underlying app'), findsOneWidget);
  });

  testWidgets(
    'reduced motion: the settled composition renders with no animation and '
    'the overlay jumps away without a fade',
    (tester) async {
      final service = _ControlledSessionService();
      await tester.pumpWidget(_app(service, reduceMotion: true));
      // No pending frames: nothing animates under reduced motion.
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
      expect(find.text('tekir'), findsOneWidget);
      expect(find.text('kim görüldü, kim beslendi'), findsOneWidget);

      service.complete();
      await tester.pump(); // restore future resolves
      await tester.pump(); // AsyncData lands — overlay jumps, no fade

      expect(find.text('tekir'), findsNothing);
      expect(find.text('underlying app'), findsOneWidget);
    },
  );
}
