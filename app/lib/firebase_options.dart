// Placeholder until `flutterfire configure` is run against the real
// Firebase project (issue #84, DEVELOPMENT.md "firebase"). The FlutterFire
// cli overwrites this file with the project's public client configuration —
// which is committable per SECURITY.md/issue #84 (client config is not a
// secret; the service-account json used by the backend notifier is, and
// never lives in the repo).
//
// Until then, [DefaultFirebaseOptions.currentPlatform] throws, and
// bootstrapFirebase (main.dart) catches it: the app runs normally with
// analytics and push simply disabled.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    throw UnsupportedError(
      'firebase is not configured — run `flutterfire configure` '
      '(DEVELOPMENT.md "firebase") to generate this file.',
    );
  }
}
