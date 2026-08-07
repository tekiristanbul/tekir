import 'package:flutter/foundation.dart';

import 'env.dart';

/// Runs the mobile runtime configuration checks that must never block
/// startup (issue #131). [Env.apiBaseUrl] already fails fast on its own
/// for the one value that must — call it separately, before this. This
/// only surfaces problems that are designed to degrade instead: an
/// unrecognized `ANALYTICS_PROVIDER`/`NOTIFICATION_PROVIDER` would
/// otherwise fall back to its safe default silently.
///
/// Call once, as early as practical in `main()`, before the features that
/// read these values initialize.
void runStartupConfigDiagnostics() {
  for (final warning in Env.unrecognizedProviderWarnings()) {
    debugPrint('[config] $warning');
  }
}
