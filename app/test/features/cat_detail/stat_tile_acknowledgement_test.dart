import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/cat_detail/ui/cat_detail_screen.dart';

/// The three-stat header's raise animation is the app's clearest piece of
/// causality: the user answered "when was this cat last fed" and the tile
/// acknowledges it. These lock the one rule that keeps it honest — it may
/// only fire on an answer moving forward.
///
/// The rule exists because the opposite shipped: while
/// `CatDetailNotifier.prependUpdate` was dropping the three timestamps,
/// posting an update reset every tile to "henüz yok" and every tile lit up
/// in its status tint to celebrate the loss. The data bug has its own
/// regression tests in cat_detail_notifier_test.dart; these make sure the
/// animation can never dress up the next one.
void main() {
  final earlier = DateTime.utc(2026, 1, 1, 9);
  final later = DateTime.utc(2026, 1, 2, 9);

  test('a newer answer replacing an older one is acknowledged', () {
    expect(isAcknowledgeableStatTimeChange(earlier, later), isTrue);
  });

  test('the first answer arriving is acknowledged', () {
    expect(isAcknowledgeableStatTimeChange(null, later), isTrue);
  });

  test('an answer being lost is never acknowledged', () {
    expect(isAcknowledgeableStatTimeChange(later, null), isFalse);
  });

  test(
    'a tile that never had an answer does not acknowledge staying empty',
    () {
      expect(isAcknowledgeableStatTimeChange(null, null), isFalse);
    },
  );

  test('an answer moving backwards is never acknowledged', () {
    expect(isAcknowledgeableStatTimeChange(later, earlier), isFalse);
  });

  test('an unchanged answer is not re-acknowledged', () {
    expect(isAcknowledgeableStatTimeChange(later, later), isFalse);
    // A distinct instance of the same moment is the same answer — a
    // rebuild must not replay the animation.
    expect(
      isAcknowledgeableStatTimeChange(later, DateTime.utc(2026, 1, 2, 9)),
      isFalse,
    );
  });
}
