import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/analytics/analytics.dart';
import '../../../core/identity/device_identity.dart';
import '../../../core/identity/session_identity.dart';
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

  // issue #80 product-owner review, finding 4: one key per logical submit
  // attempt (mirrors AddCatNotifier's own _idempotencyKey exactly) — kept
  // stable across a failed attempt's retry (whichever button re-triggers
  // _submit), regenerated only after a successful submit, so a rapid
  // repeat tap or a retried request can never create a second update row.
  String _idempotencyKey = _generateIdempotencyKey();

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

  /// Submits the current selection and draft comment from the composition
  /// sheet. Returns true on success; on failure, [state.error] carries the
  /// mapped, turkish-ready failure for the caller to read via
  /// [updateSubmitErrorMessageTr].
  Future<bool> submit() {
    final statuses = state.selectedStatuses.toList();
    if (statuses.isEmpty) return Future.value(false);
    final trimmedComment = state.comment.trim();
    return _submit(statuses, trimmedComment.isEmpty ? null : trimmedComment);
  }

  /// The one-tap "seen" shortcut. Deliberately bypasses [state.comment] —
  /// a draft typed into the composition sheet and then dismissed without
  /// submitting must never be attached to an unrelated one-tap update.
  Future<bool> submitSeen() => _submit(const ['seen'], null);

  Future<bool> _submit(List<String> statuses, String? comment) async {
    if (state.isSubmitting) return false;
    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      // Defense-in-depth (issue #65): the caller is expected to have
      // already gone through AuthGate before reaching this method, so a
      // session should always be cached here — this only actually fires on
      // a stale composer instance or a logout that happened while the
      // sheet was open. The server is still the real authorization
      // boundary (RequireBearer); this is purely a fast, local check to
      // avoid a doomed round trip.
      if (ref.read(sessionIdentityServiceProvider).cached == null) {
        state = state.copyWith(
          isSubmitting: false,
          error: UpdateSubmitError.unauthorized,
        );
        return false;
      }
      // Lazily initializes (or awaits an in-flight, or retries a
      // previously failed) device identity for optional association with
      // the update (author_device_id) — never required for authorization,
      // and never triggered merely by viewing the read-only cat-detail
      // screen, only by an actual submit.
      await ref.read(deviceIdentityServiceProvider).init();
      final entry = await ref
          .read(catDetailApiProvider)
          .createUpdate(
            catId,
            statuses: statuses,
            comment: comment,
            idempotencyKey: _idempotencyKey,
          );
      ref.read(catDetailProvider(catId).notifier).prependUpdate(entry);
      // ordinary_update_created (issue #84): bounded status vocabulary
      // only — the comment text never leaves the api call above.
      ref
          .read(analyticsProvider)
          .log(
            AnalyticsEvent.ordinaryUpdateCreated(
              statuses.length > 1
                  ? AnalyticsUpdateStatus.multiple
                  : switch (statuses.single) {
                      'fed' => AnalyticsUpdateStatus.fed,
                      'water_provided' => AnalyticsUpdateStatus.waterProvided,
                      _ => AnalyticsUpdateStatus.seen,
                    },
            ),
          );
      state = const CatUpdateComposerState();
      _idempotencyKey = _generateIdempotencyKey();
      return true;
    } on UpdateValidationException {
      state = state.copyWith(
        isSubmitting: false,
        error: UpdateSubmitError.validation,
      );
    } on UpdateUnauthorizedException {
      // The stored credential looked valid locally but the server rejected
      // it — replaying the same token on retry would just 401 again, so
      // drop it and force a fresh registration next time. Best-effort: a
      // secure-storage deletion failure must not leave the user stuck in
      // isSubmitting forever without ever seeing the retryable error.
      try {
        await ref.read(deviceIdentityServiceProvider).invalidate();
      } catch (_) {
        // Ignored — falling through still surfaces the unauthorized error
        // and re-enables submission below.
      }
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

/// A high-entropy, non-guessable key — no new dependency for something this
/// small (the backend only needs uniqueness per attempt, not a specific
/// format), mirrors add_cat_state.dart's identical helper exactly.
String _generateIdempotencyKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
