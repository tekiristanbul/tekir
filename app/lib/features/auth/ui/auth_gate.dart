import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/analytics/analytics.dart';
import '../../../core/identity/session_identity.dart';
import '../../../core/theme/app_theme.dart';

/// Gates an authenticated action at the point of intent, mirroring the
/// prototype's `requireLogin`/`openAuthSheet`/`resumePendingAction`
/// mechanism (prototype/app.js:102-131) exactly: no route guard or
/// redirect exists (or is needed) anywhere in the router — public browsing
/// stays reachable, and gating happens only when a specific action is
/// tapped, not by navigating to a URL.
///
/// This issue builds and tests the mechanism itself; no existing feature
/// (follow, add-update, add-cat) is rewired to call it yet — those gated
/// actions are each their own issue's scope.
class AuthGate {
  const AuthGate._();

  /// Runs [onAuthenticated] immediately if a session is already cached.
  /// Otherwise shows the auth-prompt sheet (mirrors the prototype's
  /// `#authSheet`); if the user chooses to continue, pushes the full login
  /// screen and runs [onAuthenticated] only once that flow completes
  /// successfully — never on cancel, back, or a failed attempt.
  ///
  /// [intent] is the bounded auth_intent vocabulary value for the gate's
  /// analytics events (issue #84): auth_gate_shown when a guest actually
  /// sees the prompt (never for an already-authenticated fall-through),
  /// then exactly one of auth_completed / auth_failed for how the gate
  /// resolved — the core "do guests cross the gate when they intend to
  /// contribute" funnel.
  static Future<void> require(
    BuildContext context,
    WidgetRef ref, {
    required String contextText,
    required AnalyticsAuthIntent intent,
    required VoidCallback onAuthenticated,
  }) async {
    if (ref.read(sessionIdentityServiceProvider).cached != null) {
      onAuthenticated();
      return;
    }

    final analytics = ref.read(analyticsProvider);
    analytics.log(AnalyticsEvent.authGateShown(intent));

    final proceed = await showModalBottomSheet<bool>(
      context: context,
      // issue #80 product-owner review: callers now include the shell's
      // persistent add-cat fab (app_shell.dart) and other widgets whose
      // context lives inside a StatefulShellRoute branch's own nested
      // Navigator — the default nearest-Navigator target would paint this
      // sheet underneath that shell chrome instead of above the whole app.
      useRootNavigator: true,
      builder: (_) => _AuthPromptSheet(contextText: contextText),
    );
    if (proceed != true || !context.mounted) {
      analytics.log(
        AnalyticsEvent.authFailed(intent, AnalyticsResult.cancelled),
      );
      return;
    }

    final success = await context.push<bool>('/login', extra: contextText);
    if (success == true) {
      analytics.log(AnalyticsEvent.authCompleted(intent));
      onAuthenticated();
    } else {
      // backed out of or abandoned the login screen — per-attempt server
      // failures are the login screen's own ui concern; the funnel only
      // records that this gate crossing didn't complete.
      analytics.log(
        AnalyticsEvent.authFailed(intent, AnalyticsResult.cancelled),
      );
    }
  }
}

/// Mirrors the prototype's `#authSheet`: a phone icon, the contextual
/// reason text, and "Vazgeç"/"Giriş yap" buttons (prototype/app.js:107-120).
class _AuthPromptSheet extends StatelessWidget {
  const _AuthPromptSheet({required this.contextText});

  final String contextText;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s5,
        AppSpacing.s6,
        AppSpacing.s5,
        AppSpacing.s6,
      ),
      decoration: const BoxDecoration(
        color: AppColors.bgElevated,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              margin: const EdgeInsets.only(bottom: AppSpacing.s3),
              decoration: const BoxDecoration(
                color: AppColors.primarySoft,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.phone,
                size: 22,
                color: AppColors.primaryStrong,
              ),
            ),
            Text(
              contextText,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.s5),
            SizedBox(
              height: kTapMin,
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.primaryInk,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
                child: const Text('Giriş yap'),
              ),
            ),
            const SizedBox(height: AppSpacing.s2),
            SizedBox(
              height: kTapMin,
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Vazgeç'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
