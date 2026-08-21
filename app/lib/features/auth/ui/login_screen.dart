import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/states/submitting_button.dart';
import '../../../core/theme/app_theme.dart';
import 'auth_notifier.dart';

/// Phone → code → (new account only) display-name, matching the approved
/// prototype's login screen structure, copy, and tokens verbatim
/// (prototype/app.js:956-1048) — one screen with three internal steps
/// rather than three separate routes, exactly as the prototype implements
/// it. Pops `true` once the whole flow completes (a caller navigating here
/// directly, or via [AuthGate], both read that result the same way).
///
/// Invalid-code, expired-code, too-many-attempts, device-conflict, offline,
/// and server-error states have no prototype precedent — the prototype's
/// demo backend accepts any code and never fails. These are a recorded,
/// intentional extension of the prototype (docs/design/
/// implementation-contract.md): they reuse the app's existing inline
/// error-banner "tekrar dene" pattern (see cat_update_sheet.dart) rather
/// than inventing new visual language.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.contextText});

  /// Mirrors the prototype's `state.loginContext` — why the user landed
  /// here (e.g. "Bir kediyi takip etmek için giriş yap"). Null for a
  /// direct, non-gated login from account/settings.
  final String? contextText;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref
          .read(authProvider.notifier)
          .start(contextText: widget.contextText),
    );
  }

  Future<void> _sendCode() async {
    await ref.read(authProvider.notifier).sendCode();
  }

  Future<void> _verifyCode() async {
    final done = await ref.read(authProvider.notifier).verifyCode();
    if (done && mounted) Navigator.of(context).pop(true);
  }

  Future<void> _submitName() async {
    final done = await ref.read(authProvider.notifier).submitName();
    if (done && mounted) Navigator.of(context).pop(true);
  }

  void _cancel() {
    ref.read(authProvider.notifier).cancel();
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: const Text('Giriş yap'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Vazgeç',
          onPressed: _cancel,
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.s5),
          child: switch (state.step) {
            AuthStep.phone => _PhoneStep(state: state, onSendCode: _sendCode),
            AuthStep.code => _CodeStep(state: state, onVerify: _verifyCode),
            AuthStep.name => _NameStep(state: state, onSubmit: _submitName),
          },
        ),
      ),
    );
  }
}

class _StepHero extends StatelessWidget {
  const _StepHero({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: const BoxDecoration(
            color: AppColors.primarySoft,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 24, color: AppColors.primaryStrong),
        ),
        const SizedBox(height: AppSpacing.s3),
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: AppSpacing.s5),
      ],
    );
  }
}

class _ContextBanner extends StatelessWidget {
  const _ContextBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: AppSpacing.s4),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s2,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          const Icon(Icons.phone_iphone, size: 16, color: AppColors.muted),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text(text, style: const TextStyle(color: AppColors.muted)),
          ),
        ],
      ),
    );
  }
}

class _AuthErrorBanner extends StatelessWidget {
  const _AuthErrorBanner({required this.error});

  final AuthError error;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: AppSpacing.s3),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s3,
      ),
      decoration: BoxDecoration(
        color: AppColors.helpSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.help),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: AppColors.help),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text(
              authErrorMessageTr(error),
              style: const TextStyle(color: AppColors.helpStrong, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Login's primary action. A thin wrapper over the shared
/// [SubmittingButton] rather than its own [ElevatedButton]: this screen
/// used to replace its label with a bare spinner while submitting, which
/// both broke the contract's `button · submitting` rule (the label must
/// change, not vanish) and kept spinning under reduced motion. The
/// wrapper stays because each step supplies its own in-flight wording.
class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.submittingLabel,
    required this.isSubmitting,
    required this.onPressed,
  });

  final String label;
  final String submittingLabel;
  final bool isSubmitting;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SubmittingButton(
      label: label,
      submittingLabel: submittingLabel,
      submitting: isSubmitting,
      onPressed: onPressed,
    );
  }
}

