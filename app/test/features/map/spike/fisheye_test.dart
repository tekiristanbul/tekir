import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:app/features/map/spike/fisheye.dart';

/// Issue #280, concept 1. The claim under test is not "it looks good" — it
/// is that the arrangement stays a magnification of the map rather than an
/// invented layout: every cat readable, nobody reordered, and the same
/// group separating the same way every time.
void main() {
  // The seeded Galata group (backend/cmd/seed/main.go): seven cats inside
  // about forty metres, which at street zoom land within a pin's width of
  // each other. This is the case the concept exists for.
  List<({String id, Offset point})> galata() => [
    (id: 'a', point: const Offset(200, 400)),
    (id: 'b', point: const Offset(203, 397)),
    (id: 'c', point: const Offset(198, 404)),
    (id: 'd', point: const Offset(206, 394)),
    (id: 'e', point: const Offset(195, 407)),
    (id: 'f', point: const Offset(209, 391)),
    (id: 'g', point: const Offset(192, 410)),
  ];

  double minimumPairDistance(List<FisheyeSeat> seats) {
    var smallest = double.infinity;
    for (var i = 0; i < seats.length; i++) {
      for (var j = i + 1; j < seats.length; j++) {
        final distance = (seats[i].seat - seats[j].seat).distance;
        if (distance < smallest) smallest = distance;
      }
    }
    return smallest;
  }

  test('separates a coincident group to at least one pin width apart', () {
    final seats = fisheyeSeats(focus: const Offset(200, 400), cats: galata());

    expect(seats, hasLength(7));
    expect(
      minimumPairDistance(seats),
      greaterThanOrEqualTo(fisheyeMinSpacing - 0.5),
    );
  });

  test('keeps every cat within reach of the focus it was opened from', () {
    final seats = fisheyeSeats(focus: const Offset(200, 400), cats: galata());

    for (final seat in seats) {
      // Nothing is thrown across the screen: the group has to stay
      // readable as one group, and reachable without moving the hand.
      expect((seat.seat - const Offset(200, 400)).distance, lessThan(200));
    }
  });

  test('preserves each cat\'s bearing order around the focus', () {
    const focus = Offset(200, 400);
    // A spread-out ring, where every cat already has an unambiguous
    // bearing — the property that must survive magnification.
    final cats = <({String id, Offset point})>[
      for (var i = 0; i < 6; i++)
        (
          id: 'cat$i',
          point:
              focus +
              Offset(math.cos(i * math.pi / 3), math.sin(i * math.pi / 3)) * 30,
        ),
    ];

    final seats = fisheyeSeats(focus: focus, cats: cats);
    final byId = {for (final seat in seats) seat.id: seat};

    for (final seat in seats) {
      final before = seat.origin - focus;
      final after = byId[seat.id]!.seat - focus;
      final turned =
          (math.atan2(after.dy, after.dx) - math.atan2(before.dy, before.dx))
              .abs();
      // A cat may be nudged around the focus to make room; it may not end
      // up on the other side of it.
      expect(turned, lessThan(math.pi / 4));
    }
  });

  test('is independent of the order the cats arrive in', () {
    const focus = Offset(200, 400);
    final forwards = fisheyeSeats(focus: focus, cats: galata());
    final backwards = fisheyeSeats(
      focus: focus,
      cats: galata().reversed.toList(),
    );

    final byId = {for (final seat in backwards) seat.id: seat.seat};
    for (final seat in forwards) {
      expect((byId[seat.id]! - seat.seat).distance, lessThan(0.001));
    }
  });

  test('leaves a cat that is already clear of its neighbours alone', () {
    const focus = Offset(200, 400);
    final seats = fisheyeSeats(
      focus: focus,
      cats: [
        (id: 'near', point: const Offset(201, 401)),
        (id: 'other', point: const Offset(204, 398)),
        // Far outside the falloff radius: the magnification there has
        // decayed to almost nothing, so this cat must stay where it is.
        (id: 'far', point: const Offset(200, 780)),
      ],
    );

    final far = seats.firstWhere((seat) => seat.id == 'far');
    expect(far.displacement, lessThan(12));
  });

  test('a focus with one cat under it is not an arrangement', () {
    final seats = fisheyeSeats(
      focus: const Offset(10, 10),
      cats: [(id: 'only', point: const Offset(12, 12))],
    );

    expect(seats.single.seat, const Offset(12, 12));
    expect(seats.single.displacement, 0);
  });
}
