import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/analytics/analytics.dart';
import '../../../core/motion/press_response.dart';
import '../../../core/motion/tekir_haptics.dart';
import '../../../core/motion/tekir_motion.dart';
import '../../../core/states/tekir_snack.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/ui/auth_gate.dart';
import '../../notifications/ui/notification_optin_sheet.dart';
import 'follow_state_notifier.dart';

/// Follow/unfollow toggle for a cat (issue #65). Gate-at-intent: a guest's
/// tap never mutates anything before authentication succeeds — it shows
/// [AuthGate]'s prompt sheet first, and only calls [FollowsNotifier.toggle]
/// once sign-in completes (resumed intent), exactly the mechanism issue
/// #47/#57 built and issue #65 is the first feature to actually call.
class FollowButton extends ConsumerWidget {
  const FollowButton({
    super.key,
    required this.catId,
    this.source,
    this.glass = false,
  });

  final String catId;

  /// Which vocabulary source the surface hosting this button was opened
  /// from — carried onto follow_created/follow_removed (issue #84); null
  /// (parameter omitted) when unknown, e.g. a direct deep link.
  final AnalyticsSource? source;

  /// Icon-only round variant on a glass background, for placement directly
  /// on a photo (binding design docs/design/screens/cat-profile.html: the
  /// follow heart sits top-right on the cover, next to the back button,
  /// matching `_BackCircleButton`'s glass treatment) instead of the
  /// labeled outline button used elsewhere.
  final bool glass;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFollowed = ref.watch(
      followsProvider.select((s) => s.value?.contains(catId) ?? false),
    );

    // Followed-ness is otherwise carried by a filled-vs-outline heart and
    // a colour swap, neither of which a screen reader reports -- so it had
    // no way to answer "am I following this cat?". `toggled` makes it a
    // state, and the label says which cat-level action it is: this button
    // sits beside an unlabelled back chevron on the same row.
    final semanticsLabel = isFollowed ? 'Takip ediliyor' : 'Takip et';

    if (glass) {
      return Semantics(
        container: true,
        excludeSemantics: true,
        button: true,
        toggled: isFollowed,
        label: semanticsLabel,
        onTap: () => _handleTap(context, ref),
        child: PressResponse(
          child: Material(
            color: Colors.white.withValues(alpha: 0.92),
            shape: const CircleBorder(),
            elevation: 2,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _handleTap(context, ref),
              child: SizedBox(
                width: kTapMin,
                height: kTapMin,
                child: Center(
                  child: _FollowHeart(
                    isFollowed: isFollowed,
                    size: 18,
                    color: isFollowed ? AppColors.primary : AppColors.ink,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // The labelled variant already announces its text, so it needs the
    // state, not a name.
    return Semantics(
      container: true,
      toggled: isFollowed,
      child: PressResponse(
        child: SizedBox(
          height: kTapMin,
          child: OutlinedButton.icon(
            onPressed: () => _handleTap(context, ref),
            style: OutlinedButton.styleFrom(
              foregroundColor: isFollowed
                  ? AppColors.primaryStrong
                  : AppColors.ink,
              side: BorderSide(
                color: isFollowed ? AppColors.primary : AppColors.lineStrong,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              textStyle: const TextStyle(fontWeight: FontWeight.w600),
            ),
            icon: _FollowHeart(
              isFollowed: isFollowed,
              size: 18,
              color: isFollowed ? AppColors.primaryStrong : AppColors.ink,
            ),
            label: Text(isFollowed ? 'Takip ediliyor' : 'Takip et'),
          ),
        ),
      ),
    );
  }

  void _handleTap(BuildContext context, WidgetRef ref) {
    unawaited(
      AuthGate.require(
        context,
        ref,
        contextText: 'Bir kediyi takip etmek için giriş yap',
        intent: AnalyticsAuthIntent.follow,
        onAuthenticated: () => unawaited(_toggle(context, ref)),
      ),
    );
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref) async {
    final wasFollowing =
        ref.read(followsProvider).value?.contains(catId) ?? false;
    // Fired with the optimistic flip, not after the round trip: the state
    // the user sees has already changed, so the hand confirms the same
    // thing the screen does, in the same frame. A failure below reverts
    // both — the visible state and, with `refused`, the felt one.
    unawaited(TekirHaptics.committed());
    try {
      await ref.read(followsProvider.notifier).toggle(catId);
    } catch (e) {
      if (!context.mounted) return;
      // TekirSnack fires the refused haptic itself, so the outcome cannot
      // reach the eye without reaching the hand.
      TekirSnack.failure(context, followActionErrorMessageTr(e));
      return;
    }
    // logged only after the server confirmed the change (issue #84) — a
    // failed toggle above never emits.
    ref
        .read(analyticsProvider)
        .log(
          wasFollowing
              ? AnalyticsEvent.followRemoved(source)
              : AnalyticsEvent.followCreated(source),
        );
    // Notification permission is asked only after following a cat — never
    // on unfollow, and at most once per session (issue #78,
    // docs/product/notifications.md).
    if (!wasFollowing && context.mounted) {
      await maybeShowNotificationOptInSheet(context, ref);
    }
  }
}

/// The follow control's heart, and the one authored beat in the app.
///
/// Following a specific street cat is an emotional act, so the moment it
/// happens gets a single restrained beat — scale out and back, once, on the
/// follow direction only. Unfollowing is not celebrated and does not beat:
/// it swaps the glyph and stops. Anything more here would turn a care
/// record into a social feed.
///
/// The outline/filled swap crossfades rather than cutting, so the change
/// reads as one glyph becoming another rather than two glyphs trading
/// places.
///
/// Under reduced motion both the beat and the crossfade collapse: the icon
/// and its color still change — that is the state, and the accessibility
/// contract removes travel, not confirmation.
class _FollowHeart extends StatefulWidget {
  const _FollowHeart({
    required this.isFollowed,
    required this.size,
    required this.color,
  });

  final bool isFollowed;
  final double size;
  final Color color;

  @override
  State<_FollowHeart> createState() => _FollowHeartState();
}

class _FollowHeartState extends State<_FollowHeart>
    with SingleTickerProviderStateMixin {
  // Built in initState rather than lazily: under reduced motion nothing
  // ever reads these, and a `late final` initializer that first runs inside
  // dispose() reaches for an ancestor that is already deactivated.
  late final AnimationController _controller;
  late final Animation<double> _beat;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: TekirMotion.state);
    // Out and back in one pass, so the beat has a peak instead of a
    // destination — a plain forward tween would leave the heart parked at
    // 1.15.
    _beat = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.15), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 1.15, end: 1.0), weight: 1),
    ]).animate(CurvedAnimation(parent: _controller, curve: TekirMotion.enter));
  }

  @override
  void didUpdateWidget(_FollowHeart oldWidget) {
    super.didUpdateWidget(oldWidget);
    final becameFollowed = widget.isFollowed && !oldWidget.isFollowed;
    if (!becameFollowed) return;
    if (TekirMotion.of(context).reduced) return;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final motion = TekirMotion.of(context);
    final icon = AnimatedSwitcher(
      duration: motion(TekirMotion.state),
      // Both glyphs occupy the same box, so a crossfade in place is the
      // whole transition — no travel, no size change.
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: Icon(
        widget.isFollowed ? Icons.favorite : Icons.favorite_border,
        key: ValueKey(widget.isFollowed),
        size: widget.size,
        color: widget.color,
      ),
    );

    if (motion.reduced) return icon;

    return ScaleTransition(scale: _beat, child: icon);
  }
}
