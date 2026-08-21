import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/states/tekir_snack.dart';
import '../../../core/states/read_skeleton.dart';
import '../../../core/theme/app_theme.dart';
import 'account_notifier.dart';

/// Mirrors the prototype's settings "Hesap" section and profile
/// guest-empty-state (prototype/app.js:756-799,892-897): guest state (icon
/// + title + body + "Giriş yap") vs. authenticated state (a verified-phone
/// row + "Çıkış yap"). Deliberately does not show the phone number itself —
/// `GET /v1/me` never returns it (see account_api.dart) — a recorded
/// deviation from the prototype's literal display, since the number simply
/// isn't in this endpoint's response.
class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(accountProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(accountProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: const Text('Hesap'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s5),
          child: _body(state),
        ),
      ),
    );
  }

  Widget _body(AccountState state) {
    if (state.isLoading && state.info == null) {
      return GatedReadSkeleton(
        rowCount: 4,
        hasLeading: false,
        onRetry: () => ref.read(accountProvider.notifier).load(),
        timedOutBuilder: (context, onRetry) => _ErrorRetry(onRetry: onRetry),
      );
    }
    if (state.error && state.info == null) {
      return _ErrorRetry(
        onRetry: () => ref.read(accountProvider.notifier).load(),
      );
    }

    final verified = state.info?.phoneVerified ?? false;
    return verified
        ? _AuthenticatedBody(onLogout: _logout)
        : _GuestBody(onLogin: _login);
  }

  Future<void> _login() async {
    final result = await context.push<bool>('/login');
    if (result == true && mounted) {
      await ref.read(accountProvider.notifier).load();
    }
  }

  Future<void> _logout() => ref.read(accountProvider.notifier).logout();
}

class _AuthenticatedBody extends ConsumerStatefulWidget {
  const _AuthenticatedBody({required this.onLogout});

  final Future<void> Function() onLogout;

  @override
  ConsumerState<_AuthenticatedBody> createState() => _AuthenticatedBodyState();
}

class _AuthenticatedBodyState extends ConsumerState<_AuthenticatedBody> {
  bool _isDeleting = false;

  /// issue #242 (apple guideline 5.1.1(v)): deletion is terminal and takes
  /// the account's content with it, so the confirmation says so plainly.
  /// The local session is cleared only after the server confirms — see
  /// [AccountNotifier.deleteAccount] — so a failure leaves the user signed
  /// in and able to retry.
  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hesabımı sil'),
        content: const Text(
          'Hesabın ve eklediğin kediler, güncellemeler ve fotoğraflar '
          'kalıcı olarak silinir. Bu işlem geri alınamaz.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Vazgeç'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.help),
            child: const Text('Hesabımı sil'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isDeleting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(accountProvider.notifier).deleteAccount();
      if (!mounted) return;
      setState(() => _isDeleting = false);
      TekirSnack.showOn(messenger, 'Hesabın silindi.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _isDeleting = false);
      TekirSnack.showOn(
        messenger,
        'Hesap silinemedi, tekrar dene.',
        tone: TekirSnackTone.failed,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.s4),
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.verified,
                size: 20,
                color: AppColors.primaryStrong,
              ),
              const SizedBox(width: AppSpacing.s3),
              const Expanded(
                child: Text(
                  'Telefon doğrulandı',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.ink,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
        // issue #234: blocking is reversible, so the list of blocked
        // accounts has to be reachable — this is the only place it exists.
        SizedBox(
          height: kTapMin,
          child: OutlinedButton.icon(
            onPressed: () => context.push('/account/blocked'),
            icon: const Icon(Icons.block, size: 18),
            label: const Text('Engellenen hesaplar'),
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        SizedBox(
          height: kTapMin,
          child: OutlinedButton.icon(
            onPressed: _isDeleting ? null : widget.onLogout,
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Çıkış yap'),
          ),
        ),
        const SizedBox(height: AppSpacing.s5),
        // Deliberately last and plain-text rather than an outlined button:
        // the destructive action must not read as this screen's primary one
        // (issue #242).
        Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            height: kTapMin,
            child: TextButton(
              onPressed: _isDeleting ? null : _confirmDelete,
              style: TextButton.styleFrom(foregroundColor: AppColors.help),
              child: Text(_isDeleting ? 'Siliniyor…' : 'Hesabımı sil'),
            ),
          ),
        ),
      ],
    );
  }
}

class _GuestBody extends StatelessWidget {
  const _GuestBody({required this.onLogin});

  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    // Scrollable so large text scale can't push the sign-in action off a
    // small screen (app-states global rules: no state overflows at large
    // system text scale).
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.person_outline, size: 40, color: AppColors.faint),
            const SizedBox(height: AppSpacing.s3),
            Text(
              'Giriş yapmadın',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.s2),
            const Text(
              'Katkı geçmişini ve rozetlerini görmek, kedi eklemek ve güncelleme paylaşmak için giriş yapman gerekir. Haritayı ve kedi detaylarını girişsiz gezebilirsin.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, height: 1.5),
            ),
            const SizedBox(height: AppSpacing.s5),
            SizedBox(
              height: kTapMin,
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onLogin,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.primaryInk,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
                child: const Text('Giriş yap'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 32, color: AppColors.help),
          const SizedBox(height: AppSpacing.s3),
          const Text(
            'Bağlantı sorunu oldu. Tekrar dener misin?',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: AppSpacing.s3),
          OutlinedButton(onPressed: onRetry, child: const Text('Tekrar dene')),
        ],
      ),
    );
  }
}
