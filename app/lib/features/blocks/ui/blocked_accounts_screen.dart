import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/states/inline_spinner.dart';
import '../../../core/states/tekir_snack.dart';
import '../../../core/theme/app_theme.dart';
import '../data/blocks_api.dart';
import 'blocks_notifier.dart';

/// The account's own blocked-accounts list with an unblock action for each
/// entry (issue #234). This is the only place blocks are ever visible: the
/// blocked party is never told, and no other account can see this list.
class BlockedAccountsScreen extends ConsumerWidget {
  const BlockedAccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocked = ref.watch(blocksProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Engellenen hesaplar')),
      body: switch (blocked) {
        AsyncData(:final value) when value.isEmpty => const _Empty(),
        AsyncData(:final value) => ListView.separated(
          padding: const EdgeInsets.all(AppSpacing.s4),
          itemCount: value.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) => _BlockedRow(account: value[index]),
        ),
        AsyncError() => const _Error(),
        _ => const Center(
          child: InlineSpinner(
            size: 28,
            color: AppColors.primary,
            trackColor: AppColors.line,
          ),
        ),
      },
    );
  }
}

class _BlockedRow extends ConsumerStatefulWidget {
  const _BlockedRow({required this.account});

  final BlockedAccount account;

  @override
  ConsumerState<_BlockedRow> createState() => _BlockedRowState();
}

class _BlockedRowState extends ConsumerState<_BlockedRow> {
  bool _isUnblocking = false;

  Future<void> _unblock() async {
    setState(() => _isUnblocking = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(blocksProvider.notifier).unblock(widget.account.userId);
      TekirSnack.showOn(messenger, 'Engel kaldırıldı.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _isUnblocking = false);
      TekirSnack.showOn(
        messenger,
        blockActionErrorMessageTr(error),
        tone: TekirSnackTone.failed,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.account.displayName;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        // An account that never set a display name still has to be
        // unblockable, so it shows a neutral placeholder rather than being
        // hidden from this list.
        (name == null || name.trim().isEmpty) ? 'Adsız hesap' : name,
        style: const TextStyle(color: AppColors.ink),
      ),
      trailing: SizedBox(
        height: kTapMin,
        child: TextButton(
          onPressed: _isUnblocking ? null : _unblock,
          child: Text(_isUnblocking ? 'Kaldırılıyor…' : 'Engeli kaldır'),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(AppSpacing.s4),
      child: Center(
        child: Text(
          'Engellediğin hesap yok.',
          style: TextStyle(color: AppColors.muted),
        ),
      ),
    );
  }
}

class _Error extends ConsumerWidget {
  const _Error();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Liste yüklenemedi.',
            style: TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: AppSpacing.s3),
          OutlinedButton(
            onPressed: () => ref.invalidate(blocksProvider),
            child: const Text('Tekrar dene'),
          ),
        ],
      ),
    );
  }
}
