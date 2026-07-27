import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/device_identity.dart';
import 'package:app/core/identity/session_identity.dart';
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
  List<String>? lastStatuses;
  String? lastComment;

  // When set, createUpdate awaits this before resolving/throwing — lets a
  // test hold a submission "in flight" to assert duplicate-submit
  // prevention.
  Completer<void>? gate;

  Object? nextError;
  CatUpdateEntry? nextResult;

  @override
  Future<CatDetail> fetchDetail(String catId) async => _detail;

  @override
  Future<UpdatesPage> fetchUpdates(String catId, {String? cursor}) async =>
      const UpdatesPage(items: [], nextCursor: null);

  @override
  Future<CatUpdateEntry> createUpdate(
    String catId, {
    required List<String> statuses,
    String? comment,
  }) async {
    createUpdateCalls++;
    lastStatuses = statuses;
    lastComment = comment;
    if (gate != null) await gate!.future;
    if (nextError != null) throw nextError!;
    return nextResult!;
  }

  @override
  Future<CatUpdateEntry> correctUpdate(
    String catId,
    String updateId, {
    required List<String> statuses,
    String? comment,
  }) => throw UnimplementedError();

  @override
  Future<void> deleteUpdate(String catId, String updateId) =>
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
  Future<void> save(SessionIdentity identity) async => _cached = identity;

  @override
  Future<void> logout({String? deviceToken}) async => _cached = null;
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
}) {
  final container = ProviderContainer(
    overrides: [
      catDetailApiProvider.overrideWithValue(api),
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

void main() {
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
    'submitSeen always sends statuses: [seen], ignoring any selection',
    () async {
      final api = _FakeCatDetailApi()..nextResult = _entry('upd-1');
      final container = _containerWith(api);
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();

      final notifier = container.read(
        catUpdateComposerProvider(_catId).notifier,
      );
      notifier.toggleStatus('fed');

      final ok = await notifier.submitSeen();

      expect(ok, isTrue);
      expect(api.lastStatuses, ['seen']);
    },
  );

  test('submitSeen never sends a dismissed composer draft comment', () async {
    final api = _FakeCatDetailApi()..nextResult = _entry('upd-1');
    final container = _containerWith(api);
    addTearDown(container.dispose);
    await container.read(catDetailProvider(_catId).notifier).load();

    final notifier = container.read(catUpdateComposerProvider(_catId).notifier);
    // Simulates: sheet opened, a comment typed, sheet dismissed without
    // submitting — the composer's draft state outlives the dismissal.
    notifier.setComment('bu görülmemeliydi');

    final ok = await notifier.submitSeen();

    expect(ok, isTrue);
    expect(api.lastComment, isNull);
    expect(api.lastStatuses, ['seen']);
  });

  test('duplicate taps while submitting create at most one request', () async {
    final gate = Completer<void>();
    final api = _FakeCatDetailApi()
      ..nextResult = _entry('upd-1')
      ..gate = gate;
    final container = _containerWith(api);
    addTearDown(container.dispose);
    await container.read(catDetailProvider(_catId).notifier).load();

    final notifier = container.read(catUpdateComposerProvider(_catId).notifier);

    final first = notifier.submitSeen();
    final second = notifier.submitSeen();

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

      final notifier = container.read(
        catUpdateComposerProvider(_catId).notifier,
      );
      final ok = await notifier.submitSeen();

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

      final notifier = container.read(
        catUpdateComposerProvider(_catId).notifier,
      );

      final ok = await notifier.submitSeen();

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
    'a 401 from the update api invalidates the stale device credential so the next submit re-registers',
    () async {
      final storage = _FakeStorage(); // pre-populated with did-1/tok-1
      final registrationAdapter = _CountingRegistrationAdapter();
      final deviceService = DeviceIdentityService(
        storage: storage,
        dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080'))
          ..httpClientAdapter = registrationAdapter,
      );
      final api = _FakeCatDetailApi()
        ..nextError = const UpdateUnauthorizedException();
      final container = _containerWith(
        api,
        deviceIdentityService: deviceService,
      );
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();

      final notifier = container.read(
        catUpdateComposerProvider(_catId).notifier,
      );

      final firstOk = await notifier.submitSeen();
      expect(firstOk, isFalse);
      final state = container.read(catUpdateComposerProvider(_catId));
      expect(state.error, UpdateSubmitError.unauthorized);
      expect(state.isSubmitting, isFalse);
      expect(
        updateSubmitErrorMessageTr(state.error!),
        isNotEmpty,
        reason: 'every mapped error has turkish, actionable copy',
      );
      expect(deviceService.cached, isNull, reason: 'stale credential dropped');
      expect(storage._data.containsKey('device_token'), isFalse);
      expect(
        registrationAdapter.callCount,
        0,
        reason: 'invalidate() only clears state, it does not re-register',
      );

      // Retryable: a following successful submit re-registers and clears
      // the error.
      api
        ..nextError = null
        ..nextResult = _entry('upd-1');
      final secondOk = await notifier.submitSeen();
      expect(secondOk, isTrue);
      expect(container.read(catUpdateComposerProvider(_catId)).error, isNull);
      expect(
        registrationAdapter.callCount,
        1,
        reason: 'stale credential must not be replayed; a fresh one is used',
      );
    },
  );

  test(
    'a secure-storage failure during invalidate does not leave the composer stuck submitting',
    () async {
      final storage = _ThrowingDeleteStorage();
      final deviceService = DeviceIdentityService(
        storage: storage,
        dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080'))
          ..httpClientAdapter = _CountingRegistrationAdapter(),
      );
      final api = _FakeCatDetailApi()
        ..nextError = const UpdateUnauthorizedException();
      final container = _containerWith(
        api,
        deviceIdentityService: deviceService,
      );
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();

      final notifier = container.read(
        catUpdateComposerProvider(_catId).notifier,
      );

      final ok = await notifier.submitSeen();
      expect(ok, isFalse);

      final state = container.read(catUpdateComposerProvider(_catId));
      expect(state.error, UpdateSubmitError.unauthorized);
      expect(
        state.isSubmitting,
        isFalse,
        reason: 'must not get stuck submitting when storage delete throws',
      );

      // A later retry remains possible — the in-flight guard isn't wedged.
      api
        ..nextError = null
        ..nextResult = _entry('upd-1');
      final retryOk = await notifier.submitSeen();
      expect(retryOk, isTrue);
    },
  );

  // UpdateUnauthorizedException is exercised separately above (and below):
  // retrying it now requires a device identity service that can actually
  // re-register, since the fix for the stale-credential review comment
  // makes the composer invalidate() the credential on a 401 rather than
  // just clearing the in-memory error.
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

        final notifier = container.read(
          catUpdateComposerProvider(_catId).notifier,
        );
        final ok = await notifier.submitSeen();

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
        final retryOk = await notifier.submitSeen();
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

      final ok = await container
          .read(catUpdateComposerProvider(_catId).notifier)
          .submitSeen();

      expect(ok, isFalse);
      expect(
        container.read(catUpdateComposerProvider(_catId)).error,
        UpdateSubmitError.server,
      );
    },
  );

  test('reset clears selection, comment, and a stale error', () async {
    final api = _FakeCatDetailApi()..nextError = const UpdateNetworkException();
    final container = _containerWith(api);
    addTearDown(container.dispose);
    await container.read(catDetailProvider(_catId).notifier).load();

    final notifier = container.read(catUpdateComposerProvider(_catId).notifier);
    notifier.toggleStatus('fed');
    notifier.setComment('taslak');
    await notifier.submit();

    notifier.reset();

    final state = container.read(catUpdateComposerProvider(_catId));
    expect(state.selectedStatuses, isEmpty);
    expect(state.comment, isEmpty);
    expect(state.error, isNull);
  });
}
