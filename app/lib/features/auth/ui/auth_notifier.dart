import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/identity/device_identity.dart';
import '../../../core/identity/session_identity.dart';
import '../data/auth_api.dart';

/// The three prototype steps (prototype/app.js's login screen): phone
/// entry, verification code, and — only for a brand-new account — the
/// minimum-profile display name.
enum AuthStep { phone, code, name }

/// Every mapped failure across all three steps. None of these are
/// permanent — every state here implies "try again" (mirrors
/// UpdateSubmitError's convention in cat_update_composer_notifier.dart).
enum AuthError {
  invalidPhone,
  resendTooSoon,
  codeIncomplete,
  invalidCode,
  expiredCode,
  tooManyAttempts,
  deviceConflict,
  staleDeviceCredential,
  nameRequired,
  network,
  server,
}

/// Turkish, actionable copy for each mapped failure. Phone/code/name
/// validation copy matches the approved prototype verbatim
/// (prototype/app.js:1009,1015,1033); the otp-outcome and offline/retry
/// copy has no prototype precedent (the prototype's demo backend accepts
/// any code and never fails) and is a recorded, intentional extension of
/// the prototype for this issue, reusing the app's existing toast/
/// error-banner vocabulary rather than inventing new visual language.
String authErrorMessageTr(AuthError error) {
  return switch (error) {
    AuthError.invalidPhone => 'Geçerli bir telefon numarası gir',
    AuthError.resendTooSoon => 'Az önce kod gönderildi, birazdan tekrar dene',
    AuthError.codeIncomplete => 'Kodu eksiksiz gir',
    AuthError.invalidCode => 'Kodu yanlış girdin, tekrar dene',
    AuthError.expiredCode => 'Kodun süresi doldu, yeni kod iste',
    AuthError.tooManyAttempts => 'Çok fazla deneme yaptın, yeni kod iste',
    AuthError.deviceConflict => 'Bu cihaz başka bir hesaba bağlı',
    AuthError.staleDeviceCredential => 'Cihaz kimliği yenilendi, tekrar dene',
    AuthError.nameRequired => 'Bir isim gir',
    AuthError.network => 'Bağlantı sorunu, tekrar dene',
    AuthError.server => 'Sunucuya ulaşılamadı, birazdan tekrar dene',
  };
}

class AuthState {
  const AuthState({
    this.step = AuthStep.phone,
    this.contextText,
    this.phone = '',
    this.code = '',
    this.name = '',
    this.isSubmitting = false,
    this.error,
  });

  final AuthStep step;

  /// Mirrors the prototype's `state.loginContext` — the reason the auth
  /// gate opened (e.g. "Bir kediyi takip etmek için giriş yap"), shown on
  /// the phone step. Null for a direct, non-gated login.
  final String? contextText;
  final String phone;
  final String code;
  final String name;
  final bool isSubmitting;
  final AuthError? error;

