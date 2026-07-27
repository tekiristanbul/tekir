import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/identity/session_identity.dart';
import '../../auth/data/auth_api.dart';
import '../data/profile.dart';
import '../data/profile_api.dart';

class ProfileState {
  const ProfileState({
    this.profile,
    this.isLoading = false,
    this.hasLoadedOnce = false,
    this.error,
  });

  final Profile? profile;
  final bool isLoading;
  final bool hasLoadedOnce;
  final Object? error;

  ProfileState copyWith({
    Profile? profile,
    bool? isLoading,
    bool? hasLoadedOnce,
    Object? error,
    bool clearError = false,
  }) {
    return ProfileState(
      profile: profile ?? this.profile,
      isLoading: isLoading ?? this.isLoading,
      hasLoadedOnce: hasLoadedOnce ?? this.hasLoadedOnce,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Loads the authenticated account's own minimal profile surface (issue
/// #80) — mirrors [AccountNotifier]'s plain load shape.
///
/// [build] listens (not watches — see below) for the session's *settled*
/// account id to change and resets state to initial the instant it does:
/// logout, or logging into a different account on the same device (issue
/// #80 product-owner review, finding 5). Three deliberate choices here:
///
/// - `ref.listen` rather than `ref.watch`: a watch would re-run [build]
///   itself on every change and unconditionally discard whatever state
///   [load] had already committed — `listen` is a side effect that only
///   reacts to a change, never coupling this notifier's own rebuild timing
///   to [sessionProvider]'s.
/// - Comparing account ids, not the whole [SessionIdentity]: a refreshed
///   access token for the *same* account must not reset this.
/// - Skipping any transition where either side is still `AsyncLoading`:
///   [sessionProvider]'s own first-ever resolution (app cold start,
///   restoring a previously saved session) is exactly such a transition —
///   without this guard it looks identical to a genuine account change and
///   would wipe out a [load] that raced ahead of it and already finished.
///   A real logout/login-switch never passes through `AsyncLoading` at all
///   ([SessionNotifier.save]/[logout] assign `state` directly), so this
///   never masks the actual case being guarded against.
class ProfileNotifier extends Notifier<ProfileState> {
  @override
  ProfileState build() {
    ref.listen(sessionProvider, (previous, next) {
      if (previous == null || previous.isLoading || next.isLoading) return;
      if (previous.value?.userId != next.value?.userId) {
        state = const ProfileState();
      }
    });
    return const ProfileState();
  }

  Future<void> load() async {
    final requestedFor = ref
        .read(sessionIdentityServiceProvider)
        .cached
        ?.userId;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final profile = await ref.read(profileApiProvider).fetch();
      if (ref.read(sessionIdentityServiceProvider).cached?.userId !=
          requestedFor) {
        return;
      }
      state = ProfileState(profile: profile, hasLoadedOnce: true);
    } catch (e) {
      if (ref.read(sessionIdentityServiceProvider).cached?.userId !=
          requestedFor) {
        return;
      }
      state = state.copyWith(isLoading: false, hasLoadedOnce: true, error: e);
    }
  }

  /// Saves a new display name through the existing `PATCH /v1/me` contract
  /// (issue #80 product-owner review, finding 2) and reflects it in
  /// [state] immediately on success — no full re-fetch needed. Rethrows the
  /// mapped [AuthApi] exception on failure so the edit sheet can surface
  /// its own inline error, mirroring [FollowsNotifier.toggle]'s convention
  /// of only updating local state once the call actually succeeds.
  Future<void> updateDisplayName(String displayName) async {
    await ref.read(authApiProvider).setDisplayName(displayName);
    applyDisplayName(displayName);
  }

  /// Reflects a display name already saved server-side into [state], if a
  /// profile is currently loaded — a no-op local patch, no network call.
  ///
  /// Also called by [AuthNotifier.submitName] (issue #80 product-owner
  /// review): a brand-new account's profile can load once, showing a null
  /// display name, in the gap between `otp/verify` succeeding and the
  /// signup name step's own `PATCH /v1/me` completing — this screen is a
  /// persistent shell tab (app_shell.dart), so once loaded, nothing else
  /// would ever tell it the name changed. Without this, the profile screen
  /// keeps showing "İsimsiz kullanıcı" even though the name saved
  /// correctly, until the next full reload.
  void applyDisplayName(String displayName) {
    final current = state.profile;
    if (current != null) {
      state = state.copyWith(
        profile: current.copyWith(displayName: displayName),
      );
    }
  }
}

final profileProvider = NotifierProvider<ProfileNotifier, ProfileState>(
  ProfileNotifier.new,
);