class _PhoneStep extends ConsumerWidget {
  const _PhoneStep({required this.state, required this.onSendCode});

  final AuthState state;
  final VoidCallback onSendCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepHero(icon: Icons.phone, title: 'Telefon ile giriş yap'),
        if (state.contextText != null) _ContextBanner(text: state.contextText!),
        const Text(
          'Telefon numarası',
          style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.muted),
        ),
        const SizedBox(height: AppSpacing.s2),
        Row(
          children: [
            const Text(
              '+90',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(width: AppSpacing.s2),
            Expanded(
              child: TextField(
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  hintText: '5xx xxx xx xx',
                  filled: true,
                  fillColor: AppColors.surfaceAlt,
                  contentPadding: EdgeInsets.all(AppSpacing.s3),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(
                      Radius.circular(AppRadius.md),
                    ),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (value) =>
                    ref.read(authProvider.notifier).setPhone(value),
              ),
            ),
          ],
        ),
        if (state.error != null) _AuthErrorBanner(error: state.error!),
        const SizedBox(height: AppSpacing.s5),
        _PrimaryButton(
          label: 'Kod gönder',
          submittingLabel: 'Kod gönderiliyor',
          isSubmitting: state.isSubmitting,
          onPressed: onSendCode,
        ),
      ],
    );
  }
}

class _CodeStep extends ConsumerWidget {
  const _CodeStep({required this.state, required this.onVerify});

  final AuthState state;
  final VoidCallback onVerify;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepHero(icon: Icons.phone, title: 'Telefon ile giriş yap'),
        if (state.contextText != null) _ContextBanner(text: state.contextText!),
        Text(
          '+90 ${state.phone}',
          style: const TextStyle(color: AppColors.muted),
        ),
        const SizedBox(height: AppSpacing.s4),
        const Text(
          'Doğrulama kodu',
          style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.muted),
        ),
        const SizedBox(height: AppSpacing.s2),
        TextField(
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(
            hintText: '------',
            filled: true,
            fillColor: AppColors.surfaceAlt,
            counterText: '',
            contentPadding: EdgeInsets.all(AppSpacing.s3),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(AppRadius.md)),
              borderSide: BorderSide.none,
            ),
          ),
          onChanged: (value) => ref.read(authProvider.notifier).setCode(value),
        ),
        if (state.error != null) _AuthErrorBanner(error: state.error!),
        const SizedBox(height: AppSpacing.s5),
        _PrimaryButton(
          label: 'Giriş yap',
          submittingLabel: 'Giriş yapılıyor',
          isSubmitting: state.isSubmitting,
          onPressed: onVerify,
        ),
      ],
    );
  }
}

class _NameStep extends ConsumerWidget {
  const _NameStep({required this.state, required this.onSubmit});

  final AuthState state;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepHero(icon: Icons.person, title: 'Görünen adını seç'),
        const Text(
          'Görünen isim',
          style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.muted),
        ),
        const SizedBox(height: AppSpacing.s2),
        TextField(
          decoration: const InputDecoration(
            hintText: 'Örn. Ayşe, Mert…',
            filled: true,
            fillColor: AppColors.surfaceAlt,
            contentPadding: EdgeInsets.all(AppSpacing.s3),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(AppRadius.md)),
              borderSide: BorderSide.none,
            ),
          ),
          onChanged: (value) => ref.read(authProvider.notifier).setName(value),
        ),
        const SizedBox(height: AppSpacing.s3),
        const Text(
          'Bu isim, paylaştığın güncellemelerin ve profilinin yanında herkese açık şekilde görünür.',
          style: TextStyle(fontSize: 12, color: AppColors.faint, height: 1.5),
        ),
        if (state.error != null) _AuthErrorBanner(error: state.error!),
        const SizedBox(height: AppSpacing.s5),
        _PrimaryButton(
          label: 'Kaydet ve devam et',
          submittingLabel: 'Kaydediliyor',
          isSubmitting: state.isSubmitting,
          onPressed: onSubmit,
        ),
      ],
    );
  }
}
