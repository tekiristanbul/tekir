import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../firebase_options.dart';
import '../config/env.dart';

/// Whether [bootstrapFirebase] brought a Firebase app up this process.
/// Overridden with the real result in main(); analytics and push wiring
/// key off it so a missing or broken Firebase configuration degrades to
/// noop/disabled instead of crashing or blocking anything (issue #84).
final firebaseReadyProvider = Provider<bool>((_) => false);

/// Initializes Firebase only when a firebase-backed provider is actually
/// selected (`ANALYTICS_PROVIDER=firebase` and/or
/// `NOTIFICATION_PROVIDER=fcm`). Under the local defaults (none/fake) this
/// is a no-op and no Firebase code runs at all. Failure — most commonly
/// the placeholder firebase_options.dart before `flutterfire configure`
/// has been run — is logged in debug and reported as not-ready, never
/// thrown: the product must keep working without Firebase.
Future<bool> bootstrapFirebase() async {
  if (Env.analyticsProvider != 'firebase' &&
      Env.notificationProvider != 'fcm') {
    return false;
  }
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    return true;
  } catch (error) {
    if (kDebugMode) {
      debugPrint('[firebase] init failed, analytics/push disabled: $error');
    }
    return false;
  }
}