  AuthState copyWith({
    AuthStep? step,
    String? phone,
    String? code,
    String? name,
    bool? isSubmitting,
    AuthError? error,
    bool clearError = false,
  }) {
    return AuthState(
      step: step ?? this.step,
      contextText: contextText,
      phone: phone ?? this.phone,
      code: code ?? this.code,
      name: name ?? this.name,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Drives the login screen through phone → code → (new account only) name.
/// [sendCode]/[verifyCode]/[submitName] each return true only once the
/// entire flow is done (the caller should pop the screen with success) —
/// [verifyCode] returns false and advances to [AuthStep.name] for a
/// brand-new account, since the flow isn't finished until the display name
/// is set. One instance app-wide, mirroring the prototype's single global
/// login form state.
class AuthNotifier extends Notifier<AuthState> {
  @override
  AuthState build() => const AuthState();

  /// Resets the flow to the phone step, recording the context text to show
  /// (mirrors the prototype's `requireLogin`/`state.loginContext`) — call
  /// when the login screen opens.
  void start({String? contextText}) {
    state = AuthState(contextText: contextText);
  }

  void setPhone(String value) =>
      state = state.copyWith(phone: value, clearError: true);
  void setCode(String value) =>
      state = state.copyWith(code: value, clearError: true);
  void setName(String value) =>
      state = state.copyWith(name: value, clearError: true);

  Future<bool> sendCode() async {
    if (state.isSubmitting) return false;
    final digits = _digits(state.phone);
    if (digits.length < 10) {
      state = state.copyWith(error: AuthError.invalidPhone);
      return false;
    }

    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      await ref.read(authApiProvider).requestOtp('+90$digits');
      state = state.copyWith(step: AuthStep.code, isSubmitting: false);
    } on OtpInvalidPhoneException {
      state = state.copyWith(
        isSubmitting: false,
        error: AuthError.invalidPhone,
      );
    } on OtpResendTooSoonException {
      state = state.copyWith(
        isSubmitting: false,
        error: AuthError.resendTooSoon,
      );
    } on AuthNetworkException {
      state = state.copyWith(isSubmitting: false, error: AuthError.network);
    } catch (_) {
      state = state.copyWith(isSubmitting: false, error: AuthError.server);
    }
    return false;
  }

  Future<bool> verifyCode() async {
    if (state.isSubmitting) return false;
    if (state.code.trim().length < 4) {
      state = state.copyWith(error: AuthError.codeIncomplete);
      return false;
    }

    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      // Lazily initializes (or awaits an in-flight, or retries a
      // previously invalidated) device identity — mirrors
      // cat_update_composer_notifier's own explicit init-before-submit
      // call. This is what actually lets a retry recover after the
      // AuthDeviceTokenInvalidException branch below invalidates a stale
      // credential: without re-running init() here, nothing would ever
      // register a replacement, and every subsequent attempt would keep
      // sending no device token at all.
      final device = await ref.read(deviceIdentityServiceProvider).init();
      if (device == null) {
        // init() swallows registration/storage failures and returns null
        // rather than throwing. Verifying now would send no device token
        // at all, which the server can only answer with the same 401 the
        // AuthDeviceTokenInvalidException branch below handles — but this
        // isn't a stale credential, it's a network/server problem, so
        // report it as such instead of making the doomed request.
        state = state.copyWith(isSubmitting: false, error: AuthError.network);
        return false;
      }
      final session = await ref
          .read(authApiProvider)
          .verifyOtp(
            phone: '+90${_digits(state.phone)}',
            code: state.code.trim(),
          );
      await ref
          .read(sessionProvider.notifier)
          .save(
            SessionIdentity(
              accessToken: session.accessToken,
              refreshToken: session.refreshToken,
              userId: session.userId,
            ),
          );

      if (session.isNewAccount) {
        state = state.copyWith(step: AuthStep.name, isSubmitting: false);
        return false;
      }
      state = const AuthState();
      return true;
    } on OtpInvalidCodeException {
      state = state.copyWith(isSubmitting: false, error: AuthError.invalidCode);
    } on OtpExpiredCodeException {
      state = state.copyWith(isSubmitting: false, error: AuthError.expiredCode);
    } on OtpTooManyAttemptsException {
      state = state.copyWith(
        isSubmitting: false,
        error: AuthError.tooManyAttempts,
      );
    } on AuthDeviceConflictException {
      state = state.copyWith(
        isSubmitting: false,
        error: AuthError.deviceConflict,
      );
    } on AuthDeviceTokenInvalidException {
      // The stored device credential looked valid locally but the server
      // no longer recognizes it — replaying the same token on retry would
      // just 401 again, so drop it and let the next attempt's init() call
      // above register a fresh one (mirrors
      // cat_update_composer_notifier's identical recovery for its own
      // stale-credential case). Best-effort: a secure-storage deletion
      // failure must not leave the user stuck in isSubmitting forever
      // without ever seeing the retryable error.
      try {
        await ref.read(deviceIdentityServiceProvider).invalidate();
      } catch (_) {
        // Ignored — falling through still surfaces the retryable error.
      }
      state = state.copyWith(
        isSubmitting: false,
        error: AuthError.staleDeviceCredential,
      );
    } on AuthNetworkException {
      state = state.copyWith(isSubmitting: false, error: AuthError.network);
    } catch (_) {
      state = state.copyWith(isSubmitting: false, error: AuthError.server);
    }
    return false;
  }

  Future<bool> submitName() async {
    if (state.isSubmitting) return false;
    final trimmed = state.name.trim();
    if (trimmed.isEmpty) {
      state = state.copyWith(error: AuthError.nameRequired);
      return false;
    }

    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      await ref.read(authApiProvider).setDisplayName(trimmed);
      state = const AuthState();
      return true;
    } on InvalidDisplayNameException {
      state = state.copyWith(
        isSubmitting: false,
        error: AuthError.nameRequired,
      );
    } on AuthNetworkException {
      state = state.copyWith(isSubmitting: false, error: AuthError.network);
    } catch (_) {
      state = state.copyWith(isSubmitting: false, error: AuthError.server);
    }
    return false;
  }

  /// Abandons the flow without authenticating (mirrors the prototype's
  /// "Vazgeç"/`cancelLogin`).
  void cancel() {
    state = const AuthState();
  }

  String _digits(String value) => value.replaceAll(RegExp(r'\D'), '');
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);
