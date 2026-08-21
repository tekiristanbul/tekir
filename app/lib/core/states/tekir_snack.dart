import 'package:flutter/material.dart';

import '../motion/tekir_haptics.dart';
import '../theme/app_theme.dart';

/// The app's transient confirmation, in tekir's own voice.
///
/// Every one of these used to be a default Material snackbar: the same
/// grey slab whether a contribution had just been recorded or lost, so
/// outcome was carried entirely by the Turkish sentence and nothing else.
/// On cat detail it also landed underneath the fixed "+ update" bar.
///
/// Two shapes only, because there are only two outcomes worth
/// distinguishing at this level: something the user asked for happened, or
/// it did not. The palette does the distinguishing before the sentence is
/// read, and the paired haptic does it before the eye arrives at all.
///
/// This owns presentation, never wording — callers pass the same copy they
/// always did.
enum TekirSnackTone {
  /// A write the user asked for was confirmed.
  done,

  /// It did not happen. Never the same slab as [done].
  failed,
}

class TekirSnack {
  const TekirSnack._();

  /// Clearance for cat detail's fixed action bar, which a bottom-anchored
  /// snackbar would otherwise sit under. Harmless on screens without one:
  /// floating snackbars already carry a margin.
  static const _barClearance = 84.0;

  static void show(
    BuildContext context,
    String message, {
    TekirSnackTone tone = TekirSnackTone.done,
    bool clearsFixedBar = false,
  }) {
    showOn(
      ScaffoldMessenger.of(context),
      message,
      tone: tone,
      clearsFixedBar: clearsFixedBar,
    );
  }

  /// For the calls that outlive their own screen: a delete confirms after
  /// the screen has popped, so the messenger is captured beforehand and the
  /// context is already gone by the time the message shows.
  static void showOn(
    ScaffoldMessengerState messenger,
    String message, {
    TekirSnackTone tone = TekirSnackTone.done,
    bool clearsFixedBar = false,
  }) {
    final failed = tone == TekirSnackTone.failed;
    final foreground = failed ? AppColors.helpInk : AppColors.primaryInk;

    // Fired here rather than at each call site so an outcome can never
    // reach the eye without also reaching the hand.
    if (failed) {
      TekirHaptics.refused();
    } else {
      TekirHaptics.committed();
    }

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: failed ? AppColors.helpStrong : AppColors.ink,
          elevation: 6,
          margin: EdgeInsets.fromLTRB(
            AppSpacing.s4,
            0,
            AppSpacing.s4,
            clearsFixedBar ? _barClearance : AppSpacing.s4,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          content: Row(
            children: [
              Icon(
                failed ? Icons.error_outline : Icons.check_circle_outline,
                size: 18,
                color: foreground,
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
  }

  /// Convenience for the failure half, which is the majority of call sites.
  static void failure(
    BuildContext context,
    String message, {
    bool clearsFixedBar = false,
  }) {
    show(
      context,
      message,
      tone: TekirSnackTone.failed,
      clearsFixedBar: clearsFixedBar,
    );
  }
}
