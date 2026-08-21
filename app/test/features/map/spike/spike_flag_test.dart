import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/map/spike/spike.dart';

/// Issue #280's containment rule: the experiment must not be able to reach
/// a build that did not ask for it. `flutter test` runs without the define,
/// so this file is testing the shipped configuration.
void main() {
  test('a build with no MAP_SPIKE define has no spike', () {
    expect(mapSpikeEnabled, isFalse);
    expect(initialSpikeConcept, MapSpikeConcept.off);
  });

  test('the concept cannot be armed while the flag is off', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(mapSpikeProvider.notifier).select(MapSpikeConcept.lens);

    // The map reads this provider unconditionally; without this guard a
    // stray write would arm an experiment in a production build.
    expect(container.read(mapSpikeProvider), MapSpikeConcept.off);
  });
}
