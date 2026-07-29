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
  Future<void> save(SessionIdentity identity) async {}

  @override
  Future<void> logout({String? deviceToken}) async {}
}

Widget _app(SessionIdentityService service) {
  return ProviderScope(
    overrides: [sessionIdentityServiceProvider.overrideWithValue(service)],
    child: MaterialApp(
      theme: AppTheme.light,
      home: const SplashGate(child: Text('underlying app')),
    ),
  );
}

void main() {
  testWidgets('shows the prototype splash composition while restoring', (
    tester,
  ) async {
    final service = _ControlledSessionService();
    await tester.pumpWidget(_app(service));

    expect(find.text('tekir'), findsOneWidget);
    expect(
      find.text("İstanbul'un sokak kedilerini keşfet, onlara göz kulak ol."),
      findsOneWidget,
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

  testWidgets('never outlives the cap when restore hangs', (tester) async {
    final service = _ControlledSessionService();
    await tester.pumpWidget(_app(service));

    await tester.pump(const Duration(milliseconds: 1900));
    expect(find.text('tekir'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 200)); // cap at 2s
    await tester.pump(const Duration(milliseconds: 250)); // fade
    await tester.pump();

    expect(find.text('tekir'), findsNothing);
    expect(find.text('underlying app'), findsOneWidget);
  });
}
