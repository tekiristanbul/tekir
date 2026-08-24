import 'dart:math' as math;

import 'cat_marker.dart';
import 'web_mercator.dart';

/// How much of a cat a marker shows at the current zoom (approved design,
/// `marker · LOD`).
///
/// One pin size at every zoom is what makes a city view an unreadable wall
/// of faces and a street view a pile of overlapping circles. Resolution is
/// chosen from the camera, not from the cat: at street zoom a cat is a face
/// you recognise, a few zoom steps out it is a presence, and across the
/// city it is a position.
enum MarkerTier {
  /// A recognisable face. The only tier that needs the cat's photo.
  avatar,

  /// A photoless silhouette: this is a cat, here, but you are too far out
  /// to tell which.
  silhouette,

  /// A position and nothing else. No photo is ever requested for a cat
  /// drawn like this.
  dot,
}

/// First zoom at which a cat is drawn as its own face.
const double avatarTierMinZoom = 17;

/// First zoom at which a cat is drawn at all beyond a bare position.
const double silhouetteTierMinZoom = 14;

/// How many avatar-resolution markers may be on screen at once.
///
/// Past this the map stops being a map and becomes a contact sheet — and
/// every avatar is a photo fetch and a rendered bitmap held per cat. The
/// overflow drops to [MarkerTier.silhouette] rather than disappearing: a
/// cat that is there must stay there.
const int maxAvatarMarkers = 12;

/// The tier [zoom] alone allows, before the on-screen avatar budget is
/// applied.
MarkerTier tierForZoom(double zoom) {
  if (zoom >= avatarTierMinZoom) return MarkerTier.avatar;
  if (zoom >= silhouetteTierMinZoom) return MarkerTier.silhouette;
  return MarkerTier.dot;
}

/// Resolves the tier for every cat in [cats], applying the avatar budget.
///
/// When more cats qualify for an avatar than [maxAvatarMarkers] allows, the
/// ones that keep it are chosen in a fixed order: a cat that needs help
/// first — the whole point of the face is recognising who is in trouble —
/// then whatever is closest to what the camera is looking at, with the
/// cat's own id breaking a tie so the same cat does not win one rebuild and
/// lose the next.
///
/// [selectedId], when it is one of [cats], always keeps its avatar
/// regardless of the budget: the map has just centred on that cat, and
/// answering a tap by making the cat less legible would be absurd.
Map<String, MarkerTier> resolveTiers({
  required List<CatMarker> cats,
  required double zoom,
  required double cameraLat,
  required double cameraLng,
  String? selectedId,
}) {
  final base = tierForZoom(zoom);
  if (base != MarkerTier.avatar) {
    return {
      for (final cat in cats)
        cat.id: cat.id == selectedId ? MarkerTier.avatar : base,
    };
  }
  if (cats.length <= maxAvatarMarkers) {
    return {for (final cat in cats) cat.id: MarkerTier.avatar};
  }

  final ranked = [...cats]
    ..sort((a, b) {
      final aSelected = a.id == selectedId;
      final bSelected = b.id == selectedId;
      if (aSelected != bSelected) return aSelected ? -1 : 1;
      if (a.needsHelp != b.needsHelp) return a.needsHelp ? -1 : 1;
      final byDistance = _squaredDegrees(
        a,
        cameraLat,
        cameraLng,
      ).compareTo(_squaredDegrees(b, cameraLat, cameraLng));
      if (byDistance != 0) return byDistance;
      return a.id.compareTo(b.id);
    });

  return {
    for (var i = 0; i < ranked.length; i++)
      ranked[i].id: i < maxAvatarMarkers
          ? MarkerTier.avatar
          : MarkerTier.silhouette,
  };
}

/// Squared distance in degrees — ordering only, so the square root and the
/// longitude correction would both change nothing about the result.
double _squaredDegrees(CatMarker cat, double lat, double lng) {
  final dLat = cat.lat - lat;
  final dLng = cat.lng - lng;
  return dLat * dLat + dLng * dLng;
}

/// A group of cats close enough together on screen to be drawn as one.
class CatCluster {
  const CatCluster({
    required this.id,
    required this.lat,
    required this.lng,
    required this.cats,
  });

