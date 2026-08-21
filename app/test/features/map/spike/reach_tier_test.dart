import 'package:flutter_test/flutter_test.dart';
import 'package:app/features/map/spike/reach_tier.dart';

/// Issue #280, concept 2. The tier rule is the whole concept, so it is
/// tested as a rule rather than through a rendered pin.
void main() {
  test('city zoom shows where the cats are, not who they are', () {
    expect(
      reachTierFor(zoom: 12, metersFromUser: 50, needsHelp: false),
      ReachTier.trace,
    );
  });

  test('neighbourhood zoom shows presence', () {
    expect(
      reachTierFor(zoom: 14.5, metersFromUser: 50, needsHelp: false),
      ReachTier.presence,
    );
  });

  test('street zoom gives a face to a cat within walking distance', () {
    expect(
      reachTierFor(zoom: 17, metersFromUser: 120, needsHelp: false),
      ReachTier.identity,
    );
  });

  test('street zoom holds back a cat that is out of reach', () {
    expect(
      reachTierFor(
        zoom: 17,
        metersFromUser: reachWalkableMeters + 1,
        needsHelp: false,
      ),
      ReachTier.presence,
    );
  });

  test('an unknown user position lets zoom decide alone', () {
    // The fallback centre is a hard-coded point, not a location; treating
    // it as one would put every cat in Istanbul "in reach" of Galata.
    expect(
      reachTierFor(zoom: 17, metersFromUser: null, needsHelp: false),
      ReachTier.identity,
    );
  });

  test('a cat that needs help is never reduced to a dot', () {
    for (final zoom in [11.0, 13.0, 14.0, 17.0]) {
      expect(
        reachTierFor(zoom: zoom, metersFromUser: 5000, needsHelp: true),
        isNot(ReachTier.trace),
        reason: 'zoom $zoom',
      );
    }
  });

  test('a cat that needs help keeps its face at any reachable zoom', () {
    // Distance does not de-emphasise an alert: someone who is not nearby
    // still has to be able to see it and decide to go.
    expect(
      reachTierFor(zoom: 14, metersFromUser: 9000, needsHelp: true),
      ReachTier.identity,
    );
  });
}
