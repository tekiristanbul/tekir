import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:app/core/analytics/analytics.dart';
import 'package:app/core/identity/device_identity.dart';
import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/states/optimistic_inline_row.dart';
import 'package:app/features/cat_detail/data/cat_detail.dart';
import 'package:app/features/cat_detail/data/cat_detail_api.dart';
import 'package:app/features/cat_detail/ui/cat_detail_notifier.dart';
import 'package:app/features/cat_detail/ui/cat_update_composer_notifier.dart';

const _catId = 'cat-1';

final _detail = CatDetail(
  id: _catId,
  name: 'tekir',
  lat: 41.0256,
  lng: 28.9744,
  areaLabel: 'Galata Kulesi çevresi, Beyoğlu',
  primaryPhoto: null,
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdateAt: null,
);

CatUpdateEntry _entry(String id) => CatUpdateEntry(
  id: id,
  statuses: const ['seen'],
  comment: null,
  createdAt: DateTime.utc(2026, 1, 2),
);

/// A server-confirmed help-carrying entry, the shape POST .../updates
/// answers for a `needs_help: true` submission (expiry always
/// server-computed 72h out, active on arrival).
CatUpdateEntry _helpEntry(
  String id, {
  List<String> statuses = const [],
  String? comment,
}) => CatUpdateEntry(
  id: id,
  needsHelp: true,
  statuses: statuses,
  comment: comment,
  createdAt: DateTime.utc(2026, 1, 2),
  needsHelpExpiresAt: DateTime.utc(2026, 1, 5),
  needsHelpActive: true,
);

class _RecordingAnalytics implements AnalyticsService {
  final events = <AnalyticsEvent>[];

  @override
  void log(AnalyticsEvent event) => events.add(event);

  List<String> names() => events.map((e) => e.name).toList();
}

// Storage is pre-populated so DeviceIdentityService.init() resolves from
// storage without any network call — the composer's device-identity
// initialization step is a precondition to exercise, not the api under
// test here (see device_identity_service_test.dart for that surface).
class _FakeStorage implements DeviceKeyValueStorage {
  final _data = <String, String>{'device_id': 'did-1', 'device_token': 'tok-1'};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

// Delete always throws — used to verify a secure-storage failure during
// DeviceIdentityService.invalidate() doesn't leave the composer stuck.
class _ThrowingDeleteStorage implements DeviceKeyValueStorage {
  final _data = <String, String>{'device_id': 'did-1', 'device_token': 'tok-1'};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async =>
      throw Exception('secure storage unavailable');
}

// Empty storage forces DeviceIdentityService through registration on every
// init() call whose result isn't cached — used to exercise the
// fails-then-succeeds retry path.
class _EmptyStorage implements DeviceKeyValueStorage {
  final _data = <String, String>{};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

class _FakeCatDetailApi implements CatDetailApi {
  int createUpdateCalls = 0;
  int uploadMediaCalls = 0;
  List<String>? lastStatuses;
  bool? lastNeedsHelp;
  String? lastComment;
  String? lastIdempotencyKey;
  String? lastMediaId;
  Uint8List? lastMediaBytes;
  String? lastMediaFilename;
  String? lastMediaUploadIdempotencyKey;
  final idempotencyKeysSeen = <String>[];
  final mediaUploadIdempotencyKeysSeen = <String>[];

  // When set, createUpdate awaits this before resolving/throwing — lets a
  // test hold a submission "in flight" to assert duplicate-submit
  // prevention.
  Completer<void>? gate;
  Completer<void>? uploadGate;
  (int, int)? uploadProgressEvent;

  Object? nextError;
  Object? uploadError;
  CatUpdateEntry? nextResult;
  String uploadedMediaId = 'media-1';

  @override
  Future<CatDetail> fetchDetail(String catId) async => _detail;

  @override
  Future<UpdatesPage> fetchUpdates(String catId, {String? cursor}) async =>
      const UpdatesPage(items: [], nextCursor: null);

  @override
  Future<CatUpdateEntry> createUpdate(
    String catId, {
    required List<String> statuses,
    bool needsHelp = false,
    String? comment,
    String idempotencyKey = '',
    String? mediaId,
  }) async {
    createUpdateCalls++;
    lastStatuses = statuses;
    lastNeedsHelp = needsHelp;
    lastComment = comment;
    lastIdempotencyKey = idempotencyKey;
    lastMediaId = mediaId;
    idempotencyKeysSeen.add(idempotencyKey);
    if (gate != null) await gate!.future;
    if (nextError != null) throw nextError!;
    return nextResult!;
  }

