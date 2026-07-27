import 'package:flutter_riverpod/flutter_riverpod.dart';

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
}

final profileProvider = NotifierProvider<ProfileNotifier, ProfileState>(
  ProfileNotifier.new,
);
