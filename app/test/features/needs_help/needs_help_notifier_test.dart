import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/device_identity.dart';
import 'package:app/core/identity/session_identity.dart';
import 'package:app/features/cat_detail/data/cat_detail.dart';
import 'package:app/features/cat_detail/data/cat_detail_api.dart';
import 'package:app/features/cat_detail/ui/cat_detail_notifier.dart';
import 'package:app/features/needs_help/data/needs_help_api.dart';
import 'package:app/features/needs_help/ui/needs_help_notifier.dart';

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

CatUpdateEntry _entry(String id, {String category = 'injured_or_sick'}) =>
    CatUpdateEntry(
      id: id,
      kind: 'needs_help',
      statuses: const [],
      comment: null,
      createdAt: DateTime.utc(2026, 3, 1, 10),
      needsHelpCategory: category,
      needsHelpCategoryLabel: 'yaralı / hasta',
      needsHelpExpiresAt: DateTime.utc(2026, 3, 4, 10),
      needsHelpActive: true,
    );

class _FakeStorage implements DeviceKeyValueStorage {
  final _data = <String, String>{'device_id': 'did-1', 'device_token': 'tok-1'};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

class _FakeCatDetailApi implements CatDetailApi {
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
  }) async => _entry('unused');
}

class _FakeNeedsHelpApi implements NeedsHelpApi {
  int createCalls = 0;
  String? lastCategory;
  String? lastComment;

  Completer<void>? gate;
  Object? nextError;
  CatUpdateEntry? nextResult;

  @override
  Future<CatUpdateEntry> create(
    String catId, {
    required String category,
    String? comment,
  }) async {
    createCalls++;
    lastCategory = category;
    lastComment = comment;
    if (gate != null) await gate!.future;
    if (nextError != null) throw nextError!;
    return nextResult!;
  }
}

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
  Future<void> logout() async => _cached = null;
}

const _authenticatedSession = SessionIdentity(
  accessToken: 'at',
  refreshToken: 'rt',
  userId: 'u1',
);

ProviderContainer _containerWith(
  _FakeNeedsHelpApi api, {
  SessionIdentityService? sessionIdentityService,
}) {
  return ProviderContainer(
    overrides: [
      catDetailApiProvider.overrideWithValue(_FakeCatDetailApi()),
      needsHelpApiProvider.overrideWithValue(api),
      deviceIdentityServiceProvider.overrideWithValue(
        DeviceIdentityService(
          storage: _FakeStorage(),
          dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080')),
        ),
      ),
      sessionIdentityServiceProvider.overrideWithValue(
        sessionIdentityService ??
            _FakeSessionIdentityService(initial: _authenticatedSession),
      ),
    ],
  );
}

