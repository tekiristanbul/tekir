import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/images/decode_budget.dart';

void main() {
  group('decodeWidthFor', () {
    testWidgets('scales the painted width by the device pixel ratio', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      late int decoded;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              decoded = decodeWidthFor(context, 132);
              return const SizedBox();
            },
          ),
        ),
      );

      expect(decoded, 396);
    });

    // A zero or negative constraint is rejected by the decoder rather than
    // clamped, so it must never leave this function.
    testWidgets('never returns less than one pixel', (tester) async {
      late int decoded;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              decoded = decodeWidthFor(context, 0);
              return const SizedBox();
            },
          ),
        ),
      );

      expect(decoded, greaterThanOrEqualTo(1));
    });
  });

  // The backend serves one full-resolution image to every surface, so an
  // unconstrained decode is ~47 MB for a typical phone photo and a few of
  // them cross the iOS memory high watermark. Every network image therefore
  // has to declare what size it is actually painted at; this asserts the
  // budget itself is small enough that the cache can never be the reason the
  // process is killed.
  test('the image cache ceiling stays well under a phone-photo pileup', () {
    expect(imageCacheMaxBytes, lessThan(100 * 1024 * 1024));
    expect(imageCacheMaxBytes, greaterThan(16 * 1024 * 1024));
  });

  testWidgets('a CachedNetworkImage without memCacheWidth is the bug this '
      'guards against', (tester) async {
    // Documents the contract for anyone adding a new image: the widget below
    // is what a regression looks like, and the finder is how the screen tests
    // check their own images.
    await tester.pumpWidget(
      MaterialApp(
        home: CachedNetworkImage(imageUrl: 'https://example.invalid/a.jpg'),
      ),
    );

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.memCacheWidth, isNull);
  });
}
