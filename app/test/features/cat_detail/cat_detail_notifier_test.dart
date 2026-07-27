import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/cat_detail/data/cat_detail.dart';
import 'package:app/features/cat_detail/data/cat_detail_api.dart';
import 'package:app/features/cat_detail/ui/cat_detail_notifier.dart';

const _catId = 'cat-1';

final _detail = CatDetail(
  id: _catId,
  name: 'tekir',
  lat: 41.0256,
  lng: 28.9744,
  areaLabel: 'Galata Kulesi çevresi, Beyoğlu',
  primaryPhoto: 'https://example.com/tekir.jpg',
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdateAt: DateTime.utc(2026, 1, 2),
);

CatUpdateEntry _update(String id, {String? comment}) => CatUpdateEntry(
  id: id,
  statuses: const ['seen'],
  comment: comment,
  createdAt: DateTime.utc(2026, 1, 2),
);

/// A fake CatDetailApi whose responses are configured up front — this
/// notifier makes one fetchDetail + fetchUpdates call per load(), with no
/// out-of-order-response race to guard against (unlike the map's bounds
/// fetch), so a simple queue of canned responses is enough.
class _FakeCatDetailApi implements CatDetailApi {
  _FakeCatDetailApi({
    this.detail,
    this.detailError,
    this.updatesPages = const [],
  });

  final CatDetail? detail;
  final Object? detailError;
  final List<UpdatesPage> updatesPages;
  int _updatesCalls = 0;

  @override
  Future<CatDetail> fetchDetail(String catId) async {
    if (detailError != null) throw detailError!;
    return detail!;
  }

  @override
  Future<UpdatesPage> fetchUpdates(String catId, {String? cursor}) async {
    final page = updatesPages[_updatesCalls];
    _updatesCalls++;
    return page;
  }

