import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/analytics/analytics.dart';
import 'core/analytics/screen_view_logging.dart';
import 'core/config/env.dart';
import 'core/config/startup_validation.dart';
import 'core/firebase/firebase_bootstrap.dart';
import 'core/identity/device_identity.dart';
import 'core/identity/session_identity.dart';
import 'core/push/push_notifications.dart';
import 'core/router/app_router.dart';
import 'core/splash/splash_gate.dart';
import 'core/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Forces Env.apiBaseUrl resolution here, synchronously, before anything
  // else starts. Identity providers below also read it, but only inside
  // `.ignore()`d futures (fire-and-forget by design) — a missing
  // API_BASE_URL thrown there would never surface. Resolving it up front
  // means a release build without it crashes at startup instead (issue
  // #128 review).
  Env.apiBaseUrl;

  // Non-fatal config diagnostics (issue #131) — anything checked here
  // degrades to a safe default elsewhere instead of failing startup, so
  // this only logs; it never throws.
  runStartupConfigDiagnostics();

  // Firebase only comes up when a firebase-backed provider is selected
  // (issue #84); under the local none/fake defaults this returns false
  // without touching Firebase at all, and a failed init degrades to
  // noop-analytics/disabled-push rather than blocking startup.
  final firebaseReady = await bootstrapFirebase();

  final container = ProviderContainer(
    overrides: [firebaseReadyProvider.overrideWithValue(firebaseReady)],
  );

  attachScreenViewLogging(appRouter, container.read(analyticsProvider));
  // Hooks push token/message streams and handles a terminated-app
  // notification open; inert under the fake provider. Fire-and-forget —
  // first paint never waits on push plumbing.
  unawaited(container.read(pushNotificationsServiceProvider).start());

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const CatsOfIstanbulApp(),
    ),
  );
}

class CatsOfIstanbulApp extends ConsumerWidget {
  const CatsOfIstanbulApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Fire-and-forget: start identity initialization without blocking the UI.
    // Registration failures are silently ignored — public read routes remain
    // accessible. The interceptor attaches the token once init completes.
    ref.read(deviceIdentityProvider.future).ignore();
    // Restores a previously authenticated session (issue #58) by rotating
    // the stored refresh token, if any. A failed/expired/revoked session
    // falls back to the guest state safely — never blocks first paint.
    ref.read(sessionProvider.future).ignore();

    return MaterialApp.router(
      title: 'tekir',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      routerConfig: appRouter,
      // Splash overlays the router output until session restore settles
      // (issue #85) — a builder wrapper, not a route, so deep links and
      // the guest/restored-session destination logic stay untouched.
      builder: (context, child) =>
          SplashGate(child: child ?? const SizedBox.shrink()),
    );
  }
}
