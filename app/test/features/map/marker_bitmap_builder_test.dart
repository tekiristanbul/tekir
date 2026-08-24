import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/map/data/marker_bitmap_builder.dart';
import 'package:app/features/map/data/marker_tier.dart';

/// Records every url it is asked for and always fails, so a test can assert
/// what was requested without a network of any kind.
class _RecordingDio implements Dio {
  final requested = <String>[];

  @override
  Future<Response<T>> get<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) async {
    requested.add(path);
    throw DioException(requestOptions: RequestOptions(path: path));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('resting help mark (issue #285)', _restingHelpMarkTests);

  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingDio dio;
  late MarkerBitmapBuilder builder;

  setUp(() {
    dio = _RecordingDio();
    builder = MarkerBitmapBuilder(photoClient: dio);
  });

  test('a dot never asks for the cat photo', () async {
    await builder.pin(
      cacheKey: 'cat-1',
      photoUrl: 'https://example.test/cat-1.jpg',
      needsHelp: false,
      tier: MarkerTier.dot,
    );

    expect(dio.requested, isEmpty);
  });

  test('a silhouette never asks for the cat photo either', () async {
    await builder.pin(
      cacheKey: 'cat-1',
      photoUrl: 'https://example.test/cat-1.jpg',
      needsHelp: false,
      tier: MarkerTier.silhouette,
    );

    expect(dio.requested, isEmpty);
  });

  test('an avatar does ask for it', () async {
    await builder.pin(
      cacheKey: 'cat-1',
      photoUrl: 'https://example.test/cat-1.jpg',
      needsHelp: false,
      tier: MarkerTier.avatar,
    );

    expect(dio.requested, ['https://example.test/cat-1.jpg']);
  });

  test('every cat shares one dot and one silhouette bitmap', () async {
    final first = await builder.pin(
      cacheKey: 'cat-1',
      photoUrl: '',
      needsHelp: false,
      tier: MarkerTier.dot,
    );
    final second = await builder.pin(
      cacheKey: 'cat-2',
      photoUrl: '',
      needsHelp: false,
      tier: MarkerTier.dot,
    );
    final silhouette = await builder.pin(
      cacheKey: 'cat-3',
      photoUrl: '',
      needsHelp: false,
      tier: MarkerTier.silhouette,
    );
    final otherSilhouette = await builder.pin(
      cacheKey: 'cat-4',
      photoUrl: '',
      needsHelp: false,
      tier: MarkerTier.silhouette,
    );

    expect(identical(first, second), isTrue);
    expect(identical(silhouette, otherSilhouette), isTrue);
    expect(identical(first, silhouette), isFalse);
  });

  test('a cat needing help gets its own variant at every tier', () async {
    for (final tier in MarkerTier.values) {
      final plain = await builder.pin(
        cacheKey: 'cat-1',
        photoUrl: '',
        needsHelp: false,
        tier: tier,
      );
      final helped = await builder.pin(
        cacheKey: 'cat-1',
        photoUrl: '',
        needsHelp: true,
        tier: tier,
      );
      expect(identical(plain, helped), isFalse, reason: '$tier');
    }
  });

  test('a cluster bubble is cached per count and help state', () async {
    final four = await builder.cluster(count: 4, containsHelp: false);
    final fourAgain = await builder.cluster(count: 4, containsHelp: false);
    final fourWithHelp = await builder.cluster(count: 4, containsHelp: true);
    final five = await builder.cluster(count: 5, containsHelp: false);

    expect(identical(four, fourAgain), isTrue);
    expect(identical(four, fourWithHelp), isFalse);
    expect(identical(four, five), isFalse);
  });

  test('every tier is drawn on a canvas that meets the tap minimum', () async {
    for (final tier in MarkerTier.values) {
      final bitmap =
          await builder.pin(
                cacheKey: 'cat-1',
                photoUrl: '',
                needsHelp: false,
                tier: tier,
              )
              as BytesMapBitmap;
      // A marker's tap target is its image. The 10pt dot is drawn inside a
      // transparent 44pt canvas for exactly this reason.
      expect(
        bitmap.width,
        greaterThanOrEqualTo(kTapMin),
        reason: '$tier is smaller than the tap minimum',
      );
    }
  });

  test('a cluster bubble is big enough to hit', () async {
    final bitmap =
        await builder.cluster(count: 3, containsHelp: false) as BytesMapBitmap;

    expect(bitmap.width, greaterThanOrEqualTo(kTapMin));
  });

  group('hasPhoto', () {
    test('a cat with no photo is never waiting for one', () {
      expect(builder.hasPhoto(''), isTrue);
    });

    test('an unfetched url has not settled', () {
      expect(builder.hasPhoto('https://example.test/cat-1.jpg'), isFalse);
    });

    test('a url that failed never settles, so the silhouette stays', () async {
      final settled = await builder.warmPhoto('https://example.test/cat-1.jpg');

      expect(settled, isFalse);
      expect(builder.hasPhoto('https://example.test/cat-1.jpg'), isFalse);
    });
  });
}

// The resting help mark — the ring and the badge painted into the pin —
// gives way to the halo layer's pulse, but only where that pulse is
// actually drawn: the avatar tier, with motion allowed. Everywhere else it
// is the whole of the mark and must stay.
void _restingHelpMarkTests() {
  test('a pulsing cat is drawn as if it did not need help', () async {
    final dio = _RecordingDio();
    final builder = MarkerBitmapBuilder(photoClient: dio);

    final plain = await builder.pin(
      cacheKey: 'cat-1',
      photoUrl: '',
      needsHelp: false,
      tier: MarkerTier.avatar,
    );
    final pulsing = await builder.pin(
      cacheKey: 'cat-1',
      photoUrl: '',
      needsHelp: true,
      tier: MarkerTier.avatar,
      restingHelpMark: false,
    );

    // Same pixels: the pin says nothing about help, because the pulse
    // does. (Not the same object — the cache keys differ, which is what
    // keeps both renderings available at once.)
    expect(
      (pulsing as BytesMapBitmap).byteData,
      (plain as BytesMapBitmap).byteData,
    );
  });

  test('a cat with no pulse keeps its ring and badge', () async {
    final dio = _RecordingDio();
    final builder = MarkerBitmapBuilder(photoClient: dio);

    final plain = await builder.pin(
      cacheKey: 'cat-1',
      photoUrl: '',
      needsHelp: false,
      tier: MarkerTier.avatar,
    );
    final marked = await builder.pin(
      cacheKey: 'cat-1',
      photoUrl: '',
      needsHelp: true,
      tier: MarkerTier.avatar,
    );

    expect(
      (marked as BytesMapBitmap).byteData,
      isNot((plain as BytesMapBitmap).byteData),
    );
  });

  test('a silhouette and a dot always keep the mark', () async {
    final dio = _RecordingDio();
    final builder = MarkerBitmapBuilder(photoClient: dio);

    for (final tier in [MarkerTier.silhouette, MarkerTier.dot]) {
      final plain = await builder.pin(
        cacheKey: 'cat-1',
        photoUrl: '',
        needsHelp: false,
        tier: tier,
      );
      // No pulse is ever drawn at these resolutions, so asking for the
      // resting mark to go must change nothing.
      final asked = await builder.pin(
        cacheKey: 'cat-1',
        photoUrl: '',
        needsHelp: true,
        tier: tier,
        restingHelpMark: false,
      );
      expect(
        (asked as BytesMapBitmap).byteData,
        isNot((plain as BytesMapBitmap).byteData),
        reason: '$tier lost its mark',
      );
    }
  });
}
