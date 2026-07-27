import 'package:flutter_riverpod/flutter_riverpod.dart';

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
class ProfileNotifier extends Notifier<ProfileState> {
  @override
  ProfileState build() => const ProfileState();

  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final profile = await ref.read(profileApiProvider).fetch();
      state = ProfileState(profile: profile, hasLoadedOnce: true);
    } catch (e) {
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
