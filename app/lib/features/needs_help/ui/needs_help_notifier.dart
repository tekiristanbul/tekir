import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/identity/device_identity.dart';
import '../../../core/identity/session_identity.dart';
import '../../cat_detail/data/cat_detail_api.dart' show CatNotFoundException;
import '../../cat_detail/ui/cat_detail_notifier.dart';
import '../data/needs_help_api.dart';

/// The fixed 5-category mvp needs-help vocabulary (product-owner decision
/// on issue #4, docs/product/alerts.md) — ids match the backend's own
/// closed vocabulary exactly (backend/db/migrations/00006's check
/// constraint), not the approved prototype's `injured_sick` id (a typo the
/// backend never adopted). Labels and icons are otherwise taken directly
/// from the approved prototype (prototype/data.js's HELP_REASONS) as the
/// visual/interaction reference issue #78 requires.
class NeedsHelpCategoryOption {
  const NeedsHelpCategoryOption(this.id, this.label, this.icon);

  final String id;
  final String label;
  final IconData icon;
}

const needsHelpCategoryOptions = [
  NeedsHelpCategoryOption(
    'injured_or_sick',
    'Yaralı veya hasta',
    Icons.warning_amber_rounded,
  ),
  NeedsHelpCategoryOption('food_needed', 'Mama gerekiyor', Icons.restaurant),
  NeedsHelpCategoryOption('water_needed', 'Su gerekiyor', Icons.water_drop),
  NeedsHelpCategoryOption(
    'unsafe_location',
    'Güvensiz bir yerde',
    Icons.location_on,
  ),
  NeedsHelpCategoryOption('trapped', 'Mahsur kalmış', Icons.block),
];

enum NeedsHelpSubmitError {
  validation,
  unauthorized,
  notFound,
  network,
  server,
}

/// Turkish, actionable copy for each mapped failure — mirrors
/// [updateSubmitErrorMessageTr]'s shape.
String needsHelpSubmitErrorMessageTr(NeedsHelpSubmitError error) {
  return switch (error) {
    NeedsHelpSubmitError.validation => 'Bir durum seçmelisin.',
    NeedsHelpSubmitError.unauthorized => 'Kimlik doğrulanamadı, tekrar dene.',
    NeedsHelpSubmitError.notFound => 'Bu kedi artık bulunamıyor.',
    NeedsHelpSubmitError.network => 'Bağlantı sorunu, tekrar dene.',
    NeedsHelpSubmitError.server =>
      'Sunucuya ulaşılamadı, birazdan tekrar dene.',
  };
}

class NeedsHelpState {
  const NeedsHelpState({
    this.category,
    this.comment = '',
    this.isSubmitting = false,
    this.error,
  });

  final String? category;
  final String comment;
  final bool isSubmitting;
  final NeedsHelpSubmitError? error;

  bool get canSubmit => category != null && !isSubmitting;

  NeedsHelpState copyWith({
    String? category,
    String? comment,
    bool? isSubmitting,
    NeedsHelpSubmitError? error,
    bool clearError = false,
  }) {
    return NeedsHelpState(
      category: category ?? this.category,
      comment: comment ?? this.comment,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Drives the needs-help report sheet (issue #78), mirroring
/// [CatUpdateComposerNotifier]'s shape: one instance per cat id, an
/// in-flight guard, and a success side effect that applies the
/// server-confirmed entry onto [CatDetailNotifier] — never an optimistic
/// one.
class NeedsHelpNotifier extends Notifier<NeedsHelpState> {
  NeedsHelpNotifier(this.catId);

  final String catId;

  @override
  NeedsHelpState build() => const NeedsHelpState();

  void selectCategory(String category) {
    if (state.isSubmitting) return;
    state = state.copyWith(category: category, clearError: true);
  }

  void setComment(String value) {
    state = state.copyWith(comment: value);
  }

  /// Clears any selection, draft comment, and stale error from a previous
  /// open of the sheet.
  void reset() {
    state = const NeedsHelpState();
  }

  /// Submits the current selection and draft comment. Returns true on
  /// success; on failure, [state.error] carries the mapped, turkish-ready
  /// failure for the caller to read via [needsHelpSubmitErrorMessageTr].
  Future<bool> submit() async {
    final category = state.category;
    if (category == null || state.isSubmitting) return false;

    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      // Defense-in-depth (issue #78: needs-help creation requires an
      // authenticated account): the caller is expected to have already gone
      // through AuthGate before reaching this method, so a session should
      // always be cached here — this only actually fires on a stale
      // notifier instance or a logout that happened while the sheet was
      // open. The server is still the real authorization boundary
      // (RequireBearer); this is purely a fast, local check to avoid a
      // doomed round trip.
      if (ref.read(sessionIdentityServiceProvider).cached == null) {
        state = state.copyWith(
          isSubmitting: false,
          error: NeedsHelpSubmitError.unauthorized,
        );
        return false;
      }
      // Lazily initializes (or awaits an in-flight, or retries a previously
      // failed) device identity for optional association with the update —
      // never required for authorization, only for installation/abuse
      // control, mirroring the ordinary-update composer.
      await ref.read(deviceIdentityServiceProvider).init();
      final trimmedComment = state.comment.trim();
      final entry = await ref
          .read(needsHelpApiProvider)
          .create(
            catId,
            category: category,
            comment: trimmedComment.isEmpty ? null : trimmedComment,
          );
      ref.read(catDetailProvider(catId).notifier).applyNeedsHelpUpdate(entry);
      state = const NeedsHelpState();
      return true;
    } on NeedsHelpValidationException {
      state = state.copyWith(
        isSubmitting: false,
        error: NeedsHelpSubmitError.validation,
      );
    } on NeedsHelpUnauthorizedException {
      try {
        await ref.read(deviceIdentityServiceProvider).invalidate();
      } catch (_) {
        // Ignored — falling through still surfaces the unauthorized error
        // and re-enables submission below.
      }
      state = state.copyWith(
        isSubmitting: false,
        error: NeedsHelpSubmitError.unauthorized,
      );
    } on CatNotFoundException {
      state = state.copyWith(
        isSubmitting: false,
        error: NeedsHelpSubmitError.notFound,
      );
    } on NeedsHelpNetworkException {
      state = state.copyWith(
        isSubmitting: false,
        error: NeedsHelpSubmitError.network,
      );
    } catch (_) {
      state = state.copyWith(
        isSubmitting: false,
        error: NeedsHelpSubmitError.server,
      );
    }
    return false;
  }
}

final needsHelpProvider =
    NotifierProvider.family<NeedsHelpNotifier, NeedsHelpState, String>(
      NeedsHelpNotifier.new,
    );
