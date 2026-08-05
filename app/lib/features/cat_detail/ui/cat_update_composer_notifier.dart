import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/analytics/analytics.dart';
import '../../../core/identity/device_identity.dart';
import '../../../core/identity/session_identity.dart';
import '../../../core/states/optimistic_inline_row.dart';
import '../data/cat_detail_api.dart';
import 'cat_detail_notifier.dart';

/// The fixed mvp status vocabulary approved on issue #3
/// (docs/product/updates.md) — order here drives the composition sheet's
/// display order.
const catUpdateStatusOptions = ['seen', 'fed', 'water_provided'];

/// The help note's fixed cap (issue #100 contract, decision 4): at most
/// 500 unicode characters — applies to the help note only, never an
/// ordinary comment.
const helpNoteMaxLength = 500;

enum UpdateSubmitError { validation, unauthorized, notFound, network, server }

/// Turkish, actionable copy for each mapped failure (issue #43) — every
/// state here implies "try again", so none of them claim to be permanent.
String updateSubmitErrorMessageTr(UpdateSubmitError error) {
  return switch (error) {
    UpdateSubmitError.validation =>
      'En az bir durum seç ya da yardımı işaretle.',
    UpdateSubmitError.unauthorized => 'Kimlik doğrulanamadı, tekrar dene.',
    UpdateSubmitError.notFound => 'Bu kedi artık bulunamıyor.',
    UpdateSubmitError.network => 'Bağlantı sorunu, tekrar dene.',
    UpdateSubmitError.server => 'Sunucuya ulaşılamadı, birazdan tekrar dene.',
  };
}

/// One ordinary submission's optimistic timeline presence (docs/design/
/// app-states.md, mutation affordances): dropped into the list in the same
/// frame as the tap, settled into the server-confirmed entry on success,
/// flipped to [InlineSaveStatus.failed] on failure — where it never
/// disappears until a retry succeeds. Help-carrying submissions never
/// create one: their feedback is the sheet's own submitting button, and
/// the active-alert banner is always built from the server-confirmed
/// entry (expiry is server-computed), never optimistically.
class PendingUpdate {
  /// Defensively wraps [statuses] so this state object stays immutable
  /// even though the caller's list is not — mutating it through
  /// `state.pending` would bypass Riverpod's state-change notifications.
  PendingUpdate({required List<String> statuses, required this.status})
    : statuses = List.unmodifiable(statuses);

  final List<String> statuses;
  final InlineSaveStatus status;
}

/// Second-person past-tense forms for the optimistic row, extending the
/// contract's one bound example "su verdin · kaydediliyor" to the other
/// two approved statuses.
const _statusDoneTr = {
  'seen': 'gördün',
  'fed': 'mama verdin',
  'water_provided': 'su verdin',
};

/// The optimistic row's full label — statuses joined with the contract's
/// " · " separator, closed by "kaydediliyor" while saving and its direct
/// negation "kaydedilemedi" once failed. The status vocabulary is fixed
/// ([catUpdateStatusOptions]), so an unknown key can only mean a
/// programming error: it is asserted in debug and omitted in release
/// rather than ever showing a raw internal key to the user.
String optimisticUpdateLabelTr(PendingUpdate pending) {
  assert(
    pending.statuses.every(_statusDoneTr.containsKey),
    'unknown status in optimistic row: ${pending.statuses}',
  );
  final parts = pending.statuses
      .where(_statusDoneTr.containsKey)
      .map((s) => _statusDoneTr[s]!);
  final tail = pending.status == InlineSaveStatus.saving
      ? 'kaydediliyor'
      : 'kaydedilemedi';
  return [...parts, tail].join(' · ');
}

class CatUpdateComposerState {
  const CatUpdateComposerState({
    this.selectedStatuses = const {},
    this.needsHelp = false,
    this.comment = '',
    this.isSubmitting = false,
    this.error,
    this.pending,
  });

  final Set<String> selectedStatuses;

  /// Whether the single `yardıma ihtiyacı var` mark is selected (issue
  /// #100/#102) — one boolean, no categories. Combinable with statuses in
  /// the same submission.
  final bool needsHelp;
  final String comment;
  final bool isSubmitting;
  final UpdateSubmitError? error;

  /// The ordinary submission currently shown as an optimistic timeline
  /// row — saving while in flight, failed (and kept) after a failure,
  /// null once no attempt is pending.
  final PendingUpdate? pending;

  /// The create invariant (docs/architecture/api.md): at least one status
  /// or the help flag; comment-only submissions stay invalid.
  bool get canSubmit =>
      (selectedStatuses.isNotEmpty || needsHelp) && !isSubmitting;

  CatUpdateComposerState copyWith({
    Set<String>? selectedStatuses,
    bool? needsHelp,
    String? comment,
    bool? isSubmitting,
    UpdateSubmitError? error,
    bool clearError = false,
    PendingUpdate? pending,
    bool clearPending = false,
  }) {
    return CatUpdateComposerState(
      selectedStatuses: selectedStatuses ?? this.selectedStatuses,
      needsHelp: needsHelp ?? this.needsHelp,
      comment: comment ?? this.comment,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      error: clearError ? null : (error ?? this.error),
      pending: clearPending ? null : (pending ?? this.pending),
    );
  }
}

