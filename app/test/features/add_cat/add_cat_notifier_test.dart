import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:app/features/add_cat/data/add_cat_api.dart';
import 'package:app/features/add_cat/ui/add_cat_state.dart';
import 'package:app/features/cat_detail/data/cat_detail.dart';
import 'package:app/features/map/data/location_service.dart';

class _FakeAddCatApi implements AddCatApi {
  List<DuplicateCandidate> nearbyResult = const [];
  Object? nearbyError;
  Object? createError;
  CatDetail? createResult;

  int fetchNearbyCalls = 0;
  int createCalls = 0;
  String? lastIdempotencyKey;
  bool? lastConfirmedNew;

  @override
  Future<List<DuplicateCandidate>> fetchNearby({
    required double lat,
    required double lng,
  }) async {
    fetchNearbyCalls++;
    if (nearbyError != null) throw nearbyError!;
    return nearbyResult;
  }

  @override
  Future<CatDetail> createCat({
    required double lat,
    required double lng,
    String? name,
    required bool confirmedNew,
    required Uint8List photoBytes,
    required String photoFilename,
    required String idempotencyKey,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    createCalls++;
    lastIdempotencyKey = idempotencyKey;
    lastConfirmedNew = confirmedNew;
    if (createError != null) throw createError!;
    return createResult!;
  }
}

/// A deterministic ImagePickerPlatform stand-in — the officially supported
/// seam for testing code that calls `ImagePicker()` (see
/// image_picker_platform_interface's `ImagePickerPlatform.instance`).
class _FakeImagePickerPlatform extends ImagePickerPlatform {
  XFile? nextFile;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async => nextFile;
}

const _resolvedCenter = ResolvedLocation(
  center: LatLng(41.03, 28.98),
  isFallback: false,
);

ProviderContainer _containerWith({
  required _FakeAddCatApi api,
  ResolvedLocation resolvedLocation = _resolvedCenter,
}) {
  final container = ProviderContainer(
    overrides: [
      addCatApiProvider.overrideWithValue(api),
      locationServiceProvider.overrideWith(
        (ref) => _FakeLocationService(resolvedLocation),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

class _FakeLocationService implements LocationService {
  _FakeLocationService(this._resolved);
  final ResolvedLocation _resolved;

  @override
  Future<ResolvedLocation> resolveInitialCenter() async => _resolved;
}

void main() {
  final fakePlatform = _FakeImagePickerPlatform();
  ImagePickerPlatform.instance = fakePlatform;

  group('location', () {
    test('start() resolves the device location into state', () async {
      final container = _containerWith(api: _FakeAddCatApi());
      container.read(addCatProvider.notifier).start();
      await Future<void>.delayed(Duration.zero);

      final state = container.read(addCatProvider);
      expect(state.lat, 41.03);
      expect(state.lng, 28.98);
      expect(state.geoError, isNull);
    });

    test(
      'confirmLocation with no nearby cats advances straight to details',
      () async {
        final api = _FakeAddCatApi();
        final container = _containerWith(api: api);
        container.read(addCatProvider.notifier).start();
        await Future<void>.delayed(Duration.zero);

        await container.read(addCatProvider.notifier).confirmLocation();

        final state = container.read(addCatProvider);
        expect(state.step, AddCatStep.details);
        expect(state.duplicates, isEmpty);
      },
    );

    test(
      'confirmLocation with nearby cats shows candidates and stays on location',
      () async {
        final api = _FakeAddCatApi()
          ..nearbyResult = const [
            DuplicateCandidate(id: 'cat-1', name: 'tekir', primaryPhoto: ''),
          ];
        final container = _containerWith(api: api);
        container.read(addCatProvider.notifier).start();
        await Future<void>.delayed(Duration.zero);

        await container.read(addCatProvider.notifier).confirmLocation();

        final state = container.read(addCatProvider);
        expect(state.step, AddCatStep.location);
        expect(state.hasDuplicates, isTrue);
        expect(state.duplicates.single.id, 'cat-1');
      },
    );

    test(
      'a failed duplicate check is advisory only — still advances to details',
      () async {
        final api = _FakeAddCatApi()
          ..nearbyError = const AddCatNetworkException();
        final container = _containerWith(api: api);
        container.read(addCatProvider.notifier).start();
        await Future<void>.delayed(Duration.zero);

        await container.read(addCatProvider.notifier).confirmLocation();

        expect(container.read(addCatProvider).step, AddCatStep.details);
      },
    );

    test(
      'continueAsDifferent clears candidates, sets confirmedNew, advances to details',
      () async {
        final api = _FakeAddCatApi()
          ..nearbyResult = const [
            DuplicateCandidate(id: 'cat-1', name: 'tekir', primaryPhoto: ''),
          ];
        final container = _containerWith(api: api);
        container.read(addCatProvider.notifier).start();
        await Future<void>.delayed(Duration.zero);
        await container.read(addCatProvider.notifier).confirmLocation();
        expect(container.read(addCatProvider).hasDuplicates, isTrue);

        container.read(addCatProvider.notifier).continueAsDifferent();

        final state = container.read(addCatProvider);
        expect(state.step, AddCatStep.details);
        expect(state.duplicates, isEmpty);
        expect(state.confirmedNew, isTrue);
      },
    );
  });

  group('save', () {
    test(
      'without a photo sets AddCatError.missingPhoto and returns null',
      () async {
        final container = _containerWith(api: _FakeAddCatApi());
        container.read(addCatProvider.notifier).start();
        await Future<void>.delayed(Duration.zero);

        final result = await container.read(addCatProvider.notifier).save();

        expect(result, isNull);
        expect(container.read(addCatProvider).error, AddCatError.missingPhoto);
      },
    );

    test(
      'a successful save returns the created cat id and resets confirmedNew flag through the api call',
      () async {
        final api = _FakeAddCatApi()
          ..createResult = CatDetail(
            id: 'new-cat-id',
            name: 'Boncuk',
            lat: 41.03,
            lng: 28.98,
            areaLabel: null,
            primaryPhoto: '/v1/media/objects/x.jpg',
            createdAt: DateTime.utc(2026, 1, 1),
            lastUpdateAt: null,
          );
        final container = _containerWith(api: api);
        container.read(addCatProvider.notifier).start();
        await Future<void>.delayed(Duration.zero);

        fakePlatform.nextFile = XFile.fromData(
          Uint8List.fromList([1, 2, 3]),
          name: 'photo.jpg',
          path: 'photo.jpg',
        );
        await container
            .read(addCatProvider.notifier)
            .pickPhoto(ImageSource.gallery);

        final result = await container.read(addCatProvider.notifier).save();

        expect(result, 'new-cat-id');
        expect(api.createCalls, 1);
        expect(api.lastConfirmedNew, false);
        // Regression: `saving` must not stay stuck true on the success
        // path — nothing left to preserve once creation succeeds, so the
        // whole state resets (mirrors AuthNotifier.verifyCode's success
        // path).
        expect(container.read(addCatProvider).saving, isFalse);
        expect(container.read(addCatProvider).step, AddCatStep.location);
      },
    );

    test(
      'a content-rejected save (422) maps to AddCatError.contentRejected and '
      'keeps the picked photo and typed name',
      () async {
        final api = _FakeAddCatApi()
          ..createError = const AddCatContentRejectedException();
        final container = _containerWith(api: api);
        container.read(addCatProvider.notifier).start();
        await Future<void>.delayed(Duration.zero);
        container.read(addCatProvider.notifier).setName('Boncuk');
        fakePlatform.nextFile = XFile.fromData(
          Uint8List.fromList([1]),
          name: 'photo.jpg',
          path: 'photo.jpg',
        );
        await container
            .read(addCatProvider.notifier)
            .pickPhoto(ImageSource.gallery);

        final result = await container.read(addCatProvider.notifier).save();

        expect(result, isNull);
        final state = container.read(addCatProvider);
        expect(state.error, AddCatError.contentRejected);
        // issue #241: a rejection is a stable, recoverable validation
        // error — the photo and name stay exactly as entered.
        expect(state.photoBytes, isNotNull);
        expect(state.name, 'Boncuk');
        expect(state.saving, isFalse);
      },
    );

    test(
      'a stale session (401) maps to AddCatError.unauthorized, not a generic server error',
      () async {
        final api = _FakeAddCatApi()
          ..createError = const AddCatUnauthorizedException();
        final container = _containerWith(api: api);
        container.read(addCatProvider.notifier).start();
        await Future<void>.delayed(Duration.zero);
        fakePlatform.nextFile = XFile.fromData(
          Uint8List.fromList([1]),
          name: 'photo.jpg',
          path: 'photo.jpg',
        );
        await container
            .read(addCatProvider.notifier)
            .pickPhoto(ImageSource.gallery);

        final result = await container.read(addCatProvider.notifier).save();

        expect(result, isNull);
        expect(container.read(addCatProvider).error, AddCatError.unauthorized);
      },
    );

    test(
      'confirmedNew is threaded through to the create call after continueAsDifferent',
      () async {
        final api = _FakeAddCatApi()
          ..nearbyResult = const [
            DuplicateCandidate(id: 'cat-1', name: 'tekir', primaryPhoto: ''),
          ]
          ..createResult = CatDetail(
            id: 'new-cat-id',
            name: '',
            lat: 41.03,
            lng: 28.98,
            areaLabel: null,
            primaryPhoto: null,
            createdAt: DateTime.utc(2026, 1, 1),
            lastUpdateAt: null,
          );
        final container = _containerWith(api: api);
        container.read(addCatProvider.notifier).start();
        await Future<void>.delayed(Duration.zero);
        await container.read(addCatProvider.notifier).confirmLocation();
        container.read(addCatProvider.notifier).continueAsDifferent();

        fakePlatform.nextFile = XFile.fromData(
          Uint8List.fromList([1]),
          name: 'photo.jpg',
          path: 'photo.jpg',
        );
        await container
            .read(addCatProvider.notifier)
            .pickPhoto(ImageSource.gallery);
        await container.read(addCatProvider.notifier).save();

        expect(api.lastConfirmedNew, isTrue);
      },
    );

    test(
      'a retry after a network failure reuses the same idempotency key',
      () async {
        final api = _FakeAddCatApi()
          ..createError = const AddCatNetworkException();
        final container = _containerWith(api: api);
        container.read(addCatProvider.notifier).start();
        await Future<void>.delayed(Duration.zero);
        fakePlatform.nextFile = XFile.fromData(
          Uint8List.fromList([1]),
          name: 'photo.jpg',
          path: 'photo.jpg',
        );
        await container
            .read(addCatProvider.notifier)
            .pickPhoto(ImageSource.gallery);

        await container.read(addCatProvider.notifier).save();
        expect(container.read(addCatProvider).error, AddCatError.network);
        final firstKey = api.lastIdempotencyKey;

        api.createError = null;
        api.createResult = CatDetail(
          id: 'new-cat-id',
          name: '',
          lat: 41.03,
          lng: 28.98,
          areaLabel: null,
          primaryPhoto: null,
          createdAt: DateTime.utc(2026, 1, 1),
          lastUpdateAt: null,
        );
        final result = await container.read(addCatProvider.notifier).save();

        expect(result, 'new-cat-id');
        expect(api.lastIdempotencyKey, firstKey);
        expect(api.createCalls, 2);
      },
    );

    test(
      'a duplicate-candidates race during save shows the candidates again without losing entered details',
      () async {
        final api = _FakeAddCatApi()
          ..createError = const AddCatDuplicateCandidatesException([
            DuplicateCandidate(
              id: 'cat-2',
              name: 'raced cat',
              primaryPhoto: '',
            ),
          ]);
        final container = _containerWith(api: api);
        container.read(addCatProvider.notifier).start();
        await Future<void>.delayed(Duration.zero);
        await container.read(addCatProvider.notifier).confirmLocation();
        container.read(addCatProvider.notifier).setName('Boncuk');
        fakePlatform.nextFile = XFile.fromData(
          Uint8List.fromList([1]),
          name: 'photo.jpg',
          path: 'photo.jpg',
        );
        await container
            .read(addCatProvider.notifier)
            .pickPhoto(ImageSource.gallery);

        final result = await container.read(addCatProvider.notifier).save();

        expect(result, isNull);
        final state = container.read(addCatProvider);
        expect(state.step, AddCatStep.location);
        expect(state.duplicates.single.id, 'cat-2');
        expect(state.name, 'Boncuk');
        expect(state.photoBytes, isNotNull);
      },
    );

    test('start() resets state and generates a new attempt', () async {
      final api = _FakeAddCatApi();
      final container = _containerWith(api: api);
      container.read(addCatProvider.notifier).start();
      await Future<void>.delayed(Duration.zero);
      container.read(addCatProvider.notifier).setName('leftover');

      container.read(addCatProvider.notifier).start();
      await Future<void>.delayed(Duration.zero);

      expect(container.read(addCatProvider).name, '');
      expect(container.read(addCatProvider).step, AddCatStep.location);
    });
  });
}
