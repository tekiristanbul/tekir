import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/identity/session_identity.dart';
import '../data/account_api.dart';

class AccountState {
  const AccountState({this.isLoading = false, this.info, this.error = false});

  final bool isLoading;
  final AccountInfo? info;
  final bool error;

  AccountState copyWith({bool? isLoading, AccountInfo? info, bool? error}) {
    return AccountState(
      isLoading: isLoading ?? this.isLoading,
      info: info ?? this.info,
      error: error ?? false,
    );
  }
}

/// Fetches `GET /v1/me` to answer "am I currently signed in" from the
/// server's own perspective — issue #58's "settings/account surface
/// required to inspect the current session" requirement. Callable
/// regardless of guest/authenticated state (the endpoint only requires the
/// device token, always present); the response's `phone_verified` is the
/// source of truth this screen renders from, not just the locally cached
/// [SessionIdentity].
class AccountNotifier extends Notifier<AccountState> {
  @override
  AccountState build() => const AccountState();

  Future<void> load() async {
    state = state.copyWith(isLoading: true);
    try {
      final info = await ref.read(accountApiProvider).fetchMe();
      state = AccountState(info: info);
    } catch (_) {
      state = state.copyWith(isLoading: false, error: true);
    }
  }

  /// Logs out, then refreshes from the server so the screen reflects the
  /// now-guest state immediately.
  Future<void> logout() async {
    await ref.read(sessionProvider.notifier).logout();
    await load();
  }
}

final accountProvider = NotifierProvider<AccountNotifier, AccountState>(
  AccountNotifier.new,
);
