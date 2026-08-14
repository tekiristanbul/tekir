import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/analytics/analytics.dart';
import '../../map/data/location_service.dart';
import '../data/add_cat_api.dart';

/// The add-cat flow's two screens (prototype/app.js's `renderAddLoc`/
/// `renderAddDetail`): location picker (with the non-blocking duplicate
/// modal shown as an overlay atop it, never its own step — see
/// [AddCatState.duplicates]) and details (photo + name + save).
enum AddCatStep { location, details }

/// Every mapped save failure. None of these are permanent — every state
/// here implies "try again" (mirrors [AuthError]'s convention).
enum AddCatError {
  missingPhoto,
  invalidSubmission,
  mediaTooLarge,
  unsupportedMedia,
  network,
  server,
  unauthorized,

  /// The pre-publication content check (issue #241) rejected the name or
  /// photo. Mirrors every other case here: implies "try again" — the photo
  /// and name are left untouched so the user can edit/replace/remove and
  /// resubmit — never a permanent dead end.
  contentRejected,
}

/// Turkish, actionable copy for each mapped failure — matches the app's
/// existing toast/error-banner vocabulary (authErrorMessageTr,
/// followActionErrorMessageTr) rather than inventing new visual language.
String addCatErrorMessageTr(AddCatError error) {
  return switch (error) {
    AddCatError.missingPhoto => 'Kaydetmeden önce bir fotoğraf ekle',
    AddCatError.invalidSubmission => 'Bilgileri kontrol edip tekrar dene.',
    AddCatError.mediaTooLarge =>
      'Fotoğraf çok büyük, daha küçük bir fotoğraf seç.',
    AddCatError.unsupportedMedia => 'Desteklenmeyen fotoğraf türü.',
    AddCatError.network => 'Bağlantı sorunu, tekrar dene.',
    AddCatError.server => 'Sunucuya ulaşılamadı, birazdan tekrar dene.',
    AddCatError.unauthorized => 'Kimlik doğrulanamadı, tekrar dene.',
    AddCatError.contentRejected =>
      'Bu içerik yayınlanamadı. Fotoğrafı veya bilgileri değiştirip '
          'tekrar dene.',
  };
}

class AddCatState {
  const AddCatState({
    this.step = AddCatStep.location,
    this.lat,
    this.lng,
    this.locationRevision = 0,
    this.geoError,
    this.duplicates = const [],
    this.confirmedNew = false,
    this.photoBytes,
    this.photoFilename,
    this.name = '',
    this.saving = false,
    this.uploadProgress,
    this.error,
  });

  final AddCatStep step;
  final double? lat;
  final double? lng;

  /// Incremented only when lat/lng change because device location was
  /// (re-)resolved (the initial automatic resolution, or an explicit "use
  /// current location" tap) — never by [AddCatNotifier.setLocation]'s own
  /// camera-pan updates. The location step's map widget watches this to
  /// know when it should itself move the camera, instead of fighting the
  /// user's own pan gesture on every frame.
  final int locationRevision;

  /// Set when the device's own location couldn't be resolved (permission
  /// denied, service disabled, timeout) — mirrors the prototype's
  /// `state.draftCat.geoError`. The user can still confirm the map's
  /// fallback center or pan to pick a location manually; this never blocks
  /// progress on its own.
  final String? geoError;

  /// Non-empty only while the duplicate-candidate modal is showing atop the
  /// location step (docs/product/cats.md/trust.md: advisory, never
  /// blocking) — not a separate [AddCatStep].
  final List<DuplicateCandidate> duplicates;

  /// True once the user has explicitly continued past a duplicate match
  /// ("yine de ekle") — sent as `confirmed_new` so a resubmission (e.g. a
  /// retry after a transient failure) never re-shows the same modal.
  final bool confirmedNew;

  final Uint8List? photoBytes;
  final String? photoFilename;
  final String name;
  final bool saving;

  /// 0..1 while the submission's multipart body is leaving the device —
  /// drives the photo-upload percentage overlay, the app's only progress
  /// indicator (docs/design/app-states.md, mutation affordances). Null
  /// whenever no upload is in flight.
  final double? uploadProgress;

  final AddCatError? error;

  bool get hasDuplicates => duplicates.isNotEmpty;

