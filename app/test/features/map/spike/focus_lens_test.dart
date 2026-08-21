import 'package:flutter_test/flutter_test.dart';
import 'package:app/features/map/spike/focus_lens.dart';

/// Issue #280, concept 1. The claims under test are the ones that decide
/// whether this reads as a lens over a map or as icons growing: the map
/// outside the glass is untouched, the effect is continuous as the focus
/// moves, and a doorway's worth of stacked cats actually comes apart.
void main() {
  // Seven cats within about fourteen pixels of each other — the seeded
  // Galata group at street zoom, which is the case the concept exists for.
  List<({String id, Offset point})> galata(Offset at) => [
    for (var i = 0; i < 7; i++)
      (id: 'cat$i', point: at + Offset((i - 3) * 2.4, (3 - i) * 2.1)),
  ];

  double closestPair(List<LensPlacement> placements) {
    var smallest = double.infinity;
    for (var i = 0; i < placements.length; i++) {
      for (var j = i + 1; j < placements.length; j++) {
        final gap = (placements[i].position - placements[j].position).distance;
        if (gap < smallest) smallest = gap;
      }
    }
    return smallest;
  }

  test('a cat outside the lens is untouched, to the pixel', () {
    const focus = Offset(200, 400);
    final placements = lensPlacements(
      focus: focus,
      strength: 1,
      cats: [
        (id: 'near', point: const Offset(210, 400)),
        (id: 'far', point: Offset(200 + lensRadius + 1, 400)),
      ],
    );

    final far = placements.firstWhere((p) => p.id == 'far');
    expect(far.position, Offset(200 + lensRadius + 1, 400));
    expect(far.scale, 1);
    expect(far.displacement, 0);
  });

  test('magnification is strongest at the focus and gone at the edge', () {
    const focus = Offset(200, 400);
    final placements = lensPlacements(
      focus: focus,
      strength: 1,
      cats: [
        (id: 'a', point: const Offset(200, 400)),
        (id: 'b', point: Offset(200 + lensRadius * 0.5, 400)),
        (id: 'c', point: Offset(200 + lensRadius * 0.99, 400)),
      ],
    );
    final byId = {for (final p in placements) p.id: p};

    expect(byId['a']!.scale, greaterThan(byId['b']!.scale));
    expect(byId['b']!.scale, greaterThan(byId['c']!.scale));
    // Continuous at the boundary: a cat just inside is effectively the
    // same size as one just outside, so nothing pops as the lens sweeps
    // over it.
    expect(byId['c']!.scale, closeTo(1, 0.05));
  });

  test('strength 0 is the untouched map', () {
    final cats = galata(const Offset(200, 400));
    final placements = lensPlacements(
      focus: const Offset(200, 400),
      strength: 0,
      cats: cats,
    );

    for (final placement in placements) {
      expect(placement.position, placement.origin);
      expect(placement.scale, 1);
    }
  });

  test('no focus is the untouched map', () {
    final placements = lensPlacements(
      focus: null,
      strength: 1,
      cats: galata(const Offset(200, 400)),
    );

    for (final placement in placements) {
      expect(placement.displacement, 0);
      expect(placement.scale, 1);
    }
  });

  test('a pixel of focus movement is a bounded amount of pin movement', () {
    // A lens amplifies movement — that is what a lens is, and pins under
    // one are expected to travel further than the finger. What must not
    // happen is amplification compounding into a jump: the spread is
    // computed rather than solved for exactly this reason, and this is the
    // assertion that would catch a solver creeping back in.
    //
    // The ceiling is a small multiple of the magnification at the focus
    // itself, which is the most the transform can legitimately produce.
    const bound = (lensDistortion + 1) * 2;
    final cats = galata(const Offset(200, 400));
    for (var step = 0; step < 40; step++) {
      final before = lensPlacements(
        focus: Offset(160 + step.toDouble(), 400),
        strength: 1,
        cats: cats,
      );
      final after = lensPlacements(
        focus: Offset(161 + step.toDouble(), 400),
        strength: 1,
        cats: cats,
      );
      final byId = {for (final p in after) p.id: p};
      for (final placement in before) {
        final moved =
            (byId[placement.id]!.position - placement.position).distance;
        expect(moved, lessThan(bound), reason: 'step $step, ${placement.id}');
        expect(
          (byId[placement.id]!.scale - placement.scale).abs(),
          lessThan(0.2),
          reason: 'step $step, ${placement.id}',
        );
      }
    }
  });

  test('a stacked doorway comes apart under the focus', () {
    const focus = Offset(200, 400);
    final stacked = lensPlacements(
      focus: focus,
      strength: 1,
      cats: galata(focus),
    );

    // Before: neighbours about three pixels apart, so a 44 pt pin covers
    // its neighbour entirely and only the last one drawn is reachable.
    final resting = lensPlacements(
      focus: null,
      strength: 0,
      cats: galata(focus),
    );
    expect(closestPair(resting), lessThan(5));
    // After: each pair clears most of a pin's width, which is what makes
    // them separately readable and separately tappable.
    expect(closestPair(stacked), greaterThan(lensBasePin * 0.7));
  });

  test('cats sharing one coordinate exactly still get their own place', () {
    const focus = Offset(200, 400);
    final placements = lensPlacements(
      focus: focus,
      strength: 1,
      cats: [for (var i = 0; i < 4; i++) (id: 'cat$i', point: focus)],
    );

    expect(closestPair(placements), greaterThan(lensBasePin * 0.7));
    // Deterministic: the same stack resolves the same way every frame, so
    // it does not shuffle while the focus rests on it.
    final again = lensPlacements(
      focus: focus,
      strength: 1,
      cats: [for (var i = 3; i >= 0; i--) (id: 'cat$i', point: focus)],
    );
    final byId = {for (final p in again) p.id: p.position};
    for (final placement in placements) {
      expect(
        (byId[placement.id]! - placement.position).distance,
        lessThan(0.5),
      );
    }
  });

  test('a displaced cat is never moved further than the lens reaches', () {
    const focus = Offset(200, 400);
    final placements = lensPlacements(
      focus: focus,
      strength: 1,
      cats: galata(focus),
    );

    for (final placement in placements) {
      // The real position stays on screen next to the drawn one, which is
      // what the layer's leader lines rely on.
      expect(placement.displacement, lessThan(lensRadius));
    }
  });
}
