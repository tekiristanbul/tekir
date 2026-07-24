import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/identity/device_identity.dart';
import '../data/cat_detail_api.dart';
import 'cat_detail_notifier.dart';

/// The fixed mvp status vocabulary approved on issue #3
/// (docs/product/updates.md) — order here drives the composition sheet's
/// display order.
const catUpdateStatusOptions = ['seen', 'fed', 'water_provided'];

enum UpdateSubmitError { validation, unauthorized, notFound, network, server }

/// Turkish, actionable copy for each mapped failure (issue #43) — every
/// state here implies "try again", so none of them claim to be permanent.
String updateSubmitErrorMessageTr(UpdateSubmitError error) {
  return switch (error) {
    UpdateSubmitError.validation => 'En az bir durum seçmelisin.',
    UpdateSubmitError.unauthorized => 'Kimlik doğrulanamadı, tekrar dene.',
    UpdateSubmitError.notFound => 'Bu kedi artık bulunamıyor.',
    UpdateSubmitError.network => 'Bağlantı sorunu, tekrar dene.',
    UpdateSubmitError.server => 'Sunucuya ulaşılamadı, birazdan tekrar dene.',
  };
}

class CatUpdateComposerState {
  const CatUpdateComposerState({
    this.selectedStatuses = const {},
    this.comment = '',
    this.isSubmitting = false,
    this.error,
  });

  final Set<String> selectedStatuses;
  final String comment;
  final bool isSubmitting;
  final UpdateSubmitError? error;

  bool get canSubmit => selectedStatuses.isNotEmpty && !isSubmitting;

  CatUpdateComposerState copyWith({
    Set<String>? selectedStatuses,
    String? comment,
    bool? isSubmitting,
    UpdateSubmitError? error,
    bool clearError = false,
  }) {
    return CatUpdateComposerState(
      selectedStatuses: selectedStatuses ?? this.selectedStatuses,
      comment: comment ?? this.comment,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Drives both entry points onto issue #43's write path — the composition
/// sheet's multi-select + optional comment, and cat_detail_screen's
/// one-tap "seen" shortcut — so a submission from either surface shares
/// the same in-flight guard ([submit] is a no-op while already
/// submitting) and the same success side effect: prepending the
/// server-confirmed entry onto [CatDetailNotifier], never an optimistic
/// one, per issue #43's "do not implement optimistic persistence" note.
///
/// One instance per cat id, matching [catDetailProvider]'s family.
class CatUpdateComposerNotifier extends Notifier<CatUpdateComposerState> {
  CatUpdateComposerNotifier(this.catId);

  final String catId;

  @override
  CatUpdateComposerState build() => const CatUpdateComposerState();

  void toggleStatus(String status) {
    if (state.isSubmitting) return;
    final next = {...state.selectedStatuses};
    if (!next.remove(status)) next.add(status);
    state = state.copyWith(selectedStatuses: next, clearError: true);
  }

  void setComment(String value) {
    state = state.copyWith(comment: value);
  }

  /// Clears any selection, draft comment, and stale error from a previous
  /// open of the composition sheet — called when the sheet mounts so a
  /// dismissed-without-submitting draft never leaks into the next open.
  void reset() {
    state = const CatUpdateComposerState();
  }

  /// Submits [statusesOverride] (used by the one-tap "seen" shortcut) or
  /// the current selection when omitted. Returns true on success; on
  /// failure, [state.error] carries the mapped, turkish-ready failure for
  /// the caller to read via [updateSubmitErrorMessageTr].
  Future<bool> submit({List<String>? statusesOverride}) async {
    if (state.isSubmitting) return false;
    final statuses = statusesOverride ?? state.selectedStatuses.toList();
    if (statuses.isEmpty) return false;

    state = state.copyWith(isSubmitting: true, clearError: true);
    final trimmedComment = state.comment.trim();
    try {
      // Lazily initializes (or awaits an in-flight, or retries a
      // previously failed) device identity — never triggered merely by
      // viewing the read-only cat-detail screen, only by an actual submit.
      await ref.read(deviceIdentityServiceProvider).init();
      final entry = await ref
          .read(catDetailApiProvider)
          .createUpdate(
            catId,
            statuses: statuses,
            comment: trimmedComment.isEmpty ? null : trimmedComment,
          );
      ref.read(catDetailProvider(catId).notifier).prependUpdate(entry);
      state = const CatUpdateComposerState();
      return true;
    } on UpdateValidationException {
      state = state.copyWith(
        isSubmitting: false,
        error: UpdateSubmitError.validation,
      );
    } on UpdateUnauthorizedException {
      state = state.copyWith(
        isSubmitting: false,
        error: UpdateSubmitError.unauthorized,
      );
    } on CatNotFoundException {
      state = state.copyWith(
        isSubmitting: false,
        error: UpdateSubmitError.notFound,
      );
    } on UpdateNetworkException {
      state = state.copyWith(
        isSubmitting: false,
        error: UpdateSubmitError.network,
      );
    } catch (_) {
      state = state.copyWith(
        isSubmitting: false,
        error: UpdateSubmitError.server,
      );
    }
    return false;
  }
}

final catUpdateComposerProvider =
    NotifierProvider.family<
      CatUpdateComposerNotifier,
      CatUpdateComposerState,
      String
    >(CatUpdateComposerNotifier.new);
