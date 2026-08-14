import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/analytics/analytics.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/ui/auth_gate.dart';
import 'blocks_notifier.dart';

/// Opens the destructive confirmation for blocking [userId] and, on
/// confirmation, performs the block (issue #234).
///
/// Blocking acts on the *account*: what disappears is every cat that account
/// owns, along with everything attached to those cats — including other
/// people's contributions. That is why the dialog says so plainly rather
/// than implying only the tapped item goes away. The block is reversible
/// from "Engellenen hesaplar", and the blocked account is never told.
///
/// Requires an account, like every other write in this app; a guest is sent
/// through [AuthGate] first.
Future<void> confirmAndBlock(
  BuildContext context,
  WidgetRef ref, {
  required String userId,
  String? displayName,
  VoidCallback? onBlocked,
}) {
  return AuthGate.require(
    context,
    ref,
    contextText: 'Hesabı engellemek için giriş yap',
    intent: AnalyticsAuthIntent.report,
    onAuthenticated: () => unawaited(
      _confirmAndBlockAuthenticated(
        context,
        ref,
        userId: userId,
        displayName: displayName,
        onBlocked: onBlocked,
      ),
    ),
  );
}

Future<void> _confirmAndBlockAuthenticated(
  BuildContext context,
  WidgetRef ref, {
  required String userId,
  String? displayName,
  VoidCallback? onBlocked,
}) async {
  final who = (displayName == null || displayName.trim().isEmpty)
      ? 'Bu hesabı'
      : '$displayName hesabını';

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Hesabı engelle'),
      content: Text(
        '$who engellemek istediğine emin misin? '
        'Bu hesabın eklediği kediler ve onlara bağlı tüm içerik senin için '
        'görünmez olur. İstediğin zaman engeli kaldırabilirsin.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Vazgeç'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: AppColors.help),
          child: const Text('Engelle'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref.read(blocksProvider.notifier).block(userId);
    onBlocked?.call();
    messenger.showSnackBar(const SnackBar(content: Text('Hesap engellendi.')));
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text(blockActionErrorMessageTr(error))),
    );
  }
}
