import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/features/cat_detail/data/cat_detail.dart';
import 'package:app/features/cat_detail/data/cat_detail_api.dart';
import 'package:app/features/cat_detail/ui/cat_detail_notifier.dart';
import 'package:app/features/discover/ui/discover_notifier.dart';
import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/map/ui/cats_map_notifier.dart';

// discoverProvider's own build() (unrelated to this notifier's own scope)
// listens to sessionProvider, which resolves this real service by default —
// a guest fake keeps the delegation test below from touching secure storage.
class _GuestSessionIdentityService implements SessionIdentityService {
  @override
  SessionIdentity? get cached => null;

  @override
  Future<SessionIdentity?> restore() async => null;

  @override
  Future<SessionIdentity?> refreshIfExpired() async => null;

  @override
  Future<void> save(SessionIdentity identity) async {}

  @override
  Future<void> logout({String? deviceToken}) async {}
}

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
  // The three-stat header's own timestamps and the cat's owner: all
  // optional-with-null-default, which is how prependUpdate used to drop
  // them without a compile error. The fixture carries them so a rebuild
  // that loses one fails a test instead of shipping.
  lastSeenAt: DateTime.utc(2026, 1, 2),
  lastFedAt: DateTime.utc(2026, 1, 1, 12),
  lastWaterAt: DateTime.utc(2026, 1, 1, 9),
  ownerUserId: 'owner-1',
);

CatUpdateEntry _update(
  String id, {
  String? comment,
  List<String> statuses = const ['seen'],
  DateTime? createdAt,
}) => CatUpdateEntry(
  id: id,
  statuses: statuses,
  comment: comment,
  createdAt: createdAt ?? DateTime.utc(2026, 1, 2),
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

  // Mutable so the reconcile tests below can change what a re-fetch
  // returns after the initial load.
  CatDetail? detail;
  Object? detailError;
  final List<UpdatesPage> updatesPages;
  int _updatesCalls = 0;

  // Captures the setCoverPhoto tests' own arguments/response — mirrors the
  // detail/detailError pair above, scoped to this one method (issue #156).
  CatDetail? setCoverResult;
  Object? setCoverError;
  String? capturedSetCoverCatId;
  String? capturedSetCoverMediaId;

  // Captures the renameCat tests' own arguments/response — same scoped
  // convention as setCoverPhoto above (issue #227).
  CatDetail? renameResult;
  Object? renameError;
  String? capturedRenameCatId;
  String? capturedRenameName;

  // Captures the deleteCat tests' own arguments — same scoped convention
  // as renameCat above (issue #228).
  Object? deleteError;
  String? capturedDeleteCatId;

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
    bool needsHelp = false,
    String? comment,
    String idempotencyKey = '',
    String? mediaId,
  }) => throw UnimplementedError();

  @override
  Future<String> uploadMedia({
    required Uint8List mediaBytes,
    required String mediaFilename,
    required String idempotencyKey,
    required bool muted,
    void Function(int sent, int total)? onSendProgress,
  }) => throw UnimplementedError();

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
  Future<CatDetail> setCoverPhoto(String catId, String mediaId) async {
    capturedSetCoverCatId = catId;
    capturedSetCoverMediaId = mediaId;
    if (setCoverError != null) throw setCoverError!;
    return setCoverResult!;
  }

  @override
  Future<CatDetail> renameCat(String catId, String name) async {
    capturedRenameCatId = catId;
    capturedRenameName = name;
    if (renameError != null) throw renameError!;
    return renameResult!;
  }

  @override
  Future<void> deleteCat(String catId) async {
    capturedDeleteCatId = catId;
    if (deleteError != null) throw deleteError!;
  }
}

/// Records every removeCat call instead of touching real map state — proves
/// [CatDetailNotifier.deleteCat] delegates to it, without needing to drive
/// [CatsMapNotifier] through a real bounds fetch first. [CatsMapNotifier]'s
/// own removal semantics (in-place, no-op when absent) are covered directly
/// by cats_map_notifier_test.dart.
class _SpyCatsMapNotifier extends CatsMapNotifier {
  final removedIds = <String>[];

