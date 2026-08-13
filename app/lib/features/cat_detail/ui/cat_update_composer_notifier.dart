import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

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

enum UpdateSubmitError {
  validation,
  unauthorized,
  notFound,
  network,
  server,
  mediaTooLarge,
  unsupportedMedia,
  mediaNotFound,
}

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
    UpdateSubmitError.mediaTooLarge =>
      'Medya çok büyük, daha küçük bir dosya seç.',
    UpdateSubmitError.unsupportedMedia => 'Desteklenmeyen medya türü.',
    UpdateSubmitError.mediaNotFound => 'Medya gönderilemedi, tekrar seç.',
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
    this.mediaBytes,
    this.mediaFilename,
    this.mediaContentType,
    this.mediaMuted = true,
    this.uploadProgress,
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
  /// null once no attempt is pending. Never set for a submission that
  /// carries a photo (see [CatUpdateComposerNotifier._submit]'s doc) — the
  /// sheet stays open and synchronous for those instead.
  final PendingUpdate? pending;

  /// An optional photo or (issue #153's video support) short video attached
  /// in the sheet — read via `XFile.readAsBytes`, never a raw file path,
  /// mirroring `AddCatState.photoBytes` exactly (see its own doc for why:
  /// flutter web has no `dart:io` `File`). Null means the update carries no
  /// media, the common case. A photo and a video are mutually exclusive —
  /// picking one replaces whatever the other already held.
  final Uint8List? mediaBytes;
  final String? mediaFilename;

  /// The picked media's content type (e.g. `image/jpeg`, `video/mp4`), set
  /// alongside [mediaBytes] so the sheet knows which preview widget to
  /// render and the upload can pick the right fallback filename extension.
  /// Null exactly when [mediaBytes] is null.
  final String? mediaContentType;

  /// Whether [mediaBytes] — when set — is a video rather than a photo.
  bool get isVideoMedia => mediaContentType?.startsWith('video/') ?? false;

  /// Whether a video attachment will publish with sound (issue #194's
  /// product decision: short-form videos default to muted, with an
  /// explicit opt-in to audio via the composer's own toggle). Defaults
  /// true — meaningless for a photo attachment, and sent to `POST
  /// /v1/media` unconditionally regardless of media type.
  final bool mediaMuted;

  /// 0..1 while the picked media's multipart upload is leaving the device
  /// — mirrors `AddCatState.uploadProgress` exactly. Null whenever no
  /// upload is in flight.
  final double? uploadProgress;

  /// The create invariant (docs/architecture/api.md): at least one status
  /// or the help flag; comment-only submissions stay invalid. Attached
  /// media is always optional and never satisfies this on its own.
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
    Uint8List? mediaBytes,
    String? mediaFilename,
    String? mediaContentType,
    bool? mediaMuted,
    bool clearMedia = false,
    double? uploadProgress,
    bool clearUploadProgress = false,
  }) {
    return CatUpdateComposerState(
      selectedStatuses: selectedStatuses ?? this.selectedStatuses,
      needsHelp: needsHelp ?? this.needsHelp,
      comment: comment ?? this.comment,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      error: clearError ? null : (error ?? this.error),
      pending: clearPending ? null : (pending ?? this.pending),
      mediaBytes: clearMedia ? null : (mediaBytes ?? this.mediaBytes),
      mediaFilename: clearMedia ? null : (mediaFilename ?? this.mediaFilename),
      mediaContentType: clearMedia
          ? null
          : (mediaContentType ?? this.mediaContentType),
      mediaMuted: clearMedia ? true : (mediaMuted ?? this.mediaMuted),
      uploadProgress: clearUploadProgress
          ? null
          : (uploadProgress ?? this.uploadProgress),
    );
  }
}

/// The mixed gallery picker (issue #196's [CatUpdateComposerNotifier.
/// pickMedia]) doesn't always resolve `XFile.mimeType` for a picked file —
/// unlike [CatUpdateComposerNotifier.pickPhoto]/`pickVideo`, which already
/// know which type they asked for. Falls back to the extension of the two
/// containers `POST /v1/media` ([[api]]) actually accepts as video; anything
/// else falls back to image, matching `pickPhoto`'s own fallback.
const _videoExtensions = {'mp4', 'mov', 'm4v'};

