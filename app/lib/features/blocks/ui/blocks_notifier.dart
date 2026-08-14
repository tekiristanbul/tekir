import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/identity/session_identity.dart';
import '../data/blocks_api.dart';

/// Turkish, actionable copy for a failed block/unblock attempt — mirrors
/// [followActionErrorMessageTr]'s register: short, declarative, no
/// exclamation marks, and never naming the other account.
String blockActionErrorMessageTr(Object error) {
  return switch (error) {
    BlockUnauthorizedException() => 'Kimlik doğrulanamadı, tekrar dene.',
    BlockTargetNotFoundException() => 'Bu hesap artık bulunamıyor.',
    BlockValidationException() => 'İşlem tamamlanamadı, tekrar dene.',
    BlockNetworkException() => 'Bağlantı sorunu, tekrar dene.',
    _ => 'Sunucuya ulaşılamadı, birazdan tekrar dene.',
  };
}

/// The authenticated account's blocked accounts (issue #234). Like
/// [FollowsNotifier], [build] re-runs whenever [sessionProvider] changes, so
/// logging out clears the list and switching accounts replaces it — a
/// guest never holds a block cache at all, and one account's blocks can
/// never leak into another's session.
///
/// This is a convenience cache for the block-list screen and for hiding the
/// "engelle" action on an account already blocked. It is never the
/// authority: what a viewer can see is decided server-side on every read.
class BlocksNotifier extends AsyncNotifier<List<BlockedAccount>> {
  @override
  Future<List<BlockedAccount>> build() async {
    final session = ref.watch(sessionProvider).value;
    if (session == null) return const [];
    return ref.read(blocksApiProvider).listBlocked();
  }

  /// Blocks [userId], then refreshes the list from the server. Rethrows the
  /// mapped [BlocksApi] exception so the caller can surface
  /// [blockActionErrorMessageTr]; state is only updated once the write has
  /// actually succeeded, matching the follow/report convention of never
  /// persisting optimistically.
  Future<void> block(String userId) async {
    await ref.read(blocksApiProvider).block(userId);
    state = AsyncData(await ref.read(blocksApiProvider).listBlocked());
  }

  Future<void> unblock(String userId) async {
    await ref.read(blocksApiProvider).unblock(userId);
    final current = state.value ?? const <BlockedAccount>[];
    state = AsyncData(
      current.where((b) => b.userId != userId).toList(growable: false),
    );
  }

  bool isBlocked(String userId) {
    final current = state.value;
    if (current == null) return false;
    return current.any((b) => b.userId == userId);
  }
}

final blocksProvider =
    AsyncNotifierProvider<BlocksNotifier, List<BlockedAccount>>(
      BlocksNotifier.new,
    );