  @override
  void removeCat(String catId) => removedIds.add(catId);
}

/// Same convention as [_SpyCatsMapNotifier] above, for [DiscoverNotifier] —
/// its own removal semantics are covered directly by
/// discover_notifier_test.dart.
class _SpyDiscoverNotifier extends DiscoverNotifier {
  final removedIds = <String>[];

  @override
  void removeCat(String catId) => removedIds.add(catId);
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

  group('setCoverPhoto (issue #156)', () {
    test('replaces detail with the server-refreshed cover', () async {
      final api = _FakeCatDetailApi(
        detail: _detail,
        updatesPages: const [UpdatesPage(items: [], nextCursor: null)],
      );
      final container = _containerWith(api);
      addTearDown(container.dispose);

      final notifier = container.read(catDetailProvider(_catId).notifier);
      await notifier.load();

      final refreshed = CatDetail(
        id: _catId,
        name: 'tekir',
        lat: 41.0256,
        lng: 28.9744,
        areaLabel: _detail.areaLabel,
        primaryPhoto: 'https://example.com/new-cover.jpg',
        createdAt: _detail.createdAt,
        lastUpdateAt: _detail.lastUpdateAt,
        isOwner: true,
      );
      api.setCoverResult = refreshed;

      await notifier.setCoverPhoto('media-2');

      expect(api.capturedSetCoverCatId, _catId);
      expect(api.capturedSetCoverMediaId, 'media-2');
      final state = container.read(catDetailProvider(_catId));
      expect(state.detail?.primaryPhoto, 'https://example.com/new-cover.jpg');
      expect(state.detail?.isOwner, isTrue);
    });

    test('a failure propagates to the caller, state left untouched', () async {
      final api = _FakeCatDetailApi(
        detail: _detail,
        updatesPages: const [UpdatesPage(items: [], nextCursor: null)],
      );
      final container = _containerWith(api);
      addTearDown(container.dispose);

      final notifier = container.read(catDetailProvider(_catId).notifier);
      await notifier.load();

      api.setCoverError = Exception('not the owner');

      await expectLater(
        () => notifier.setCoverPhoto('media-2'),
        throwsA(isA<Exception>()),
      );
      final state = container.read(catDetailProvider(_catId));
      expect(state.detail?.primaryPhoto, _detail.primaryPhoto);
    });
  });