String _guessContentTypeFromName(String name) {
  final ext = name.split('.').last.toLowerCase();
  return _videoExtensions.contains(ext) ? 'video/mp4' : 'image/jpeg';
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

  // issue #153: a separate key for the picked media's own standalone
  // upload — regenerated whenever the picked photo or video itself
  // changes (a new upload is a new attempt), but kept stable across a
  // retry of the same picked media, so a retried upload can never create
  // a second media row.
  String _mediaIdempotencyKey = _generateIdempotencyKey();

  // issue #202: bumped whenever this composer's current draft stops being
  // "the one the user is looking at" — a fresh [reset] (opening the sheet
  // again, for this cat or after navigating from another one) or the sheet
  // being dismissed via [discardInFlightMediaPick]. pickPhoto/pickVideo
  // capture the generation before their picker await and re-check it
  // after, so a picker result that resolves once the user has moved on can
  // never resurrect a selection into a draft nobody is looking at anymore.
  int _generation = 0;

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

  /// Picks a photo from the given source (issue #196 narrowed the sheet's
  /// own use of this to camera capture only — the gallery flow moved to
  /// [pickMedia]). Mirrors [AddCatNotifier.pickPhoto] exactly, including
  /// reading bytes via `XFile.readAsBytes` for flutter web compatibility.
  /// Replaces whatever media was already picked, if any (photo or video) —
  /// the sheet's picker affordance doubles as "replace" once media is
  /// showing.
  Future<void> pickPhoto(ImageSource source) async {
    if (state.isSubmitting) return;
    final generation = _generation;
    final picked = await ImagePicker().pickImage(source: source);
    if (picked == null) return;
    await _setPickedMedia(
      picked,
      fallbackContentType: 'image/jpeg',
      generation: generation,
    );
  }

  /// Picks a video from the given source (issue #153's video support) —
  /// capped at the product-approved 30-second maximum duration; a longer
  /// gallery pick is truncated to that cap by the platform picker itself.
  /// Otherwise mirrors [pickPhoto] exactly, including replacing whatever
  /// media was already picked.
  Future<void> pickVideo(ImageSource source) async {
    if (state.isSubmitting) return;
    final generation = _generation;
    final picked = await ImagePicker().pickVideo(
      source: source,
      maxDuration: const Duration(seconds: 30),
    );
    if (picked == null) return;
    await _setPickedMedia(
      picked,
      fallbackContentType: 'video/mp4',
      generation: generation,
    );
  }

  /// Picks a photo or video from the gallery in one action (issue #196):
  /// the platform's own mixed-type picker (the iOS `PHPicker`, the Android
  /// Photo Picker) lets the user choose either from a single flow, so the
  /// sheet's gallery entry point no longer needs separate photo/video
  /// actions the way camera capture still does (see [pickPhoto]/
  /// [pickVideo] — there is no equivalent unified capture call for the
  /// camera source in `image_picker`). Otherwise mirrors [pickPhoto]
  /// exactly, including replacing whatever media was already picked. A
  /// gallery-picked video is not client-side duration-capped the way
  /// [pickVideo] caps camera capture — the server's own duration check
  /// ([[api]]'s `POST /v1/media`) still applies regardless of entry point.
  Future<void> pickMedia() async {
    if (state.isSubmitting) return;
    final generation = _generation;
    final picked = await ImagePicker().pickMedia();
    if (picked == null) return;
    await _setPickedMedia(
      picked,
      fallbackContentType: _guessContentTypeFromName(picked.name),
      generation: generation,
    );
  }

  Future<void> _setPickedMedia(
    XFile picked, {
    required String fallbackContentType,
    required int generation,
  }) async {
    final bytes = await picked.readAsBytes();
    // The composer moved on — reset for a fresh session, or dismissed —
    // while this pick was in flight (issue #202). Applying it now would
    // write a selection into a draft the user isn't looking at anymore, so
    // it's silently dropped instead.
    if (generation != _generation) return;
    _mediaIdempotencyKey = _generateIdempotencyKey();
    state = state.copyWith(
      mediaBytes: bytes,
      mediaFilename: picked.name,
      mediaContentType: picked.mimeType ?? fallbackContentType,
      // issue #194: every fresh pick starts muted, regardless of what a
      // previously picked (and since replaced) video's toggle was left at.
      mediaMuted: true,
      clearError: true,
    );
  }

  /// Removes the currently picked media (photo or video), if any (issue
  /// #153).
  void removeMedia() {
    if (state.isSubmitting) return;
    state = state.copyWith(clearMedia: true, clearError: true);
  }

  /// Toggles whether the picked video will publish with sound (issue
  /// #194) — the composer's mute/unmute control, visible before upload.
  /// Meaningless while no video is picked, but harmless to call regardless.
  void toggleMuted() {
    if (state.isSubmitting) return;
    state = state.copyWith(mediaMuted: !state.mediaMuted);
  }

  /// Clears any selection, draft comment, and stale error from a previous
  /// open of the composition sheet — called by the caller opening the
  /// sheet (synchronously, before it mounts, so the very first frame can
  /// never flash a previous open's leftover media or draft; issue #202)
  /// so a dismissed-without-submitting draft never leaks into the next
  /// open, for this cat or any other.
  ///
  /// Never touches an in-flight background submission, and keeps a failed
  /// attempt whole: reopening the sheet after an optimistic failure must
  /// show the retained values and their error, ready to retry ("data is
  /// never lost"). An ordinary submission always carries a selection, so
  /// a failed pending row always has a draft to keep.
  void reset() {
    if (state.isSubmitting) return;
    if (state.pending?.status == InlineSaveStatus.failed) return;
    _generation++;
    state = const CatUpdateComposerState();
  }

  /// Invalidates any media pick still in flight from this composer session
  /// (issue #202), without otherwise touching state — called when the
  /// sheet that started the pick is dismissed. Distinct from [reset]: it
  /// must still run while a failed attempt's draft is being kept (a
  /// dismissed sheet's own in-flight pick is never that draft — picking is
  /// already blocked once a submission starts), so it carries no guard of
  /// its own.
  void discardInFlightMediaPick() {
    _generation++;
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
    final mediaBytes = state.mediaBytes;
    // An ordinary, media-less submission drops its optimistic row here, in
    // the same synchronous state change as the in-flight guard — feedback
    // starts in the frame of the tap. A help-carrying submission never
    // gets a row (see the class doc); neither does one carrying a photo or
    // video — the sheet stays open and synchronous for those too, so the
    // upload's own progress and any failure have somewhere to show (issue
    // #153; CatUpdateSheet._submit mirrors this exact condition).
    state = state.copyWith(
      isSubmitting: true,
      clearError: true,
      pending: (needsHelp || mediaBytes != null)
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
      // issue #153: a photo or video is uploaded standalone via POST
      // /v1/media first (driving uploadProgress as its multipart body
      // leaves the device), then referenced by id on the update write
      // below — never sent as part of that request's own body. This must
      // stay the first await in this branch (device identity init below
      // runs after it) so the very first progress event lands in the same
      // synchronous stretch as the tap, matching AddCatState's upload
      // feedback.
      String? mediaId;
      if (mediaBytes != null) {
        mediaId = await ref
            .read(catDetailApiProvider)
            .uploadMedia(
              mediaBytes: mediaBytes,
              mediaFilename:
                  state.mediaFilename ??
                  (state.isVideoMedia ? 'video.mp4' : 'photo.jpg'),
              idempotencyKey: _mediaIdempotencyKey,
              muted: state.mediaMuted,
              onSendProgress: (sent, total) {
                if (total <= 0 || !state.isSubmitting) return;
                state = state.copyWith(
                  uploadProgress: (sent / total).clamp(0.0, 1.0),
                );
              },
            );
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
            mediaId: mediaId,
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
      _mediaIdempotencyKey = _generateIdempotencyKey();
      return true;
    } on UpdateValidationException {
      _fail(UpdateSubmitError.validation);
    } on UpdateUnauthorizedException {
      // The global SessionRefreshInterceptor (issue #173) already tried one
      // silent refresh-and-retry before this exception ever reaches here,
      // so surfacing it means the session itself is genuinely dead — drop
      // it locally so the app falls back to the guest state instead of
      // replaying the same stale access token on every retry (issue #173;
      // this used to wrongly invalidate the device identity, which was
      // never the credential that failed). Best-effort: a secure-storage
      // deletion failure during logout must not leave the user stuck in
      // isSubmitting forever without ever seeing the retryable error.
      try {
        await ref.read(sessionProvider.notifier).logout();
      } catch (_) {
        // Ignored — falling through still surfaces the unauthorized error
        // and re-enables submission below.
      }
      _fail(UpdateSubmitError.unauthorized);
    } on CatNotFoundException {
      _fail(UpdateSubmitError.notFound);
    } on UpdateMediaTooLargeException {
      _fail(UpdateSubmitError.mediaTooLarge);
    } on UpdateMediaUnsupportedException {
      _fail(UpdateSubmitError.unsupportedMedia);
    } on UpdateMediaNotFoundException {
      // The uploaded media no longer resolves by the time the update write
      // ran — retrying with the same (now-gone) media id could only fail
      // again, so it is dropped and a fresh pick is required, unlike every
      // other failure here which keeps the draft untouched.
      state = state.copyWith(clearMedia: true);
      _mediaIdempotencyKey = _generateIdempotencyKey();
      _fail(UpdateSubmitError.mediaNotFound);
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
      clearUploadProgress: true,
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
