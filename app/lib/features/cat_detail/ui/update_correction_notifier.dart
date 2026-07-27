import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/identity/session_identity.dart';
import '../data/cat_detail.dart';
import '../data/cat_detail_api.dart';
import 'cat_detail_notifier.dart';

/// Mapped failure for the correction sheet to read via
/// [updateCorrectionErrorMessageTr] — mirrors [NeedsHelpSubmitError]'s
/// shape exactly.
enum UpdateCorrectionError {
  validation,
  unauthorized,
  notAuthor,
  notFound,
  expired,
  network,
  server,
}

/// Turkish, actionable copy for each mapped failure — mirrors
/// [needsHelpSubmitErrorMessageTr]'s register (short, declarative, no
/// exclamation marks).
String updateCorrectionErrorMessageTr(UpdateCorrectionError error) {
  return switch (error) {
    UpdateCorrectionError.validation => 'En az bir durum seçmelisin.',
    UpdateCorrectionError.unauthorized => 'Kimlik doğrulanamadı, tekrar dene.',
    UpdateCorrectionError.notAuthor => 'Bu güncelleme sana ait değil.',
    UpdateCorrectionError.notFound => 'Bu güncelleme artık bulunamıyor.',
    UpdateCorrectionError.expired =>
      'Düzeltme süresi doldu. Geçmiş artık değiştirilemez.',
    UpdateCorrectionError.network => 'Bağlantı sorunu, tekrar dene.',
    UpdateCorrectionError.server =>
      'Sunucuya ulaşılamadı, birazdan tekrar dene.',
  };
}

/// What the sheet should do once an action settles — the caller
/// (UpdateCorrectionSheet) reacts to this rather than the notifier
/// reaching into navigation/snackbar concerns itself.
enum UpdateCorrectionOutcome { saved, deleted, alreadyGone }

class UpdateCorrectionState {
  const UpdateCorrectionState({
    this.statuses = const [],
    this.comment = '',
    this.isSubmitting = false,
    this.error,
  });

  final List<String> statuses;
  final String comment;
  final bool isSubmitting;
  final UpdateCorrectionError? error;

  bool get canSubmit => statuses.isNotEmpty && !isSubmitting;

  UpdateCorrectionState copyWith({
    List<String>? statuses,
    String? comment,
    bool? isSubmitting,
    UpdateCorrectionError? error,
    bool clearError = false,
  }) {
    return UpdateCorrectionState(
      statuses: statuses ?? this.statuses,
      comment: comment ?? this.comment,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Drives the correction/delete sheet for one specific update (issue #80),
/// mirroring [NeedsHelpNotifier]'s shape: one instance per update id, an
/// in-flight guard, and a success side effect applied onto the sibling
/// [CatDetailNotifier] — never an optimistic one, always the
/// server-confirmed result.
class UpdateCorrectionNotifier extends Notifier<UpdateCorrectionState> {
  UpdateCorrectionNotifier(this.key);

  final ({String catId, String updateId}) key;

  String get catId => key.catId;
  String get updateId => key.updateId;

  @override
  UpdateCorrectionState build() => const UpdateCorrectionState();

  /// Seeds the sheet's editable fields from the entry currently on screen —
  /// called once when the sheet opens, mirroring how [NeedsHelpSheet]
  /// resets on open, except here the fields start pre-filled rather than
  /// blank since this is an edit, not a fresh contribution.
  void seed(CatUpdateEntry entry) {
    state = UpdateCorrectionState(
      statuses: entry.statuses,
      comment: entry.comment ?? '',
    );
  }

  void toggleStatus(String status) {
    if (state.isSubmitting) return;
    final statuses = [...state.statuses];
    if (statuses.contains(status)) {
      statuses.remove(status);
    } else {
      statuses.add(status);
    }
    state = state.copyWith(statuses: statuses, clearError: true);
  }

  void setComment(String value) {
    state = state.copyWith(comment: value);
  }

  Future<UpdateCorrectionOutcome?> save() async {
    if (!state.canSubmit) return null;

    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      if (ref.read(sessionIdentityServiceProvider).cached == null) {
        state = state.copyWith(
          isSubmitting: false,
          error: UpdateCorrectionError.unauthorized,
        );
        return null;
      }
      final trimmedComment = state.comment.trim();
      final entry = await ref
          .read(catDetailApiProvider)
          .correctUpdate(
            catId,
            updateId,
            statuses: state.statuses,
            comment: trimmedComment.isEmpty ? null : trimmedComment,
          );
      ref.read(catDetailProvider(catId).notifier).replaceUpdate(entry);
      state = state.copyWith(isSubmitting: false);
      return UpdateCorrectionOutcome.saved;
    } catch (e) {
      state = state.copyWith(isSubmitting: false, error: _mapError(e));
      return null;
    }
  }

  Future<UpdateCorrectionOutcome?> delete() async {
    if (state.isSubmitting) return null;

    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      if (ref.read(sessionIdentityServiceProvider).cached == null) {
        state = state.copyWith(
          isSubmitting: false,
          error: UpdateCorrectionError.unauthorized,
        );
        return null;
      }
      await ref.read(catDetailApiProvider).deleteUpdate(catId, updateId);
      ref.read(catDetailProvider(catId).notifier).removeUpdate(updateId);
      state = state.copyWith(isSubmitting: false);
      return UpdateCorrectionOutcome.deleted;
    } catch (e) {
      // A concurrent delete from another device/tab beating this one to it
      // is not a distinct error state (docs/architecture/api.md's
      // idempotent-delete note) — but the *client* only learns about that
      // race via a 404 on an id it just saw on screen. Treat a not-found
      // delete attempt as "already gone" rather than a hard failure: the
      // end state (this update is gone) is exactly what the user wanted.
      if (e is UpdateCorrectionNotFoundException) {
        ref.read(catDetailProvider(catId).notifier).removeUpdate(updateId);
        state = state.copyWith(isSubmitting: false);
        return UpdateCorrectionOutcome.alreadyGone;
      }
      state = state.copyWith(isSubmitting: false, error: _mapError(e));
      return null;
    }
  }

  UpdateCorrectionError _mapError(Object e) {
    return switch (e) {
      UpdateValidationException() => UpdateCorrectionError.validation,
      UpdateUnauthorizedException() => UpdateCorrectionError.unauthorized,
      UpdateCorrectionForbiddenException() => UpdateCorrectionError.notAuthor,
      UpdateCorrectionNotFoundException() => UpdateCorrectionError.notFound,
      UpdateCorrectionExpiredException() => UpdateCorrectionError.expired,
      UpdateNetworkException() => UpdateCorrectionError.network,
      _ => UpdateCorrectionError.server,
    };
  }
}

final updateCorrectionProvider =
    NotifierProvider.family<
      UpdateCorrectionNotifier,
      UpdateCorrectionState,
      ({String catId, String updateId})
    >(UpdateCorrectionNotifier.new);