  AddCatState copyWith({
    AddCatStep? step,
    double? lat,
    double? lng,
    int? locationRevision,
    String? geoError,
    bool clearGeoError = false,
    List<DuplicateCandidate>? duplicates,
    bool? confirmedNew,
    Uint8List? photoBytes,
    String? photoFilename,
    String? name,
    bool? saving,
    double? uploadProgress,
    bool clearUploadProgress = false,
    AddCatError? error,
    bool clearError = false,
  }) {
    return AddCatState(
      step: step ?? this.step,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      locationRevision: locationRevision ?? this.locationRevision,
      geoError: clearGeoError ? null : (geoError ?? this.geoError),
      duplicates: duplicates ?? this.duplicates,
      confirmedNew: confirmedNew ?? this.confirmedNew,
      photoBytes: photoBytes ?? this.photoBytes,
      photoFilename: photoFilename ?? this.photoFilename,
      name: name ?? this.name,
      saving: saving ?? this.saving,
      uploadProgress: clearUploadProgress
          ? null
          : (uploadProgress ?? this.uploadProgress),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Drives the add-cat flow: location (with device-location resolution and
/// the non-blocking duplicate check) → details (photo + name) → submit,
/// mirroring [AuthNotifier]'s single-notifier, step-switching, app-wide-
/// instance shape exactly — including [start], called once per add-cat
/// attempt from [AddCatScreen]'s `initState` (mirrors [AuthNotifier.start]
/// / [LoginScreen]), rather than relying on provider disposal to reset
/// between attempts.
class AddCatNotifier extends Notifier<AddCatState> {
  @override
  AddCatState build() => const AddCatState();

  String _idempotencyKey = _generateIdempotencyKey();

  /// Resets the flow to a fresh attempt and kicks off device-location
  /// resolution. Call when the add-cat screen opens.
  void start() {
    state = const AddCatState();
    _idempotencyKey = _generateIdempotencyKey();
    unawaited(_useCurrentLocation());
  }

  Future<void> _useCurrentLocation() async {
    final resolved = await ref
        .read(locationServiceProvider)
        .resolveInitialCenter();
    state = state.copyWith(
      lat: resolved.center.latitude,
      lng: resolved.center.longitude,
      locationRevision: state.locationRevision + 1,
      clearGeoError: !resolved.isFallback,
      geoError: resolved.isFallback
          ? 'Konum bulunamadı. Haritadan elle seç.'
          : null,
    );
  }

  /// Re-resolves device location on an explicit "use current location" tap
  /// (prototype's `useCurrentLocation`), distinct from the automatic
  /// resolution on open so a permission prompt only re-fires when asked.
  Future<void> useCurrentLocation() => _useCurrentLocation();

  /// Called as the user pans the map (prototype's location-picker: the pin
  /// stays fixed in the center of the screen, the map moves underneath).
  void setLocation(double lat, double lng) {
    state = state.copyWith(lat: lat, lng: lng, clearGeoError: true);
  }

  /// Confirms the current location and runs the non-blocking duplicate
  /// check (prototype's `confirmLocation`). A failed check (e.g. offline)
  /// never blocks progress — duplicate detection is advisory only
  /// (docs/product/cats.md/trust.md) — it simply proceeds as if no nearby
  /// cats were found.
  Future<void> confirmLocation() async {
    final lat = state.lat;
    final lng = state.lng;
    if (lat == null || lng == null) return;
    try {
      final candidates = await ref
          .read(addCatApiProvider)
          .fetchNearby(lat: lat, lng: lng);
      if (candidates.isNotEmpty) {
        state = state.copyWith(duplicates: candidates);
        return;
      }
    } catch (_) {
      // advisory only — fall through to details either way.
    }
    state = state.copyWith(step: AddCatStep.details, duplicates: const []);
  }

  /// "Yine de ekle" — the duplicate modal never blocks creation
  /// (docs/product/cats.md/trust.md): the user explicitly continues as a
  /// different cat.
  void continueAsDifferent() {
    state = state.copyWith(
      step: AddCatStep.details,
      duplicates: const [],
      confirmedNew: true,
    );
  }

  /// Returns to the location step (the app bar's back action on the
  /// details step) without losing anything already entered there.
  void backToLocation() => state = state.copyWith(step: AddCatStep.location);

  void setName(String value) => state = state.copyWith(name: value);

  /// Picks a photo from the given source — the ui offers a choice between
  /// [ImageSource.camera] and [ImageSource.gallery] (docs/architecture/
  /// flutter.md: "image_picker for capture/selection", both, not gallery
  /// only) so a contributor can photograph a street cat on the spot.
  Future<void> pickPhoto(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    state = state.copyWith(
      photoBytes: bytes,
      photoFilename: picked.name,
      clearError: true,
    );
  }

  /// Submits the new cat. Returns the created cat's id on success, null on
  /// any failure (the error is left in [AddCatState.error] for the ui to
  /// show, with a "tekrar dene" retry that calls this again — reusing the
  /// same [_idempotencyKey], so a retry can never create a duplicate cat).
  Future<String?> save() async {
    if (state.saving) return null;
    final photoBytes = state.photoBytes;
    if (photoBytes == null) {
      state = state.copyWith(error: AddCatError.missingPhoto);
      return null;
    }
    final lat = state.lat;
    final lng = state.lng;
    if (lat == null || lng == null) {
      state = state.copyWith(error: AddCatError.invalidSubmission);
      return null;
    }

    // Same-frame mutation feedback (docs/design/app-states.md): saving and
    // the 0% upload overlay both start with the tap, never after 400 ms.
    state = state.copyWith(saving: true, clearError: true, uploadProgress: 0);
    try {
      final trimmedName = state.name.trim();
      final cat = await ref
          .read(addCatApiProvider)
          .createCat(
            lat: lat,
            lng: lng,
            name: trimmedName.isEmpty ? null : trimmedName,
            confirmedNew: state.confirmedNew,
            photoBytes: photoBytes,
            photoFilename: state.photoFilename ?? 'photo.jpg',
            idempotencyKey: _idempotencyKey,
            onSendProgress: (sent, total) {
              if (total <= 0 || !state.saving) return;
              // Keep the documented 0..1 invariant in state itself rather
              // than relying on widgets to clamp.
              state = state.copyWith(
                uploadProgress: (sent / total).clamp(0.0, 1.0),
              );
            },
          );
      // Reset in full (mirrors AuthNotifier.verifyCode's success path) —
      // there's nothing left to preserve once creation succeeds, and
      // leaving `saving: true` here would strand the ui in a disabled/
      // loading state if navigation away were ever delayed or skipped.
      state = const AddCatState();
      // cat_created (issue #84): deliberately parameterless — no name, no
      // location, no id.
      ref.read(analyticsProvider).log(const AnalyticsEvent.catCreated());
      return cat.id;
    } on AddCatDuplicateCandidatesException catch (e) {
      // A race: a matching cat was created between the location step's own
      // check and this submit. Still advisory, never a dead end — show the
      // candidates again (back on the location step) without losing the
      // details the user already entered.
      state = state.copyWith(
        saving: false,
        clearUploadProgress: true,
        step: AddCatStep.location,
        duplicates: e.candidates,
      );
      return null;
    } on AddCatMediaTooLargeException {
      state = state.copyWith(
        saving: false,
        clearUploadProgress: true,
        error: AddCatError.mediaTooLarge,
      );
      return null;
    } on AddCatUnsupportedMediaException {
      state = state.copyWith(
        saving: false,
        clearUploadProgress: true,
        error: AddCatError.unsupportedMedia,
      );
      return null;
    } on AddCatContentRejectedException {
      // The photo/name stay exactly as entered (issue #241,
      // docs/product/trust.md) — a stable, recoverable outcome the user can
      // edit/replace/remove and retry, never a report to anyone.
      state = state.copyWith(
        saving: false,
        clearUploadProgress: true,
        error: AddCatError.contentRejected,
      );
      return null;
    } on AddCatValidationException {
      state = state.copyWith(
        saving: false,
        clearUploadProgress: true,
        error: AddCatError.invalidSubmission,
      );
      return null;
    } on AddCatUnauthorizedException {
      // The add-cat flow is only reachable behind AuthGate, so this means
      // the session went stale mid-flow (e.g. revoked elsewhere) rather
      // than a routine path — mirrors follow/update's explicit 401
      // handling rather than falling through to the generic server error.
      state = state.copyWith(
        saving: false,
        clearUploadProgress: true,
        error: AddCatError.unauthorized,
      );
      return null;
    } on AddCatNetworkException {
      state = state.copyWith(
        saving: false,
        clearUploadProgress: true,
        error: AddCatError.network,
      );
      return null;
    } catch (_) {
      state = state.copyWith(
        saving: false,
        clearUploadProgress: true,
        error: AddCatError.server,
      );
      return null;
    }
  }
}

final addCatProvider = NotifierProvider<AddCatNotifier, AddCatState>(
  AddCatNotifier.new,
);

/// A high-entropy, non-guessable key — no new dependency for something this
/// small (the backend only needs uniqueness per attempt, not a specific
/// format; see docs/architecture/api.md's Idempotency-Key header).
String _generateIdempotencyKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
