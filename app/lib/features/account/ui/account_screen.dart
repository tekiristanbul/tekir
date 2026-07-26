import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
      return const Center(child: CircularProgressIndicator());
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

class _AuthenticatedBody extends StatelessWidget {
  const _AuthenticatedBody({required this.onLogout});

  final Future<void> Function() onLogout;

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
        SizedBox(
          height: kTapMin,
          child: OutlinedButton.icon(
            onPressed: onLogout,
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Çıkış yap'),
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
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.person_outline, size: 40, color: AppColors.faint),
        const SizedBox(height: AppSpacing.s3),
        Text('Giriş yapmadın', style: Theme.of(context).textTheme.titleMedium),
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