  /// Stable across rebuilds for the same group, so the sdk updates a
  /// cluster marker in place instead of removing and re-adding it.
  final String id;
  final double lat;
  final double lng;
  final List<CatMarker> cats;

  int get count => cats.length;

  bool get containsHelp => cats.any((cat) => cat.needsHelp);
}

/// What one clustering pass produced: the cats still drawn individually,
/// and the groups standing in for the rest.
class ClusteredCats {
  const ClusteredCats({required this.loose, required this.clusters});

  final List<CatMarker> loose;
  final List<CatCluster> clusters;
}

/// Side of the screen cell cats are bucketed into, in logical pixels.
///
/// Roughly the width of an avatar marker plus its breathing room: two cats
/// inside one cell would overlap if both were drawn, which is exactly when
/// one mark is more honest than two.
const double clusterCellPixels = 64;

/// Groups [cats] by the screen cell they fall in at [zoom].
///
/// Linear in the number of cats, deliberately: the bbox read is
/// unpaginated, so a city-zoom viewport can hold a lot of them, and this
/// runs on every camera settle. Bucketing by projected pixel is the same
/// idea the sdk's own clusterer uses — what changes is that the result is
/// ours to draw.
///
/// [selectedId] never joins a cluster. The map has centred on that cat and
/// opened a sheet about it; folding it into a count would take it off the
/// map at the moment it matters most.
ClusteredCats clusterCats({
  required List<CatMarker> cats,
  required double zoom,
  String? selectedId,
}) {
  final buckets = <String, List<CatMarker>>{};
  final loose = <CatMarker>[];

  for (final cat in cats) {
    if (cat.id == selectedId) {
      loose.add(cat);
      continue;
    }
    final point = worldPixel(cat.lat, cat.lng, zoom);
    final key =
        '${(point.dx / clusterCellPixels).floor()}:'
        '${(point.dy / clusterCellPixels).floor()}';
    buckets.putIfAbsent(key, () => <CatMarker>[]).add(cat);
  }

  final clusters = <CatCluster>[];
  for (final entry in buckets.entries) {
    final group = entry.value;
    if (group.length < 2) {
      loose.addAll(group);
      continue;
    }
    // Sorted by id so the cluster's identity and position do not depend on
    // the order the api happened to return the cats in.
    final ordered = [...group]..sort((a, b) => a.id.compareTo(b.id));
    var sumLat = 0.0;
    var sumLng = 0.0;
    for (final cat in ordered) {
      sumLat += cat.lat;
      sumLng += cat.lng;
    }
    clusters.add(
      CatCluster(
        // The cell is the group's identity: the same cats in the same cell
        // produce the same marker id on the next rebuild.
        id: 'cluster:${entry.key}',
        lat: sumLat / ordered.length,
        lng: sumLng / ordered.length,
        cats: ordered,
      ),
    );
  }

  loose.sort((a, b) => a.id.compareTo(b.id));
  clusters.sort((a, b) => a.id.compareTo(b.id));
  return ClusteredCats(loose: loose, clusters: clusters);
}

/// Whether zooming in would ever break [cluster] apart.
///
/// A cell is about seven metres across at the map's closest zoom, so two
/// cats recorded from the same doorway share one for good: tapping the
/// group zooms until there is no zoom left and the cats inside it stay
/// unreachable. The caller checks this first and offers to pick from the
/// group instead of pretending another tap will help.
bool clusterCanSplitByZooming(CatCluster cluster, {required double maxZoom}) =>
    clusterCats(cats: cluster.cats, zoom: maxZoom).clusters.isEmpty;

/// How far a cluster tap zooms in.
///
/// Fitting the camera to the group's own bounds sounds more precise, but
/// for a tight group (cats a few metres apart) the bounds-fit zoom can come
/// out lower than the current one — the tap would not zoom in at all and
/// the group would never split. A fixed step guarantees forward progress on
/// every tap.
const double clusterTapZoomStep = 2.0;

/// The zoom a tap on a cluster should move to, never past [maxZoom].
double zoomAfterClusterTap(double currentZoom, double maxZoom) =>
    math.min(currentZoom + clusterTapZoomStep, maxZoom);