  @override
  Future<String> uploadMedia({
    required Uint8List mediaBytes,
    required String mediaFilename,
    required String idempotencyKey,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    uploadMediaCalls++;
    lastMediaBytes = mediaBytes;
    lastMediaFilename = mediaFilename;
    lastMediaUploadIdempotencyKey = idempotencyKey;
    mediaUploadIdempotencyKeysSeen.add(idempotencyKey);
    final event = uploadProgressEvent;
    if (event != null) onSendProgress?.call(event.$1, event.$2);
    if (uploadGate != null) await uploadGate!.future;
    if (uploadError != null) throw uploadError!;
    return uploadedMediaId;
  }

  @override
  Future<CatUpdateEntry> correctUpdate(
    String catId,
    String updateId, {
    required List<String> statuses,
    String? comment,
    bool clearNeedsHelp = false,
  }) => throw UnimplementedError();

  @override
  Future<void> deleteUpdate(String catId, String updateId) =>
      throw UnimplementedError();

  @override
  Future<List<CatMediaItem>> fetchMedia(String catId) async => const [];

  @override
  Future<CatDetail> setCoverPhoto(String catId, String mediaId) =>
      throw UnimplementedError();
}

// Returns a malformed (missing device_id/device_token) body on the first
// call and a valid one afterwards, mirroring device_identity_service_test's
// _CountingAdapter — used to exercise DeviceIdentityService's registration
// retry from within the composer's submit flow.
class _FlakyDeviceAdapter implements HttpClientAdapter {
  int callCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
    final body = callCount == 1
        ? '{"unexpected":"shape"}'
        : '{"device_id":"did-retry","device_token":"tok-retry"}';
    return ResponseBody.fromString(
      body,
      201,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

// Registers a fresh device_id/device_token every call — used to verify a
// re-registration actually happens after DeviceIdentityService.invalidate().
class _CountingRegistrationAdapter implements HttpClientAdapter {
  int callCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
    return ResponseBody.fromString(
      '{"device_id":"did-fresh-$callCount","device_token":"tok-fresh-$callCount"}',
      201,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

// A no-op 204 for SessionIdentityService's own best-effort revoke call
// during logout() — used by the UpdateUnauthorizedException tests below,
// which exercise the composer's session-logout recovery rather than
// SessionIdentityService's own network behavior (see
// session_identity_service_test.dart for that surface).
class _NoopAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString('', 204);

  @override
  void close({bool force = false}) {}
}

// Mirrors auth_gate_test.dart's fake exactly — implements only the public
// surface (cached/restore/save/logout) SessionIdentityService exposes.
class _FakeSessionIdentityService implements SessionIdentityService {
  _FakeSessionIdentityService({SessionIdentity? initial}) : _cached = initial;

  SessionIdentity? _cached;

  @override
  SessionIdentity? get cached => _cached;

  @override
  Future<SessionIdentity?> restore() async => _cached;

  @override
  Future<SessionIdentity?> refreshIfExpired() async => _cached;

  @override
  Future<void> save(SessionIdentity identity) async => _cached = identity;

  @override
  Future<void> logout({String? deviceToken}) async => _cached = null;
}

class _FakeImagePickerPlatform extends ImagePickerPlatform {
  XFile? nextFile;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async => nextFile;

  @override
  Future<XFile?> getVideo({
    required ImageSource source,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    Duration? maxDuration,
  }) async => nextFile;
}

const _authenticatedSession = SessionIdentity(
  accessToken: 'at',
  refreshToken: 'rt',
  userId: 'u1',
);

ProviderContainer _containerWith(
  _FakeCatDetailApi api, {
  DeviceIdentityService? deviceIdentityService,
  SessionIdentityService? sessionIdentityService,
  AnalyticsService? analytics,
}) {
  final container = ProviderContainer(
    overrides: [
      catDetailApiProvider.overrideWithValue(api),
      if (analytics != null) analyticsProvider.overrideWithValue(analytics),
      deviceIdentityServiceProvider.overrideWithValue(
        deviceIdentityService ??
            DeviceIdentityService(
              storage: _FakeStorage(),
              dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080')),
            ),
      ),
      // Every existing test below exercises an already-authenticated
      // submit (issue #65 gates the caller before this notifier ever
      // runs) — defaults to a cached session so those behaviors stay
      // unchanged; the unauthenticated case gets its own explicit test.
      sessionIdentityServiceProvider.overrideWithValue(
        sessionIdentityService ??
            _FakeSessionIdentityService(initial: _authenticatedSession),
      ),
    ],
  );
  return container;
}

/// Submits a seen-only ordinary update through the public surface the ui
/// uses since the single "+ update" action landed: select 'seen' (unless
/// a failed attempt already retained it) and submit.
Future<bool> _submitSeen(ProviderContainer container) {
  final notifier = container.read(catUpdateComposerProvider(_catId).notifier);
  if (!container
      .read(catUpdateComposerProvider(_catId))
      .selectedStatuses
      .contains('seen')) {
    notifier.toggleStatus('seen');
  }
  return notifier.submit();
}

void main() {
  final fakePlatform = _FakeImagePickerPlatform();
  ImagePickerPlatform.instance = fakePlatform;

  test('toggleStatus adds and removes from the selection', () {
    final container = _containerWith(_FakeCatDetailApi());
    addTearDown(container.dispose);
    final notifier = container.read(catUpdateComposerProvider(_catId).notifier);

    notifier.toggleStatus('seen');
    notifier.toggleStatus('fed');
    expect(container.read(catUpdateComposerProvider(_catId)).selectedStatuses, {
      'seen',
      'fed',
    });

    notifier.toggleStatus('seen');
    expect(container.read(catUpdateComposerProvider(_catId)).selectedStatuses, {
      'fed',
    });
  });

  test('submit with no selection is a no-op', () async {
    final api = _FakeCatDetailApi();
    final container = _containerWith(api);
    addTearDown(container.dispose);

    final ok = await container
        .read(catUpdateComposerProvider(_catId).notifier)
        .submit();

    expect(ok, isFalse);
    expect(api.createUpdateCalls, 0);
  });

  test('pickPhoto stores the picked bytes and filename', () async {
    final container = _containerWith(_FakeCatDetailApi());
    addTearDown(container.dispose);
    final notifier = container.read(catUpdateComposerProvider(_catId).notifier);
    fakePlatform.nextFile = XFile.fromData(
      Uint8List.fromList([1, 2, 3]),
      name: 'photo.jpg',
      path: 'photo.jpg',
    );

    await notifier.pickPhoto(ImageSource.gallery);

    final state = container.read(catUpdateComposerProvider(_catId));
    expect(state.mediaBytes, Uint8List.fromList([1, 2, 3]));
    expect(state.mediaFilename, 'photo.jpg');
  });

  test(
    'pickVideo stores the picked bytes, filename, and content type',
    () async {
      final container = _containerWith(_FakeCatDetailApi());
      addTearDown(container.dispose);
      final notifier = container.read(
        catUpdateComposerProvider(_catId).notifier,
      );
      fakePlatform.nextFile = XFile.fromData(
        Uint8List.fromList([1, 2, 3]),
        name: 'clip.mp4',
        path: 'clip.mp4',
        mimeType: 'video/mp4',
      );

      await notifier.pickVideo(ImageSource.gallery);

      final state = container.read(catUpdateComposerProvider(_catId));
      expect(state.mediaBytes, Uint8List.fromList([1, 2, 3]));
      expect(state.mediaFilename, 'clip.mp4');
      expect(state.mediaContentType, 'video/mp4');
      expect(state.isVideoMedia, isTrue);
    },
  );

  test('pickVideo without a mime type falls back to video/mp4', () async {
    final container = _containerWith(_FakeCatDetailApi());
    addTearDown(container.dispose);
    final notifier = container.read(catUpdateComposerProvider(_catId).notifier);
    fakePlatform.nextFile = XFile.fromData(
      Uint8List.fromList([1, 2, 3]),
      name: 'clip.mp4',
      path: 'clip.mp4',
    );

    await notifier.pickVideo(ImageSource.gallery);

    final state = container.read(catUpdateComposerProvider(_catId));
    expect(state.mediaContentType, 'video/mp4');
    expect(state.isVideoMedia, isTrue);
  });

  test('picking a video replaces a previously picked photo', () async {
    final container = _containerWith(_FakeCatDetailApi());
    addTearDown(container.dispose);
    final notifier = container.read(catUpdateComposerProvider(_catId).notifier);
    fakePlatform.nextFile = XFile.fromData(
      Uint8List.fromList([1, 2, 3]),
      name: 'photo.jpg',
      path: 'photo.jpg',
      mimeType: 'image/jpeg',
    );
    await notifier.pickPhoto(ImageSource.gallery);
    expect(
      container.read(catUpdateComposerProvider(_catId)).isVideoMedia,
      isFalse,
    );

    fakePlatform.nextFile = XFile.fromData(
      Uint8List.fromList([4, 5]),
      name: 'clip.mp4',
      path: 'clip.mp4',
      mimeType: 'video/mp4',
    );
    await notifier.pickVideo(ImageSource.gallery);

    final state = container.read(catUpdateComposerProvider(_catId));
    expect(state.mediaBytes, Uint8List.fromList([4, 5]));
    expect(state.mediaFilename, 'clip.mp4');
    expect(state.isVideoMedia, isTrue);
  });

  test('removeMedia clears the currently picked photo', () async {
    final container = _containerWith(_FakeCatDetailApi());
    addTearDown(container.dispose);
    final notifier = container.read(catUpdateComposerProvider(_catId).notifier);
    fakePlatform.nextFile = XFile.fromData(
      Uint8List.fromList([1, 2, 3]),
      name: 'photo.jpg',
      path: 'photo.jpg',
    );
    await notifier.pickPhoto(ImageSource.gallery);

    notifier.removeMedia();

    final state = container.read(catUpdateComposerProvider(_catId));
    expect(state.mediaBytes, isNull);
    expect(state.mediaFilename, isNull);
  });

  test(
    'a successful submit prepends the entry onto the shared cat-detail state and resets',
    () async {
      final api = _FakeCatDetailApi()..nextResult = _entry('upd-1');
      final container = _containerWith(api);
      addTearDown(container.dispose);

      await container.read(catDetailProvider(_catId).notifier).load();

      final notifier = container.read(
        catUpdateComposerProvider(_catId).notifier,
      );
      notifier.toggleStatus('seen');
      notifier.setComment('  az önce görüldü  ');

      final ok = await notifier.submit();

      expect(ok, isTrue);
      expect(api.lastStatuses, ['seen']);
      expect(api.lastComment, 'az önce görüldü', reason: 'comment is trimmed');

      final composerState = container.read(catUpdateComposerProvider(_catId));
      expect(composerState.selectedStatuses, isEmpty);
      expect(composerState.comment, isEmpty);
      expect(composerState.isSubmitting, isFalse);
      expect(composerState.error, isNull);

      final detailState = container.read(catDetailProvider(_catId));
      expect(detailState.updates.map((u) => u.id), ['upd-1']);
    },
  );

  test('a blank comment is submitted as null, not an empty string', () async {
    final api = _FakeCatDetailApi()..nextResult = _entry('upd-1');
    final container = _containerWith(api);
    addTearDown(container.dispose);
    await container.read(catDetailProvider(_catId).notifier).load();

    final notifier = container.read(catUpdateComposerProvider(_catId).notifier);
    notifier.toggleStatus('seen');
    notifier.setComment('   ');
    await notifier.submit();

    expect(api.lastComment, isNull);
  });

  test(
    'a submit with a picked photo uploads it first and passes media_id',
    () async {
      final api = _FakeCatDetailApi()..nextResult = _entry('upd-1');
      final container = _containerWith(api);
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();
      final notifier = container.read(
        catUpdateComposerProvider(_catId).notifier,
      );
      fakePlatform.nextFile = XFile.fromData(
        Uint8List.fromList([1, 2, 3]),
        name: 'photo.jpg',
        path: 'photo.jpg',
      );
      await notifier.pickPhoto(ImageSource.gallery);
      notifier.toggleStatus('seen');

      final ok = await notifier.submit();

      expect(ok, isTrue);
      expect(api.uploadMediaCalls, 1);
      expect(api.lastMediaFilename, 'photo.jpg');
      expect(api.lastMediaId, 'media-1');
      expect(container.read(catUpdateComposerProvider(_catId)).pending, isNull);
    },
  );

  test(
    'a photo upload drives progress while the sheet stays synchronous',
    () async {
      final api = _FakeCatDetailApi()
        ..nextResult = _entry('upd-1')
        ..uploadGate = Completer<void>()
        ..uploadProgressEvent = (3, 4);
      final container = _containerWith(api);
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();
      final notifier = container.read(
        catUpdateComposerProvider(_catId).notifier,
      );
      fakePlatform.nextFile = XFile.fromData(
        Uint8List.fromList([1, 2, 3]),
        name: 'photo.jpg',
        path: 'photo.jpg',
      );
      await notifier.pickPhoto(ImageSource.gallery);
      notifier.toggleStatus('seen');

      final future = notifier.submit();

      final stateWhileUploading = container.read(
        catUpdateComposerProvider(_catId),
      );
      expect(stateWhileUploading.isSubmitting, isTrue);
      expect(stateWhileUploading.uploadProgress, 0.75);
      expect(stateWhileUploading.pending, isNull);

      api.uploadGate!.complete();
      await future;
    },
  );

  test(
    'a photo upload failure keeps the draft and maps a retryable error',
    () async {
      final api = _FakeCatDetailApi()
        ..uploadError = const UpdateMediaTooLargeException();
      final container = _containerWith(api);
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();
      final notifier = container.read(
        catUpdateComposerProvider(_catId).notifier,
      );
      fakePlatform.nextFile = XFile.fromData(
        Uint8List.fromList([1, 2, 3]),
        name: 'photo.jpg',
        path: 'photo.jpg',
      );
      await notifier.pickPhoto(ImageSource.gallery);
      notifier.toggleStatus('seen');

      final ok = await notifier.submit();

      expect(ok, isFalse);
      final state = container.read(catUpdateComposerProvider(_catId));
      expect(state.error, UpdateSubmitError.mediaTooLarge);
      expect(state.mediaBytes, isNotNull);
      expect(state.selectedStatuses, {'seen'});
    },
  );

  test(
    'media not found clears the picked photo and requires a fresh pick',
    () async {
      final api = _FakeCatDetailApi()
        ..uploadError = null
        ..nextError = const UpdateMediaNotFoundException();
      final container = _containerWith(api);
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();
      final notifier = container.read(
        catUpdateComposerProvider(_catId).notifier,
      );
      fakePlatform.nextFile = XFile.fromData(
        Uint8List.fromList([1, 2, 3]),
        name: 'photo.jpg',
        path: 'photo.jpg',
      );
      await notifier.pickPhoto(ImageSource.gallery);
      notifier.toggleStatus('seen');

      final ok = await notifier.submit();

      expect(ok, isFalse);
      final state = container.read(catUpdateComposerProvider(_catId));
      expect(state.error, UpdateSubmitError.mediaNotFound);
      expect(state.mediaBytes, isNull);
      expect(state.mediaFilename, isNull);
    },
  );

  group('idempotency key (issue #80 product-owner review, finding 4)', () {
    test(
      'each successful submit uses a fresh key from the one before it',
      () async {
        final api = _FakeCatDetailApi()..nextResult = _entry('upd-1');
        final container = _containerWith(api);
        addTearDown(container.dispose);

        await _submitSeen(container);
        api.nextResult = _entry('upd-2');
        await _submitSeen(container);

        expect(api.idempotencyKeysSeen, hasLength(2));
        expect(api.idempotencyKeysSeen[0], isNot(api.idempotencyKeysSeen[1]));
        expect(api.idempotencyKeysSeen[0], isNotEmpty);
      },
    );

    test('a failed submit keeps the same key so a retry of the same attempt '
        'reuses it, never creating a second row for one logical tap', () async {
      final api = _FakeCatDetailApi()
        ..nextError = const UpdateNetworkException();
      final container = _containerWith(api);
      addTearDown(container.dispose);

      await _submitSeen(container);
      api.nextError = null;
      api.nextResult = _entry('upd-1');
      await _submitSeen(container);

      expect(api.idempotencyKeysSeen, hasLength(2));
      expect(api.idempotencyKeysSeen[0], api.idempotencyKeysSeen[1]);
    });
  });

  test('duplicate taps while submitting create at most one request', () async {
    final gate = Completer<void>();
    final api = _FakeCatDetailApi()
      ..nextResult = _entry('upd-1')
      ..gate = gate;
    final container = _containerWith(api);
    addTearDown(container.dispose);
    await container.read(catDetailProvider(_catId).notifier).load();

    final first = _submitSeen(container);
    final second = _submitSeen(container);

    expect(
      container.read(catUpdateComposerProvider(_catId)).isSubmitting,
      isTrue,
    );

    gate.complete();
    final results = await Future.wait([first, second]);

    expect(api.createUpdateCalls, 1);
    expect(results, [true, false]);
  });

  test(
    'no cached session surfaces as a retryable unauthorized error, without calling the update api (issue #65)',
    () async {
      final api = _FakeCatDetailApi()..nextResult = _entry('upd-1');
      final container = _containerWith(
        api,
        sessionIdentityService: _FakeSessionIdentityService(),
      );
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();

      final ok = await _submitSeen(container);

      expect(ok, isFalse);
      expect(
        container.read(catUpdateComposerProvider(_catId)).error,
        UpdateSubmitError.unauthorized,
      );
      expect(
        api.createUpdateCalls,
        0,
        reason: 'must not call the update api without a cached session',
      );
    },
  );

  test(
    'a device identity that fails to resolve does not block the update — it proceeds session-only, without device association (issue #65)',
    () async {
      final deviceService = DeviceIdentityService(
        storage: _EmptyStorage(),
        dio: (Dio(BaseOptions(baseUrl: 'http://localhost:8080'))
          ..httpClientAdapter = _FlakyDeviceAdapter()),
      );
      final api = _FakeCatDetailApi()..nextResult = _entry('upd-1');
      final container = _containerWith(
        api,
        deviceIdentityService: deviceService,
      );
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();

      final ok = await _submitSeen(container);

      expect(
        ok,
        isTrue,
        reason:
            'authorization comes from the bearer session alone now; a '
            'failed device registration is no longer fatal',
      );
      expect(api.createUpdateCalls, 1);
      expect(deviceService.cached, isNull);
      expect(container.read(catUpdateComposerProvider(_catId)).error, isNull);
    },
  );

  test(
    'a 401 from the update api logs out the stale session locally, leaving '
    'the device identity untouched (issue #173)',
    () async {
      final storage = _FakeStorage(); // pre-populated with did-1/tok-1
      final registrationAdapter = _CountingRegistrationAdapter();
      final deviceService = DeviceIdentityService(
        storage: storage,
        dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080'))
          ..httpClientAdapter = registrationAdapter,
      );
      final sessionService = SessionIdentityService(
        storage: _EmptyStorage(),
        dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080'))
          ..httpClientAdapter = _NoopAdapter(),
      );
      await sessionService.save(_authenticatedSession);
      final api = _FakeCatDetailApi()
        ..nextError = const UpdateUnauthorizedException();
      final container = _containerWith(
        api,
        deviceIdentityService: deviceService,
        sessionIdentityService: sessionService,
      );
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();

      final ok = await _submitSeen(container);
      expect(ok, isFalse);
      final state = container.read(catUpdateComposerProvider(_catId));
      expect(state.error, UpdateSubmitError.unauthorized);
      expect(state.isSubmitting, isFalse);
      expect(
        updateSubmitErrorMessageTr(state.error!),
        isNotEmpty,
        reason: 'every mapped error has turkish, actionable copy',
      );
      expect(
        sessionService.cached,
        isNull,
        reason: 'the rejected session — not the device — is what was wrong',
      );
      expect(
        deviceService.cached?.deviceToken,
        'tok-1',
        reason: 'a session-level 401 must never touch the device identity',
      );
      expect(
        registrationAdapter.callCount,
        0,
        reason: 'the device identity is never re-registered by this path',
      );

      // A submit attempted without logging back in fails fast, locally,
      // instead of replaying the now-cleared session against the api again.
      final retryOk = await _submitSeen(container);
      expect(retryOk, isFalse);
      expect(
        api.createUpdateCalls,
        1,
        reason: 'the retry never re-hits the api once the session is cleared',
      );
    },
  );

  test(
    'a storage failure while logging out the stale session does not leave '
    'the composer stuck submitting',
    () async {
      final sessionService = SessionIdentityService(
        storage: _ThrowingDeleteStorage(),
        dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080'))
          ..httpClientAdapter = _NoopAdapter(),
      );
      await sessionService.save(_authenticatedSession);
      final api = _FakeCatDetailApi()
        ..nextError = const UpdateUnauthorizedException();
      final container = _containerWith(
        api,
        sessionIdentityService: sessionService,
      );
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();

      final ok = await _submitSeen(container);
      expect(ok, isFalse);

      final state = container.read(catUpdateComposerProvider(_catId));
      expect(state.error, UpdateSubmitError.unauthorized);
      expect(
        state.isSubmitting,
        isFalse,
        reason: 'must not get stuck submitting when storage delete throws',
      );
    },
  );

  // UpdateUnauthorizedException is exercised separately above: it clears
  // the session rather than falling through to the generic retry-with-the-
  // same-draft path every other mapped error below shares.
  for (final entry in {
    const UpdateValidationException(): UpdateSubmitError.validation,
    const CatNotFoundException(): UpdateSubmitError.notFound,
    const UpdateNetworkException(): UpdateSubmitError.network,
    const UpdateServerException(): UpdateSubmitError.server,
  }.entries) {
    test(
      '${entry.key.runtimeType} surfaces as ${entry.value}, and is retryable',
      () async {
        final api = _FakeCatDetailApi()..nextError = entry.key;
        final container = _containerWith(api);
        addTearDown(container.dispose);
        await container.read(catDetailProvider(_catId).notifier).load();

        final ok = await _submitSeen(container);

        expect(ok, isFalse);
        final state = container.read(catUpdateComposerProvider(_catId));
        expect(state.error, entry.value);
        expect(state.isSubmitting, isFalse);
        expect(
          updateSubmitErrorMessageTr(state.error!),
          isNotEmpty,
          reason: 'every mapped error has turkish, actionable copy',
        );

        // Retryable: a following successful submit clears the error.
        api
          ..nextError = null
          ..nextResult = _entry('upd-2');
        final retryOk = await _submitSeen(container);
        expect(retryOk, isTrue);
        expect(container.read(catUpdateComposerProvider(_catId)).error, isNull);
      },
    );
  }

  test(
    'an unmapped exception also surfaces as a retryable server error',
    () async {
      final api = _FakeCatDetailApi()..nextError = Exception('boom');
      final container = _containerWith(api);
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();

      final ok = await _submitSeen(container);

      expect(ok, isFalse);
      expect(
        container.read(catUpdateComposerProvider(_catId)).error,
        UpdateSubmitError.server,
      );
    },
  );

  test(
    'reset clears selection, help mark, comment, and a stale error',
    () async {
      final api = _FakeCatDetailApi()
        ..nextError = const UpdateNetworkException();
      final container = _containerWith(api);
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();

      final notifier = container.read(
        catUpdateComposerProvider(_catId).notifier,
      );
      notifier.toggleStatus('fed');
      notifier.toggleNeedsHelp();
      notifier.setComment('taslak');
      await notifier.submit();

      notifier.reset();

      final state = container.read(catUpdateComposerProvider(_catId));
      expect(state.selectedStatuses, isEmpty);
      expect(state.needsHelp, isFalse);
      expect(state.comment, isEmpty);
      expect(state.error, isNull);
    },
  );

  group('yardıma ihtiyacı var (issue #100/#102)', () {
    test('a help-only submit is valid: no status required', () async {
      final api = _FakeCatDetailApi()..nextResult = _helpEntry('upd-1');
      final container = _containerWith(api);
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();

      final notifier = container.read(
        catUpdateComposerProvider(_catId).notifier,
      );
      notifier.toggleNeedsHelp();
      expect(
        container.read(catUpdateComposerProvider(_catId)).canSubmit,
        isTrue,
      );

      final ok = await notifier.submit();

      expect(ok, isTrue);
      expect(api.lastStatuses, isEmpty);
      expect(api.lastNeedsHelp, isTrue);
      expect(api.lastComment, isNull);
    });

    test('a help submit carries the optional note', () async {
      final api = _FakeCatDetailApi()
        ..nextResult = _helpEntry('upd-1', comment: 'kabı bomboştu');
      final container = _containerWith(api);
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();

      final notifier = container.read(
        catUpdateComposerProvider(_catId).notifier,
      );
      notifier.toggleNeedsHelp();
      notifier.setComment('  kabı bomboştu  ');
      await notifier.submit();

      expect(api.lastNeedsHelp, isTrue);
      expect(api.lastComment, 'kabı bomboştu');
    });

    test(
      'a combined status + help submit sends both and emits both events',
      () async {
        final analytics = _RecordingAnalytics();
        final api = _FakeCatDetailApi()
          ..nextResult = _helpEntry(
            'upd-1',
            statuses: const ['water_provided'],
          );
        final container = _containerWith(api, analytics: analytics);
        addTearDown(container.dispose);
        await container.read(catDetailProvider(_catId).notifier).load();

        final notifier = container.read(
          catUpdateComposerProvider(_catId).notifier,
        );
        notifier.toggleStatus('water_provided');
        notifier.toggleNeedsHelp();

        final ok = await notifier.submit();

        expect(ok, isTrue);
        expect(api.lastStatuses, ['water_provided']);
        expect(api.lastNeedsHelp, isTrue);
        expect(analytics.names(), [
          'ordinary_update_created',
          'needs_help_created',
        ]);
        expect(analytics.events[0].params, {'update_status': 'water_provided'});
        expect(
          analytics.events[1].params,
          isEmpty,
          reason:
              'needs_help_created is parameterless since #101 — no '
              'category, and never the note text',
        );
        // one submission, one timeline event.
        final detailState = container.read(catDetailProvider(_catId));
        expect(detailState.updates.map((u) => u.id), ['upd-1']);
      },
    );

    test('a help-only submit emits needs_help_created alone', () async {
      final analytics = _RecordingAnalytics();
      final api = _FakeCatDetailApi()..nextResult = _helpEntry('upd-1');
      final container = _containerWith(api, analytics: analytics);
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();

      final notifier = container.read(
        catUpdateComposerProvider(_catId).notifier,
      );
      notifier.toggleNeedsHelp();
      await notifier.submit();

      expect(analytics.names(), ['needs_help_created']);
    });

    test(
      'a successful help submit becomes the active alert, note included',
      () async {
        final api = _FakeCatDetailApi()
          ..nextResult = _helpEntry('upd-1', comment: 'halsiz görünüyor');
        final container = _containerWith(api);
        addTearDown(container.dispose);
        await container.read(catDetailProvider(_catId).notifier).load();

        final notifier = container.read(
          catUpdateComposerProvider(_catId).notifier,
        );
        notifier.toggleNeedsHelp();
        notifier.setComment('halsiz görünüyor');
        await notifier.submit();

        final alert = container
            .read(catDetailProvider(_catId))
            .detail
            ?.activeAlert;
        expect(alert, isNotNull);
        expect(alert!.comment, 'halsiz görünüyor');
        expect(alert.expiresAt, DateTime.utc(2026, 1, 5));
      },
    );

    test(
      'a failed help submit preserves the note, mark, and selection for retry',
      () async {
        final api = _FakeCatDetailApi()
          ..nextError = const UpdateNetworkException();
        final container = _containerWith(api);
        addTearDown(container.dispose);
        await container.read(catDetailProvider(_catId).notifier).load();

        final notifier = container.read(
          catUpdateComposerProvider(_catId).notifier,
        );
        notifier.toggleStatus('water_provided');
        notifier.toggleNeedsHelp();
        notifier.setComment('kabı bomboştu ve halsizdi');

        final ok = await notifier.submit();

        expect(ok, isFalse);
        final state = container.read(catUpdateComposerProvider(_catId));
        expect(state.error, UpdateSubmitError.network);
        expect(state.comment, 'kabı bomboştu ve halsizdi');
        expect(state.needsHelp, isTrue);
        expect(state.selectedStatuses, {'water_provided'});
        expect(state.isSubmitting, isFalse);

        // Retry succeeds and clears the draft.
        api
          ..nextError = null
          ..nextResult = _helpEntry(
            'upd-1',
            statuses: const ['water_provided'],
            comment: 'kabı bomboştu ve halsizdi',
          );
        final retryOk = await notifier.submit();
        expect(retryOk, isTrue);
        expect(
          container.read(catUpdateComposerProvider(_catId)).comment,
          isEmpty,
        );
      },
    );

    test('a help submit never creates an optimistic pending row', () async {
      final gate = Completer<void>();
      final api = _FakeCatDetailApi()
        ..nextResult = _helpEntry('upd-1')
        ..gate = gate;
      final container = _containerWith(api);
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();

      final notifier = container.read(
        catUpdateComposerProvider(_catId).notifier,
      );
      notifier.toggleNeedsHelp();
      final future = notifier.submit();

      expect(container.read(catUpdateComposerProvider(_catId)).pending, isNull);

      gate.complete();
      await future;
      expect(container.read(catUpdateComposerProvider(_catId)).pending, isNull);
    });
  });

  group('optimistic pending row (issue #109, mutation affordances)', () {
    test('an ordinary submit drops a saving pending row in the same '
        'synchronous state change as the tap', () async {
      final gate = Completer<void>();
      final api = _FakeCatDetailApi()
        ..nextResult = _entry('upd-1')
        ..gate = gate;
      final container = _containerWith(api);
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();

      final future = _submitSeen(container);

      final pending = container.read(catUpdateComposerProvider(_catId)).pending;
      expect(pending, isNotNull);
      expect(pending!.status, InlineSaveStatus.saving);
      expect(pending.statuses, ['seen']);

      gate.complete();
      await future;
    });

    test('success clears the pending row in the same state change that '
        'prepends the confirmed entry', () async {
      final api = _FakeCatDetailApi()..nextResult = _entry('upd-1');
      final container = _containerWith(api);
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();

      final ok = await _submitSeen(container);

      expect(ok, isTrue);
      expect(container.read(catUpdateComposerProvider(_catId)).pending, isNull);
      expect(
        container.read(catDetailProvider(_catId)).updates.map((u) => u.id),
        ['upd-1'],
      );
    });

    test('failure flips the row to failed and keeps it; the retry replaces it '
        'with a fresh saving row until success clears it', () async {
      final api = _FakeCatDetailApi()
        ..nextError = const UpdateNetworkException();
      final container = _containerWith(api);
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();

      await _submitSeen(container);

      var pending = container.read(catUpdateComposerProvider(_catId)).pending;
      expect(pending, isNotNull);
      expect(pending!.status, InlineSaveStatus.failed);
      expect(pending.statuses, ['seen']);

      final gate = Completer<void>();
      api
        ..nextError = null
        ..nextResult = _entry('upd-1')
        ..gate = gate;
      final retry = _submitSeen(container);
      pending = container.read(catUpdateComposerProvider(_catId)).pending;
      expect(pending!.status, InlineSaveStatus.saving);

      gate.complete();
      await retry;
      expect(container.read(catUpdateComposerProvider(_catId)).pending, isNull);
    });

    test(
      'reset keeps a failed attempt whole: the row, the draft, and its error '
      'all survive a sheet remount',
      () async {
        final api = _FakeCatDetailApi()
          ..nextError = const UpdateNetworkException();
        final container = _containerWith(api);
        addTearDown(container.dispose);
        await container.read(catDetailProvider(_catId).notifier).load();

        final notifier = container.read(
          catUpdateComposerProvider(_catId).notifier,
        );
        notifier.toggleStatus('water_provided');
        notifier.setComment('kabı doldurdum');
        await notifier.submit();

        notifier.reset();

        final state = container.read(catUpdateComposerProvider(_catId));
        expect(state.pending?.status, InlineSaveStatus.failed);
        expect(state.selectedStatuses, {'water_provided'});
        expect(state.comment, 'kabı doldurdum');
        expect(state.error, UpdateSubmitError.network);
      },
    );

    test('reset never touches an in-flight submission', () async {
      final gate = Completer<void>();
      final api = _FakeCatDetailApi()
        ..nextResult = _entry('upd-1')
        ..gate = gate;
      final container = _containerWith(api);
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();

      final notifier = container.read(
        catUpdateComposerProvider(_catId).notifier,
      );
      final future = _submitSeen(container);

      notifier.reset();

      final state = container.read(catUpdateComposerProvider(_catId));
      expect(state.isSubmitting, isTrue);
      expect(state.pending?.status, InlineSaveStatus.saving);

      gate.complete();
      await future;
    });

    test('the row label extends the contract copy across statuses and both '
        'states', () {
      expect(
        optimisticUpdateLabelTr(
          PendingUpdate(
            statuses: ['water_provided'],
            status: InlineSaveStatus.saving,
          ),
        ),
        'su verdin · kaydediliyor',
      );
      expect(
        optimisticUpdateLabelTr(
          PendingUpdate(statuses: ['seen'], status: InlineSaveStatus.failed),
        ),
        'gördün · kaydedilemedi',
      );
      expect(
        optimisticUpdateLabelTr(
          PendingUpdate(
            statuses: ['fed', 'water_provided'],
            status: InlineSaveStatus.saving,
          ),
        ),
        'mama verdin · su verdin · kaydediliyor',
      );
    });
  });
}
