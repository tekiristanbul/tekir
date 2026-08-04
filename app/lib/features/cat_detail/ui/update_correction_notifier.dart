import 'dart:async';

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
    UpdateCorrectionError.validation =>
      'Güncelleme boş kalamaz: bir durum seç ya da güncellemeyi sil.',
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
    this.hadNeedsHelp = false,
    this.needsHelp = false,
    this.createdAt,
    this.isSubmitting = false,
    this.error,
  });

  final List<String> statuses;
  final String comment;

  /// Whether the seeded entry carried the help mark when the sheet opened
  /// — the mark can only ever be removed by a correction, never added
  /// (docs/architecture/api.md: PATCH `needs_help: true` is a 400), so
  /// the toggle below only exists at all when this is true.
  final bool hadNeedsHelp;

  /// The mark's edited value. Only meaningful while [hadNeedsHelp].
  final bool needsHelp;

  /// The seeded entry's created_at — kept so a successful mark removal
  /// (cleared or deleted) can tell [CatDetailNotifier] which mark the
  /// cat's active state may have lost.
  final DateTime? createdAt;
  final bool isSubmitting;
  final UpdateCorrectionError? error;

  /// The server's post-state invariant (issue #101): at least one status,
  /// or the help mark survives — a patch that would hollow the row out is
  /// rejected, so don't offer to submit one; the author deletes instead.
  bool get canSubmit => (statuses.isNotEmpty || needsHelp) && !isSubmitting;

  /// True when saving would remove the entry's help mark.
  bool get clearsNeedsHelp => hadNeedsHelp && !needsHelp;

  UpdateCorrectionState copyWith({
    List<String>? statuses,
    String? comment,
    bool? hadNeedsHelp,
    bool? needsHelp,
    DateTime? createdAt,
    bool? isSubmitting,
    UpdateCorrectionError? error,
    bool clearError = false,
  }) {
    return UpdateCorrectionState(
      statuses: statuses ?? this.statuses,
      comment: comment ?? this.comment,
      hadNeedsHelp: hadNeedsHelp ?? this.hadNeedsHelp,
      needsHelp: needsHelp ?? this.needsHelp,
      createdAt: createdAt ?? this.createdAt,
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
      hadNeedsHelp: entry.needsHelp,
      needsHelp: entry.needsHelp,
      createdAt: entry.createdAt,
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

  /// Toggles the entry's help mark off (or back on, before saving) — only
  /// ever offered on an entry that already carried it: a correction can
  /// remove the mark within the window but never add one
  /// (docs/product/updates.md).
  void toggleNeedsHelp() {
    if (state.isSubmitting || !state.hadNeedsHelp) return;
    state = state.copyWith(needsHelp: !state.needsHelp, clearError: true);
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
      final cleared = state.clearsNeedsHelp;
      final entry = await ref
          .read(catDetailApiProvider)
          .correctUpdate(
            catId,
            updateId,
            statuses: state.statuses,
            comment: trimmedComment.isEmpty ? null : trimmedComment,
            clearNeedsHelp: cleared,
          );
      final detailNotifier = ref.read(catDetailProvider(catId).notifier);
      detailNotifier.replaceUpdate(entry);
      // Removing the mark may change the cat's active help state — the
      // server alone decides the fallback, so reconcile in the background
      // rather than holding the sheet open on a second round trip.
      final createdAt = state.createdAt;
      if (cleared && createdAt != null) {
        unawaited(detailNotifier.reconcileAfterHelpRemoval(createdAt));
      }
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
      final detailNotifier = ref.read(catDetailProvider(catId).notifier);
      detailNotifier.removeUpdate(updateId);
      // Deleting a help-carrying update removes its mark with it (issue
      // #101) — reconcile the active state the same way a clear does.
      final createdAt = state.createdAt;
      if (state.hadNeedsHelp && createdAt != null) {
        unawaited(detailNotifier.reconcileAfterHelpRemoval(createdAt));
      }
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
        final detailNotifier = ref.read(catDetailProvider(catId).notifier);
        detailNotifier.removeUpdate(updateId);
        final createdAt = state.createdAt;
        if (state.hadNeedsHelp && createdAt != null) {
          unawaited(detailNotifier.reconcileAfterHelpRemoval(createdAt));
        }
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
