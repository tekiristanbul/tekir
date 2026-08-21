import 'package:flutter_test/flutter_test.dart';
import 'package:app/features/map/spike/focus_lens.dart';

/// Issue #280, concept 1. The claims under test are the ones that decide
/// whether this reads as glass lying on a map: the map outside the rim is
/// untouched, the magnification has an edge rather than a fade, no cat is
/// ever drawn away from its own coordinate, and the cat under the focus is
/// the one on top.
void main() {
  // Seven cats within about fourteen pixels of each other — the seeded
  // Galata group at street zoom, which is the case the concept exists for.
  List<({String id, Offset point})> galata(Offset at) => [
    for (var i = 0; i < 7; i++)
      (id: 'cat$i', point: at + Offset((i - 3) * 2.4, (3 - i) * 2.1)),
  ];

  test('a cat outside the glass is untouched, to the pixel', () {
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
  });

  test('no cat is ever drawn away from its own coordinate', () {
    // The rule that replaced the earlier de-crowding pass: the lens changes
    // size and nothing else, so the map never shows a cat where it is not.
    const focus = Offset(200, 400);
    final cats = galata(focus);
    for (final strength in [0.0, 0.3, 0.7, 1.0]) {
      final placements = lensPlacements(
        focus: focus,
        strength: strength,
        cats: cats,
      );
      final byId = {for (final cat in cats) cat.id: cat.point};
      for (final placement in placements) {
        expect(placement.position, byId[placement.id], reason: '$strength');
      }
    }
  });

  test('magnification is strongest at the focus and gone at the rim', () {
    const focus = Offset(200, 400);
    final placements = lensPlacements(
      focus: focus,
      strength: 1,
      cats: [
        (id: 'a', point: focus),
        (id: 'b', point: focus + const Offset(lensRadius * 0.5, 0)),
        (id: 'c', point: focus + const Offset(lensRadius * 0.99, 0)),
      ],
    );
    final byId = {for (final p in placements) p.id: p};

    expect(byId['a']!.scale, closeTo(lensMagnification, 0.001));
    expect(byId['b']!.scale, greaterThan(byId['c']!.scale));
    expect(byId['b']!.scale, lessThan(byId['a']!.scale));
  });

  test('the rim is an edge, not a fade', () {
    // The spherical-cap profile arrives at 1 vertically. Halfway out the
    // glass is still magnifying most of the way, and it collapses in the
    // last stretch — which is what makes the boundary a place on the map
    // rather than a gradual nothing.
    const focus = Offset(200, 400);
    double scaleAt(double fraction) => lensPlacements(
      focus: focus,
      strength: 1,
      cats: [(id: 'x', point: focus + Offset(lensRadius * fraction, 0))],
    ).single.scale;

    final lift = lensMagnification - 1;
    expect((scaleAt(0.5) - 1) / lift, greaterThan(0.8));
    expect((scaleAt(0.9) - 1) / lift, lessThan(0.5));
    expect(scaleAt(0.999), closeTo(1, 0.05));
  });

  test('strength 0 and no focus are both the untouched map', () {
    final cats = galata(const Offset(200, 400));
    for (final placements in [
      lensPlacements(focus: const Offset(200, 400), strength: 0, cats: cats),
      lensPlacements(focus: null, strength: 1, cats: cats),
    ]) {
      for (final placement in placements) {
        expect(placement.scale, 1);
      }
    }
  });

  test('the cat under the focus is the one drawn on top', () {
    // With nothing displaced, this is what opens a stack: sweeping the
    // glass brings each cat forward in turn.
    const focus = Offset(200, 400);
    final placements = lensPlacements(
      focus: focus,
      strength: 1,
      cats: galata(focus),
    );

    // cat3 sits exactly on the focus in this arrangement.
    expect(placements.last.id, 'cat3');
    expect(placements.last.scale, closeTo(lensMagnification, 0.001));
    // Ordered back to front all the way down.
    for (var i = 1; i < placements.length; i++) {
      expect(
        placements[i].distanceToFocus,
        lessThanOrEqualTo(placements[i - 1].distanceToFocus),
      );
    }
  });

  test('a pixel of focus movement is a bounded amount of size change', () {
    // A lens amplifies; what it must not do is jump. Scale-only
    // magnification makes that easy to state and cheap to keep true.
    final cats = galata(const Offset(200, 400));
    for (var step = 0; step < 60; step++) {
      final before = lensPlacements(
        focus: Offset(140 + step.toDouble(), 400),
        strength: 1,
        cats: cats,
      );
      final after = lensPlacements(
        focus: Offset(141 + step.toDouble(), 400),
        strength: 1,
        cats: cats,
      );
      final byId = {for (final p in after) p.id: p};
      for (final placement in before) {
        expect(
          (byId[placement.id]!.scale - placement.scale).abs(),
          lessThan(0.1),
          reason: 'step $step, ${placement.id}',
        );
      }
    }
  });

  test('is independent of the order the cats arrive in', () {
    const focus = Offset(200, 400);
    final forwards = lensPlacements(
      focus: focus,
      strength: 1,
      cats: galata(focus),
    );
    final backwards = lensPlacements(
      focus: focus,
      strength: 1,
      cats: galata(focus).reversed.toList(),
    );

    expect(
      forwards.map((p) => p.id).toList(),
      backwards.map((p) => p.id).toList(),
    );
  });
}
