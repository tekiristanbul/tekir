/// Concept 2's rule: how much of a cat a pin shows, given how much the
/// user can currently do about it.
///
/// The shipped map draws every cat at one size, 66 pt of photo, at every
/// zoom. Pulled back over Beyoğlu that is a wall of faces with no shape to
/// it; the map stops being a map and becomes a contact sheet. Pushed in on
/// one street it is right.
///
/// The tiers below are not a size ramp for its own sake. tekir is an app
/// for going outside and checking on a cat, so the thing worth resolving
/// is reach: the cats you could walk to in the next few minutes earn a
/// face, the ones further out earn a presence, and at city zoom every cat
/// is a mark showing where the city's cats are — which is the question
/// that zoom level is actually asking.
///
/// One override outranks all of it. A cat with an active needs-help mark
/// never falls to a dot, because the alert contract (docs/product/alerts.md)
/// makes it the one thing the map must not quietly de-emphasise.
enum ReachTier {
  /// Photo, full ring, 66 pt — the shipped pin, unchanged.
  identity,

  /// A smaller photo with a thin ring, 40 pt: still this cat, not yet a
  /// face you read at a glance.
  presence,

  /// A 14 pt dot. Position and count only.
  trace,
}

/// Below this zoom the map is showing districts, not streets.
const double reachTraceZoom = 13.5;

/// Below this zoom the map is showing a neighbourhood: enough for presence,
/// not enough for a screenful of faces.
const double reachPresenceZoom = 15.5;

/// A cat further than this from the user is out of reach for now, even at
/// street zoom. Roughly ten minutes' walk.
const double reachWalkableMeters = 800;

/// The tier [ReachTier] a pin should draw at.
///
/// [metersFromUser] is null when the user's own position is unknown — the
/// fallback-centre case the map already supports, where nothing is out of
/// reach because nothing has a distance yet, so zoom alone decides.
ReachTier reachTierFor({
  required double zoom,
  required double? metersFromUser,
  required bool needsHelp,
}) {
  if (needsHelp) {
    // A cat that needs help is never a dot. Above district zoom it is
    // shown at full identity regardless of distance: the point of the mark
    // is that someone who is not nearby can still see it and decide to go.
    return zoom >= reachTraceZoom ? ReachTier.identity : ReachTier.presence;
  }
  if (zoom < reachTraceZoom) return ReachTier.trace;
  if (zoom < reachPresenceZoom) return ReachTier.presence;
  if (metersFromUser != null && metersFromUser > reachWalkableMeters) {
    return ReachTier.presence;
  }
  return ReachTier.identity;
}