/// Drives issue #43's write path from its single remaining entry point:
/// the composition sheet's multi-select + optional comment, opened by the
/// screen's one "+ update" action (binding design docs/design/screens/
/// cat-profile.html — the former one-tap "seen" shortcut is superseded;
/// "gördüm" is an option inside the sheet). [submit] is a no-op while a
/// submission is already in flight.
///
/// Ordinary submissions are optimistic per the adopted application-state
/// contract (docs/design/app-states.md, mutation affordances, superseding
/// issue #43's earlier "no optimistic persistence" note): a [PendingUpdate]
/// row appears in the same synchronous state change as the tap, and only
/// the server-confirmed entry ever lands on [CatDetailNotifier] — on
/// success the pending row is replaced by it in the same frame. A
/// help-carrying submission stays synchronous in the sheet: its note is
/// visibly retained there on failure ("data is never lost"), and the
/// active alert is never shown before the server confirms it.
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

  void toggleNeedsHelp() {
    if (state.isSubmitting) return;
    state = state.copyWith(needsHelp: !state.needsHelp, clearError: true);
  }

  void setComment(String value) {
    state = state.copyWith(comment: value);
  }

  /// Clears any selection, draft comment, and stale error from a previous
  /// open of the composition sheet — called when the sheet mounts so a
  /// dismissed-without-submitting draft never leaks into the next open.
  ///
  /// Never touches an in-flight background submission, and keeps a failed
  /// attempt whole: reopening the sheet after an optimistic failure must
  /// show the retained values and their error, ready to retry ("data is
  /// never lost"). An ordinary submission always carries a selection, so
  /// a failed pending row always has a draft to keep.
  void reset() {
    if (state.isSubmitting) return;
    if (state.pending?.status == InlineSaveStatus.failed) return;
    state = const CatUpdateComposerState();
  }

  /// Submits the current selection, help mark, and draft comment from the
  /// composition sheet. Returns true on success; on failure, [state.error]
  /// carries the mapped, turkish-ready failure for the caller to read via
  /// [updateSubmitErrorMessageTr] — and the draft (including the optional
  /// help note) survives untouched for a retry.
  Future<bool> submit() {
    final statuses = state.selectedStatuses.toList();
    if (statuses.isEmpty && !state.needsHelp) return Future.value(false);
    final trimmedComment = state.comment.trim();
    return _submit(
      statuses,
      trimmedComment.isEmpty ? null : trimmedComment,
      needsHelp: state.needsHelp,
    );
  }

  Future<bool> _submit(
    List<String> statuses,
    String? comment, {
    bool needsHelp = false,
  }) async {
    if (state.isSubmitting) return false;
    // An ordinary submission drops its optimistic row here, in the same
    // synchronous state change as the in-flight guard — feedback starts in
    // the frame of the tap. A help-carrying one never gets a row (see the
    // class doc); its feedback is the sheet's submitting button.
    state = state.copyWith(
      isSubmitting: true,
      clearError: true,
      pending: needsHelp
          ? null
          : PendingUpdate(statuses: statuses, status: InlineSaveStatus.saving),
    );
    try {
      // Defense-in-depth (issue #65): the caller is expected to have
      // already gone through AuthGate before reaching this method, so a
      // session should always be cached here — this only actually fires on
      // a stale composer instance or a logout that happened while the
      // sheet was open. The server is still the real authorization
      // boundary (RequireBearer); this is purely a fast, local check to
      // avoid a doomed round trip.
      if (ref.read(sessionIdentityServiceProvider).cached == null) {
        _fail(UpdateSubmitError.unauthorized);
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
            needsHelp: needsHelp,
            comment: comment,
            idempotencyKey: _idempotencyKey,
          );
      ref.read(catDetailProvider(catId).notifier).prependUpdate(entry);
      // A combined update emits both events (docs/product/alerts.md,
      // decision 6): ordinary_update_created when at least one status is
      // present, needs_help_created (parameterless since #101) when the
      // help mark is set. Bounded vocabularies only — the comment/note
      // text never leaves the api call above.
      final analytics = ref.read(analyticsProvider);
      if (statuses.isNotEmpty) {
        analytics.log(
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
      }
      if (needsHelp) {
        analytics.log(const AnalyticsEvent.needsHelpCreated());
      }
      state = const CatUpdateComposerState();
      _idempotencyKey = _generateIdempotencyKey();
      return true;
    } on UpdateValidationException {
      _fail(UpdateSubmitError.validation);
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
      _fail(UpdateSubmitError.unauthorized);
    } on CatNotFoundException {
      _fail(UpdateSubmitError.notFound);
    } on UpdateNetworkException {
      _fail(UpdateSubmitError.network);
    } catch (_) {
      _fail(UpdateSubmitError.server);
    }
    return false;
  }

  /// Surfaces a failed attempt: re-enables submission, records the mapped
  /// error, and — when the attempt had an optimistic row — flips that row
  /// to failed, keeping it mounted (the contract's "it never disappears").
  /// The draft itself is untouched, so a retry re-submits the same values
  /// under the same idempotency key.
  void _fail(UpdateSubmitError error) {
    final pending = state.pending;
    state = state.copyWith(
      isSubmitting: false,
      error: error,
      pending: pending == null
          ? null
          : PendingUpdate(
              statuses: pending.statuses,
              status: InlineSaveStatus.failed,
            ),
    );
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