  @override
  Future<CatUpdateEntry> createUpdate(
    String catId, {
    required List<String> statuses,
    String? comment,
  }) => throw UnimplementedError();

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

ProviderContainer _containerWith(_FakeCatDetailApi api) {
  final container = ProviderContainer(
    overrides: [catDetailApiProvider.overrideWithValue(api)],
  );
  return container;
}

void main() {
  test(
    'a successful load populates detail and the first updates page',
    () async {
      final container = _containerWith(
        _FakeCatDetailApi(
          detail: _detail,
          updatesPages: [
            UpdatesPage(
              items: [_update('u1', comment: 'left some food')],
              nextCursor: 'next',
            ),
          ],
        ),
      );
      addTearDown(container.dispose);

      await container.read(catDetailProvider(_catId).notifier).load();

      final state = container.read(catDetailProvider(_catId));
      expect(state.detail?.name, 'tekir');
      expect(state.updates, hasLength(1));
      expect(state.updates.single.comment, 'left some food');
      expect(state.hasNextPage, isTrue);
      expect(state.isLoading, isFalse);
      expect(state.hasLoadedOnce, isTrue);
      expect(state.notFound, isFalse);
      expect(state.error, isNull);
    },
  );

  test(
    'an empty update history is a populated state with zero items',
    () async {
      final container = _containerWith(
        _FakeCatDetailApi(
          detail: _detail,
          updatesPages: [const UpdatesPage(items: [], nextCursor: null)],
        ),
      );
      addTearDown(container.dispose);

      await container.read(catDetailProvider(_catId).notifier).load();

      final state = container.read(catDetailProvider(_catId));
      expect(state.detail, isNotNull);
      expect(state.updates, isEmpty);
      expect(state.hasNextPage, isFalse);
      expect(state.error, isNull);
      expect(state.notFound, isFalse);
    },
  );

  test('a 404 surfaces as notFound, not a generic error', () async {
    final container = _containerWith(
      _FakeCatDetailApi(detailError: const CatNotFoundException()),
    );
    addTearDown(container.dispose);

    await container.read(catDetailProvider(_catId).notifier).load();

    final state = container.read(catDetailProvider(_catId));
    expect(state.notFound, isTrue);
    expect(state.error, isNull);
    expect(state.detail, isNull);
    expect(state.isLoading, isFalse);
    expect(state.hasLoadedOnce, isTrue);
  });

  test('any other failure surfaces as a generic error, not notFound', () async {
    final container = _containerWith(
      _FakeCatDetailApi(detailError: Exception('network down')),
    );
    addTearDown(container.dispose);

    await container.read(catDetailProvider(_catId).notifier).load();

    final state = container.read(catDetailProvider(_catId));
    expect(state.error, isNotNull);
    expect(state.notFound, isFalse);
    expect(state.detail, isNull);
    expect(state.hasLoadedOnce, isTrue);
  });

  test(
    'loadMoreUpdates appends the next page and updates the cursor',
    () async {
      final container = _containerWith(
        _FakeCatDetailApi(
          detail: _detail,
          updatesPages: [
            UpdatesPage(items: [_update('u1')], nextCursor: 'page-2'),
            UpdatesPage(items: [_update('u2')], nextCursor: null),
          ],
        ),
      );
      addTearDown(container.dispose);

      final notifier = container.read(catDetailProvider(_catId).notifier);
      await notifier.load();
      await notifier.loadMoreUpdates();

      final state = container.read(catDetailProvider(_catId));
      expect(state.updates.map((u) => u.id), ['u1', 'u2']);
      expect(state.hasNextPage, isFalse);
    },
  );

  test(
    'prependUpdate (issue #43) inserts newest-first and refreshes lastUpdateAt',
    () async {
      final container = _containerWith(
        _FakeCatDetailApi(
          detail: _detail,
          updatesPages: [
            UpdatesPage(items: [_update('u1')], nextCursor: null),
          ],
        ),
      );
      addTearDown(container.dispose);

      final notifier = container.read(catDetailProvider(_catId).notifier);
      await notifier.load();

      final freshEntry = _update('u2', comment: 'az önce görüldü');
      notifier.prependUpdate(freshEntry);

      final state = container.read(catDetailProvider(_catId));
      expect(state.updates.map((u) => u.id), ['u2', 'u1']);
      expect(state.detail?.lastUpdateAt, freshEntry.createdAt);
    },
  );

  test(
    'prependUpdate is a no-op if the entry id is already in the timeline (retry-safe)',
    () async {
      final container = _containerWith(
        _FakeCatDetailApi(
          detail: _detail,
          updatesPages: [
            UpdatesPage(items: [_update('u1')], nextCursor: null),
          ],
        ),
      );
      addTearDown(container.dispose);

      final notifier = container.read(catDetailProvider(_catId).notifier);
      await notifier.load();

      notifier.prependUpdate(_update('u1', comment: 'retried submit'));

      final state = container.read(catDetailProvider(_catId));
      expect(state.updates, hasLength(1));
      expect(state.updates.single.comment, isNull);
    },
  );

  test('prependUpdate is a no-op before detail has loaded', () async {
    final container = _containerWith(_FakeCatDetailApi());
    addTearDown(container.dispose);

    final notifier = container.read(catDetailProvider(_catId).notifier);
    notifier.prependUpdate(_update('u1'));

    final state = container.read(catDetailProvider(_catId));
    expect(state.updates, isEmpty);
    expect(state.detail, isNull);
  });

  test(
    'replaceUpdate (issue #80) swaps the entry in place, keeping position',
    () async {
      final container = _containerWith(
        _FakeCatDetailApi(
          detail: _detail,
          updatesPages: [
            UpdatesPage(
              items: [_update('u2'), _update('u1')],
              nextCursor: null,
            ),
          ],
        ),
      );
      addTearDown(container.dispose);

      final notifier = container.read(catDetailProvider(_catId).notifier);
      await notifier.load();

      final corrected = _update('u1', comment: 'düzeltildi');
      notifier.replaceUpdate(corrected);

      final state = container.read(catDetailProvider(_catId));
      expect(state.updates.map((u) => u.id), ['u2', 'u1']);
      expect(state.updates[1].comment, 'düzeltildi');
    },
  );

  test(
    'replaceUpdate is a no-op if the id is no longer in the timeline',
    () async {
      final container = _containerWith(
        _FakeCatDetailApi(
          detail: _detail,
          updatesPages: [
            UpdatesPage(items: [_update('u1')], nextCursor: null),
          ],
        ),
      );
      addTearDown(container.dispose);

      final notifier = container.read(catDetailProvider(_catId).notifier);
      await notifier.load();

      notifier.replaceUpdate(_update('does-not-exist'));

      final state = container.read(catDetailProvider(_catId));
      expect(state.updates.map((u) => u.id), ['u1']);
    },
  );

  test('removeUpdate (issue #80) drops exactly the deleted entry', () async {
    final container = _containerWith(
      _FakeCatDetailApi(
        detail: _detail,
        updatesPages: [
          UpdatesPage(items: [_update('u2'), _update('u1')], nextCursor: null),
        ],
      ),
    );
    addTearDown(container.dispose);

    final notifier = container.read(catDetailProvider(_catId).notifier);
    await notifier.load();

    notifier.removeUpdate('u2');

    final state = container.read(catDetailProvider(_catId));
    expect(state.updates.map((u) => u.id), ['u1']);
  });
}