  group('renameCat (issue #227)', () {
    test('replaces detail with the server-refreshed name', () async {
      final api = _FakeCatDetailApi(
        detail: _detail,
        updatesPages: const [UpdatesPage(items: [], nextCursor: null)],
      );
      final container = _containerWith(api);
      addTearDown(container.dispose);

      final notifier = container.read(catDetailProvider(_catId).notifier);
      await notifier.load();

      final renamed = CatDetail(
        id: _catId,
        name: 'boncuk',
        lat: 41.0256,
        lng: 28.9744,
        areaLabel: _detail.areaLabel,
        primaryPhoto: _detail.primaryPhoto,
        createdAt: _detail.createdAt,
        lastUpdateAt: _detail.lastUpdateAt,
        isOwner: true,
      );
      api.renameResult = renamed;

      await notifier.renameCat('boncuk');

      expect(api.capturedRenameCatId, _catId);
      expect(api.capturedRenameName, 'boncuk');
      final state = container.read(catDetailProvider(_catId));
      expect(state.detail?.name, 'boncuk');
    });

    test('patches catsMapProvider and discoverProvider in place instead of '
        'invalidating them, so neither loses what it already had loaded '
        '(issue #230)', () async {
      final api = _FakeCatDetailApi(
        detail: _detail,
        updatesPages: const [UpdatesPage(items: [], nextCursor: null)],
      );
      final container = _containerWith(api);
      addTearDown(container.dispose);

      final notifier = container.read(catDetailProvider(_catId).notifier);
      await notifier.load();

      // Seed a selected marker for this same cat and a non-default
      // discover tab. Invalidating (the pre-#230 bug) would reset both
      // back to build()'s empty defaults; an in-place patch leaves them
      // as they were, only with the new name.
      container
          .read(catsMapProvider.notifier)
          .selectCat(
            const CatMarker(
              id: _catId,
              name: 'tekir',
              primaryPhoto: '',
              lat: 41.0,
              lng: 29.0,
            ),
          );
      container
          .read(discoverProvider.notifier)
          .selectTab(DiscoverTab.following);

      api.renameResult = CatDetail(
        id: _catId,
        name: 'boncuk',
        lat: 41.0256,
        lng: 28.9744,
        areaLabel: _detail.areaLabel,
        primaryPhoto: _detail.primaryPhoto,
        createdAt: _detail.createdAt,
        lastUpdateAt: _detail.lastUpdateAt,
        isOwner: true,
      );

      await notifier.renameCat('boncuk');

      expect(container.read(catsMapProvider).selectedMarker?.name, 'boncuk');
      expect(
        container.read(discoverProvider).selectedTab,
        DiscoverTab.following,
      );
    });

    test('a failure propagates to the caller, state left untouched', () async {
      final api = _FakeCatDetailApi(
        detail: _detail,
        updatesPages: const [UpdatesPage(items: [], nextCursor: null)],
      );
      final container = _containerWith(api);
      addTearDown(container.dispose);

      final notifier = container.read(catDetailProvider(_catId).notifier);
      await notifier.load();

      api.renameError = const RenameCatForbiddenException();

      await expectLater(
        () => notifier.renameCat('boncuk'),
        throwsA(isA<RenameCatForbiddenException>()),
      );
      final state = container.read(catDetailProvider(_catId));
      expect(state.detail?.name, _detail.name);
    });
  });

