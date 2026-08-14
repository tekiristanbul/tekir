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

  /// Deletes the account for good (issue #242, apple guideline 5.1.1(v)),
  /// then drops the local session and reloads as a guest.
  ///
  /// Order matters and is the whole point: the delete call has to be
  /// confirmed by the server *before* any local credential is cleared. The
  /// other way round the user would be signed out of an account that still
  /// exists, with no way to reach it again and nothing left to retry with.
  /// A failure therefore propagates to the caller with the session intact,
  /// so the screen can offer a retry.
  ///
  /// The session teardown afterwards is the ordinary logout path; its
  /// best-effort server-side revoke will simply fail against an account
  /// that no longer exists, which is why it is best-effort.
  Future<void> deleteAccount() async {
    await ref.read(accountApiProvider).deleteAccount();
    await ref.read(sessionProvider.notifier).logout();
    await load();
  }
}

final accountProvider = NotifierProvider<AccountNotifier, AccountState>(
  AccountNotifier.new,
);
