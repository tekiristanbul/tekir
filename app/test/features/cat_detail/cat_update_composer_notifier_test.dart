import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/device_identity.dart';
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

ProviderContainer _containerWith(
  _FakeCatDetailApi api, {
  DeviceIdentityService? deviceIdentityService,
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
    'a device identity that fails to resolve surfaces as a retryable unauthorized error, without calling the update api',
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

      final firstOk = await notifier.submitSeen();
      expect(firstOk, isFalse);
      expect(
        container.read(catUpdateComposerProvider(_catId)).error,
        UpdateSubmitError.unauthorized,
      );
      expect(
        api.createUpdateCalls,
        0,
        reason: 'must not call the update api without a resolved identity',
      );

      // Retryable: the previously failed registration is retried, not
      // replayed from a stuck completed-null future.
      final secondOk = await notifier.submitSeen();
      expect(secondOk, isTrue);
      expect(api.createUpdateCalls, 1);
      expect(container.read(catUpdateComposerProvider(_catId)).error, isNull);
    },
  );

  for (final entry in {
    const UpdateValidationException(): UpdateSubmitError.validation,
    const UpdateUnauthorizedException(): UpdateSubmitError.unauthorized,
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