void main() {
  test('selectCategory sets a single selection, replacing any previous one', () {
    final container = _containerWith(_FakeNeedsHelpApi());
    addTearDown(container.dispose);
    final notifier = container.read(needsHelpProvider(_catId).notifier);

    notifier.selectCategory('trapped');
    expect(container.read(needsHelpProvider(_catId)).category, 'trapped');

    notifier.selectCategory('water_needed');
    expect(container.read(needsHelpProvider(_catId)).category, 'water_needed');
  });

  test('submit with no category selected is a no-op', () async {
    final api = _FakeNeedsHelpApi();
    final container = _containerWith(api);
    addTearDown(container.dispose);

    final ok = await container.read(needsHelpProvider(_catId).notifier).submit();

    expect(ok, isFalse);
    expect(api.createCalls, 0);
  });

  test(
    'a successful submit applies the entry (including the new active alert) onto cat-detail state and resets',
    () async {
      final api = _FakeNeedsHelpApi()..nextResult = _entry('nh-1');
      final container = _containerWith(api);
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();

      final notifier = container.read(needsHelpProvider(_catId).notifier);
      notifier.selectCategory('injured_or_sick');
      notifier.setComment('  sağ arka ayağını basamıyor  ');

      final ok = await notifier.submit();

      expect(ok, isTrue);
      expect(api.lastCategory, 'injured_or_sick');
      expect(
        api.lastComment,
        'sağ arka ayağını basamıyor',
        reason: 'comment is trimmed',
      );

      final state = container.read(needsHelpProvider(_catId));
      expect(state.category, isNull);
      expect(state.comment, isEmpty);
      expect(state.isSubmitting, isFalse);
      expect(state.error, isNull);

      final detailState = container.read(catDetailProvider(_catId));
      expect(detailState.updates.map((u) => u.id), ['nh-1']);
      expect(detailState.detail!.activeAlert, isNotNull);
      expect(detailState.detail!.activeAlert!.category, 'injured_or_sick');
    },
  );

  test('a blank comment is submitted as null, not an empty string', () async {
    final api = _FakeNeedsHelpApi()..nextResult = _entry('nh-1');
    final container = _containerWith(api);
    addTearDown(container.dispose);
    await container.read(catDetailProvider(_catId).notifier).load();

    final notifier = container.read(needsHelpProvider(_catId).notifier);
    notifier.selectCategory('food_needed');
    notifier.setComment('   ');
    await notifier.submit();

    expect(api.lastComment, isNull);
  });

  test('duplicate submits while in flight create at most one request', () async {
    final gate = Completer<void>();
    final api = _FakeNeedsHelpApi()
      ..nextResult = _entry('nh-1')
      ..gate = gate;
    final container = _containerWith(api);
    addTearDown(container.dispose);
    await container.read(catDetailProvider(_catId).notifier).load();

    final notifier = container.read(needsHelpProvider(_catId).notifier);
    notifier.selectCategory('trapped');

    final first = notifier.submit();
    final second = notifier.submit();

    expect(container.read(needsHelpProvider(_catId)).isSubmitting, isTrue);

    gate.complete();
    final results = await Future.wait([first, second]);

    expect(api.createCalls, 1);
    expect(results, [true, false]);
  });

  test(
    'no cached session surfaces as a retryable unauthorized error, without calling the api (issue #78)',
    () async {
      final api = _FakeNeedsHelpApi()..nextResult = _entry('nh-1');
      final container = _containerWith(
        api,
        sessionIdentityService: _FakeSessionIdentityService(),
      );
      addTearDown(container.dispose);
      await container.read(catDetailProvider(_catId).notifier).load();

      final notifier = container.read(needsHelpProvider(_catId).notifier);
      notifier.selectCategory('trapped');
      final ok = await notifier.submit();

      expect(ok, isFalse);
      expect(
        container.read(needsHelpProvider(_catId)).error,
        NeedsHelpSubmitError.unauthorized,
      );
      expect(
        api.createCalls,
        0,
        reason: 'must not call the api without a cached session',
      );
    },
  );

  for (final entry in {
    const NeedsHelpValidationException(): NeedsHelpSubmitError.validation,
    const CatNotFoundException(): NeedsHelpSubmitError.notFound,
    const NeedsHelpNetworkException(): NeedsHelpSubmitError.network,
    const NeedsHelpServerException(): NeedsHelpSubmitError.server,
  }.entries) {
    test(
      '${entry.key.runtimeType} surfaces as ${entry.value}, and is retryable without losing the selection',
      () async {
        final api = _FakeNeedsHelpApi()..nextError = entry.key;
        final container = _containerWith(api);
        addTearDown(container.dispose);
        await container.read(catDetailProvider(_catId).notifier).load();

        final notifier = container.read(needsHelpProvider(_catId).notifier);
        notifier.selectCategory('unsafe_location');
        final ok = await notifier.submit();

        expect(ok, isFalse);
        final state = container.read(needsHelpProvider(_catId));
        expect(state.error, entry.value);
        expect(state.isSubmitting, isFalse);
        expect(
          state.category,
          'unsafe_location',
          reason: 'a failed submit must not lose the selection',
        );
        expect(
          needsHelpSubmitErrorMessageTr(state.error!),
          isNotEmpty,
          reason: 'every mapped error has turkish, actionable copy',
        );

        api
          ..nextError = null
          ..nextResult = _entry('nh-2', category: 'unsafe_location');
        final retryOk = await notifier.submit();
        expect(retryOk, isTrue);
        expect(container.read(needsHelpProvider(_catId)).error, isNull);
      },
    );
  }

  test('an unmapped exception also surfaces as a retryable server error', () async {
    final api = _FakeNeedsHelpApi()..nextError = Exception('boom');
    final container = _containerWith(api);
    addTearDown(container.dispose);
    await container.read(catDetailProvider(_catId).notifier).load();

    final notifier = container.read(needsHelpProvider(_catId).notifier);
    notifier.selectCategory('trapped');
    final ok = await notifier.submit();

    expect(ok, isFalse);
    expect(
      container.read(needsHelpProvider(_catId)).error,
      NeedsHelpSubmitError.server,
    );
  });

  test('reset clears selection, comment, and a stale error', () async {
    final api = _FakeNeedsHelpApi()..nextError = const NeedsHelpNetworkException();
    final container = _containerWith(api);
    addTearDown(container.dispose);
    await container.read(catDetailProvider(_catId).notifier).load();

    final notifier = container.read(needsHelpProvider(_catId).notifier);
    notifier.selectCategory('trapped');
    notifier.setComment('taslak');
    await notifier.submit();

    notifier.reset();

    final state = container.read(needsHelpProvider(_catId));
    expect(state.category, isNull);
    expect(state.comment, isEmpty);
    expect(state.error, isNull);
  });
}