  group('deleteCat (issue #228)', () {
    test('calls the api with the cat\'s id', () async {
      final api = _FakeCatDetailApi(
        detail: _detail,
        updatesPages: const [UpdatesPage(items: [], nextCursor: null)],
      );
      final container = _containerWith(api);
      addTearDown(container.dispose);

      final notifier = container.read(catDetailProvider(_catId).notifier);
      await notifier.load();

      await notifier.deleteCat();

      expect(api.capturedDeleteCatId, _catId);
    });

    test(
      'delegates to catsMapProvider.removeCat and discoverProvider.removeCat '
      '— never invalidate (issue #230\'s defect), which this notifier\'s own '
      'in-place removeCat methods (see their own tests) exist to avoid',
      () async {
        final api = _FakeCatDetailApi(
          detail: _detail,
          updatesPages: const [UpdatesPage(items: [], nextCursor: null)],
        );
        final mapNotifier = _SpyCatsMapNotifier();
        final discoverNotifier = _SpyDiscoverNotifier();
        final container = ProviderContainer(
          overrides: [
            catDetailApiProvider.overrideWithValue(api),
            sessionIdentityServiceProvider.overrideWithValue(
              _GuestSessionIdentityService(),
            ),
            catsMapProvider.overrideWith(() => mapNotifier),
            discoverProvider.overrideWith(() => discoverNotifier),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(catDetailProvider(_catId).notifier);
        await notifier.load();

        await notifier.deleteCat();

        expect(mapNotifier.removedIds, [_catId]);
        expect(discoverNotifier.removedIds, [_catId]);
      },
    );

    test('a failure propagates to the caller', () async {
      final api = _FakeCatDetailApi(
        detail: _detail,
        updatesPages: const [UpdatesPage(items: [], nextCursor: null)],
      );
      final container = _containerWith(api);
      addTearDown(container.dispose);

      final notifier = container.read(catDetailProvider(_catId).notifier);
      await notifier.load();

      api.deleteError = const DeleteCatForbiddenException();

      await expectLater(
        () => notifier.deleteCat(),
        throwsA(isA<DeleteCatForbiddenException>()),
      );
    });
  });

  group('help mark side effects (issue #101/#102)', () {
    CatUpdateEntry helpEntry(String id, {String? comment}) => CatUpdateEntry(
      id: id,
      needsHelp: true,
      statuses: const [],
      comment: comment,
      createdAt: DateTime.utc(2026, 1, 3),
      needsHelpExpiresAt: DateTime.utc(2026, 1, 6),
      needsHelpActive: true,
    );

    CatDetail detailWithAlert(ActiveAlert? alert) => CatDetail(
      id: _catId,
      name: 'tekir',
      lat: 41.0256,
      lng: 28.9744,
      areaLabel: null,
      primaryPhoto: null,
      createdAt: DateTime.utc(2026, 1, 1),
      lastUpdateAt: DateTime.utc(2026, 1, 2),
      activeAlert: alert,
    );

    test(
      'prependUpdate promotes a help-carrying entry to the active alert, note included',
      () async {
        final container = _containerWith(
          _FakeCatDetailApi(
            detail: _detail,
            updatesPages: const [UpdatesPage(items: [], nextCursor: null)],
          ),
        );
        addTearDown(container.dispose);

        final notifier = container.read(catDetailProvider(_catId).notifier);
        await notifier.load();

        notifier.prependUpdate(helpEntry('u1', comment: 'halsiz görünüyor'));

        final state = container.read(catDetailProvider(_catId));
        expect(state.updates.map((u) => u.id), ['u1']);
        final alert = state.detail?.activeAlert;
        expect(alert, isNotNull);
        expect(alert!.comment, 'halsiz görünüyor');
        expect(alert.createdAt, DateTime.utc(2026, 1, 3));
        expect(alert.expiresAt, DateTime.utc(2026, 1, 6));
      },
    );

    test(
      'prependUpdate leaves the existing alert alone for an ordinary entry',
      () async {
        final existing = ActiveAlert(
          comment: 'önceki not',
          createdAt: DateTime.utc(2026, 1, 2),
          expiresAt: DateTime.utc(2026, 1, 5),
        );
        final container = _containerWith(
          _FakeCatDetailApi(
            detail: detailWithAlert(existing),
            updatesPages: const [UpdatesPage(items: [], nextCursor: null)],
          ),
        );
        addTearDown(container.dispose);

        final notifier = container.read(catDetailProvider(_catId).notifier);
        await notifier.load();

        notifier.prependUpdate(_update('u1'));

        expect(
          container.read(catDetailProvider(_catId)).detail?.activeAlert,
          same(existing),
        );
      },
    );

    test(
      'reconcileAfterHelpRemoval re-fetches: the server decides the fallback state',
      () async {
        final api = _FakeCatDetailApi(
          detail: detailWithAlert(
            ActiveAlert(
              comment: 'kaldırılan not',
              createdAt: DateTime.utc(2026, 1, 3),
              expiresAt: DateTime.utc(2026, 1, 6),
            ),
          ),
          updatesPages: const [UpdatesPage(items: [], nextCursor: null)],
        );
        final container = _containerWith(api);
        addTearDown(container.dispose);

        final notifier = container.read(catDetailProvider(_catId).notifier);
        await notifier.load();

        // After the clear, the server serves an older mark as the state.
        final fallback = ActiveAlert(
          comment: 'daha eski bir işaret',
          createdAt: DateTime.utc(2026, 1, 2),
          expiresAt: DateTime.utc(2026, 1, 5),
        );
        api.detail = detailWithAlert(fallback);

        await notifier.reconcileAfterHelpRemoval(DateTime.utc(2026, 1, 3));

        expect(
          container
              .read(catDetailProvider(_catId))
              .detail
              ?.activeAlert
              ?.comment,
          'daha eski bir işaret',
        );
      },
    );

    test(
      'when the re-fetch fails, the alert this mark sourced is dropped rather than left stale',
      () async {
        final api = _FakeCatDetailApi(
          detail: detailWithAlert(
            ActiveAlert(
              comment: 'kaldırılan not',
              createdAt: DateTime.utc(2026, 1, 3),
              expiresAt: DateTime.utc(2026, 1, 6),
            ),
          ),
          updatesPages: const [UpdatesPage(items: [], nextCursor: null)],
        );
        final container = _containerWith(api);
        addTearDown(container.dispose);

        final notifier = container.read(catDetailProvider(_catId).notifier);
        await notifier.load();

        api.detailError = Exception('offline');

        await notifier.reconcileAfterHelpRemoval(DateTime.utc(2026, 1, 3));

        expect(
          container.read(catDetailProvider(_catId)).detail?.activeAlert,
          isNull,
        );
      },
    );

    test(
      'when the re-fetch fails and the alert came from a different mark, it stays',
      () async {
        final api = _FakeCatDetailApi(
          detail: detailWithAlert(
            ActiveAlert(
              comment: 'başka bir işaret',
              createdAt: DateTime.utc(2026, 1, 2),
              expiresAt: DateTime.utc(2026, 1, 5),
            ),
          ),
          updatesPages: const [UpdatesPage(items: [], nextCursor: null)],
        );
        final container = _containerWith(api);
        addTearDown(container.dispose);

        final notifier = container.read(catDetailProvider(_catId).notifier);
        await notifier.load();

        api.detailError = Exception('offline');

        await notifier.reconcileAfterHelpRemoval(DateTime.utc(2026, 1, 3));

        expect(
          container
              .read(catDetailProvider(_catId))
              .detail
              ?.activeAlert
              ?.comment,
          'başka bir işaret',
        );
      },
    );
  });

  test('prependUpdate advances only the status its entry carries, and keeps '
      'every field it does not touch', () async {
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

    final fed = _update(
      'u2',
      statuses: const ['fed'],
      createdAt: DateTime.utc(2026, 1, 3),
    );
    notifier.prependUpdate(fed);

    final detail = container.read(catDetailProvider(_catId)).detail!;
    // The question the user just answered moves...
    expect(detail.lastFedAt, fed.createdAt);
    // ...and the two they did not are untouched, rather than reset to
    // "henüz yok" as the hand-built rebuild used to leave them.
    expect(detail.lastSeenAt, _detail.lastSeenAt);
    expect(detail.lastWaterAt, _detail.lastWaterAt);
    // Dropping this stripped "engelle" from the cat's own menu for the
    // rest of the session.
    expect(detail.ownerUserId, 'owner-1');
    expect(detail.areaLabel, _detail.areaLabel);
    expect(detail.primaryPhoto, _detail.primaryPhoto);
  });

  test(
    'prependUpdate advances every status a combined entry carries',
    () async {
      final container = _containerWith(
        _FakeCatDetailApi(
          detail: _detail,
          updatesPages: const [UpdatesPage(items: [], nextCursor: null)],
        ),
      );
      addTearDown(container.dispose);

      final notifier = container.read(catDetailProvider(_catId).notifier);
      await notifier.load();

      final combined = _update(
        'u2',
        statuses: const ['seen', 'water_provided'],
        createdAt: DateTime.utc(2026, 1, 3),
      );
      notifier.prependUpdate(combined);

      final detail = container.read(catDetailProvider(_catId)).detail!;
      expect(detail.lastSeenAt, combined.createdAt);
      expect(detail.lastWaterAt, combined.createdAt);
      expect(detail.lastFedAt, _detail.lastFedAt);
    },
  );

  test('prependUpdate never moves a stat timestamp backwards', () async {
    final container = _containerWith(
      _FakeCatDetailApi(
        detail: _detail,
        updatesPages: const [UpdatesPage(items: [], nextCursor: null)],
      ),
    );
    addTearDown(container.dispose);

    final notifier = container.read(catDetailProvider(_catId).notifier);
    await notifier.load();

    // An older entry arriving late answers "when was this cat last seen"
    // with a worse answer than the one already held.
    notifier.prependUpdate(
      _update(
        'u2',
        statuses: const ['seen'],
        createdAt: DateTime.utc(2025, 12, 31),
      ),
    );

    final detail = container.read(catDetailProvider(_catId)).detail!;
    expect(detail.lastSeenAt, _detail.lastSeenAt);
  });
}
