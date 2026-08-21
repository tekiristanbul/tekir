/// Issue #280's interaction spike, and the single switch that keeps it out
/// of the shipped app.
///
/// Everything the spike adds lives under `features/map/spike/`. The map
/// screen reaches into it from four guarded points, each of which reads
/// [mapSpikeEnabled] first; with the flag off — the default, and the only
/// state a release build can be in unless someone passes the define — the
/// spike code is unreachable and tree-shaken, no route is registered, no
/// widget is inserted, and the map behaves exactly as it does on `main`.
///
/// Removing the experiment means deleting this directory and the four
/// `if (mapSpikeEnabled)` blocks that reference it. Nothing else in the app
/// imports it.
///
/// Turn it on for a session with:
///
///     flutter run --dart-define=MAP_SPIKE=fan      # concept 1
///     flutter run --dart-define=MAP_SPIKE=reach    # concept 2
///     flutter run --dart-define=MAP_SPIKE=carry    # concept 3
///
/// The value only chooses which concept is armed *first*; with the flag on
/// at all, an on-map switcher lets a reviewer move between the three (and
/// back to the shipped behaviour) without a rebuild, which is the whole
/// point of a comparison spike.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The three concepts under evaluation, plus [off] — the shipped map,
/// unchanged, which is the baseline every concept is compared against.
enum MapSpikeConcept {
  /// Shipped behaviour: native cluster bubbles, cluster tap zooms in.
  off('kapalı'),

  /// Concept 1 — proximity fisheye. Focus separates the cats around it
  /// along their own bearings instead of hiding them behind a count.
  fan('odak'),

  /// Concept 2 — reach tiers. A pin's resolution follows zoom and the
  /// user's own distance from it.
  reach('erişim'),

  /// Concept 3 — cat carry. The pin is the object that becomes the
  /// preview and then the detail.
  carry('süreklilik');

  const MapSpikeConcept(this.label);

  /// Turkish label for the on-map switcher. Developer chrome, but the app
  /// has no second language and a mixed-language control reads worse than
  /// a translated one even in an experiment.
  final String label;
}

const _define = String.fromEnvironment('MAP_SPIKE');

/// True only when the build was given `--dart-define=MAP_SPIKE=...`.
/// Const, so a release build without the define drops every branch behind
/// it.
const mapSpikeEnabled = _define != '';

/// The concept the build starts on. Unrecognised values arm nothing rather
/// than guessing, so a typo in the define is visible immediately.
MapSpikeConcept get initialSpikeConcept => switch (_define) {
  'fan' => MapSpikeConcept.fan,
  'reach' => MapSpikeConcept.reach,
  'carry' => MapSpikeConcept.carry,
  _ => MapSpikeConcept.off,
};

class MapSpikeNotifier extends Notifier<MapSpikeConcept> {
  @override
  MapSpikeConcept build() =>
      mapSpikeEnabled ? initialSpikeConcept : MapSpikeConcept.off;

  void select(MapSpikeConcept concept) {
    // The guard matters: with the flag off this provider can still be read
    // (the map watches it unconditionally to keep the read out of a
    // conditional), and nothing must be able to arm a concept.
    state = mapSpikeEnabled ? concept : MapSpikeConcept.off;
  }
}

final mapSpikeProvider = NotifierProvider<MapSpikeNotifier, MapSpikeConcept>(
  MapSpikeNotifier.new,
);
