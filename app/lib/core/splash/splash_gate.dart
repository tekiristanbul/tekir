import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../identity/session_identity.dart';
import '../theme/app_theme.dart';

/// Prototype-aligned launch splash (issue #85): full-bleed terracotta with
/// the temporary lettermark tile, `tekir` wordmark, and tagline — the exact
/// composition of prototype/app.js's renderSplash / styles.css's
/// .splash-screen, with the placeholder paw replaced by the wordmark-derived
/// temporary mark (assets/brand/temporary, issue #85's "no paw prints"
/// direction).
///
/// Shown as an overlay above the router output (via MaterialApp.builder)
/// instead of a route of its own: deep links keep resolving underneath, and
/// dismissing is a fade — no navigation, so the restored-session/guest
/// destination logic stays exactly where it already lives (nothing routes
/// here). Unlike the prototype's fixed 1100 ms timer, this holds only until
/// [sessionProvider]'s restore settles (issue #85 amendment: no artificial
/// branding delay), capped at [_maxWait] so an offline restore — whose
/// network rotation can run into its 10 s receive timeout before falling
/// back to guest — never pins the user to the splash; the app below is
/// already usable as guest while the restore keeps running.
///
/// On web this takes over seamlessly from the identical static splash in
/// web/index.html (removed on `flutter-first-frame`), which is what covers
/// the engine-download window where a white flash would otherwise show.
class SplashGate extends ConsumerStatefulWidget {
  const SplashGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends ConsumerState<SplashGate> {
  static const _maxWait = Duration(seconds: 2);
  static const _fade = Duration(milliseconds: 200);

  Timer? _cap;
  bool _capElapsed = false;
  bool _removed = false;

  @override
  void initState() {
    super.initState();
    _cap = Timer(_maxWait, () {
      if (mounted) setState(() => _capElapsed = true);
    });
  }

  @override
  void dispose() {
    _cap?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Settled means restore finished (either way — a failed restore falls
    // back to guest inside SessionIdentityService, so AsyncError still
    // means "destination known") or the cap fired.
    final settled = !ref.watch(sessionProvider).isLoading || _capElapsed;
    return Stack(
      children: [
        widget.child,
        if (!_removed)
          IgnorePointer(
            ignoring: settled,
            child: AnimatedOpacity(
              opacity: settled ? 0 : 1,
              duration: _fade,
              onEnd: () {
                if (mounted) setState(() => _removed = true);
              },
              child: const _SplashView(),
            ),
          ),
      ],
    );
  }
}

class _SplashView extends StatelessWidget {
  const _SplashView();

  @override
  Widget build(BuildContext context) {
    // Mark and wordmark are the brand lockup, not content — they keep the
    // canonical size under large system text scaling (the tile would
    // overflow otherwise); the tagline is content and scales normally,
    // with scroll absorbing the overflow on small screens.
    return Material(
      color: AppColors.primary,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s6,
            vertical: AppSpacing.s8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppRadius.xl),
                ),
                // Anchored by baseline, not by line box: how engines split
                // a line box around the baseline varies (the test renderer
                // sat the glyph 6 px low), but the baseline itself is
                // stable. At fontSize 66 Fraunces-600's `t` outline spans
                // 39.40 px above / 0.69 px below the baseline (bbox
                // -20.8..1194.0 of 2000 upem — see assets/scripts/
                // generate.py, which derives the exported mark from the
                // same instance), so a baseline 61.4 px from the tile top
                // centers the 40.1 px glyph in the 84 px tile.
                child: const Align(
                  alignment: Alignment.topCenter,
                  child: Baseline(
                    baseline: 61.4,
                    baselineType: TextBaseline.alphabetic,
                    child: Text(
                      't',
                      textScaler: TextScaler.noScaling,
                      style: TextStyle(
                        fontFamily: 'Fraunces',
                        fontWeight: FontWeight.w600,
                        fontSize: 66,
                        height: 1.0,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.s4),
              const Text(
                'tekir',
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontFamily: 'Fraunces',
                  fontWeight: FontWeight.w600,
                  fontSize: 30,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: AppSpacing.s4),
              ConstrainedBox(
                // prototype .splash-screen__tag: max-width 22em at 14 px
                constraints: const BoxConstraints(maxWidth: 308),
                child: Text(
                  "İstanbul'un sokak kedilerini keşfet, "
                  'onlara göz kulak ol.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: Colors.white.withValues(alpha: 0.82),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
