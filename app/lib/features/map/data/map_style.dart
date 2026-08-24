/// The map's own ground, in tekir's colours (issue #285, approved design
/// artboard 01 and its `renk` block).
///
/// The map used to be google's default palette with the noisiest labels
/// switched off — grey roads, blue water, white ground — under a set of
/// cream-and-terracotta markers that had nothing to do with it. The
/// approved design draws the city as paper: warm ground, sand roads, muted
/// green parks, grey-green water. The cats sit on it instead of on top of
/// it.
///
/// **On the values.** The design's artboard sets its ground and its roads
/// two steps apart on the same warm ramp, which reads because the artboard
/// draws four roads on an empty rectangle. A real istanbul viewport is
/// mostly road, and at that density the same two steps collapse into one
/// flat mass — the first pass at this also tinted built-up land darker than
/// the ground, which turned the whole city into a single slab.
///
/// So the hues are the design's and the ordering is the design's — ground
/// lightest, roads darker, parks green, water grey-green — while the value
/// range is widened enough for real geometry to separate, and roads carry a
/// three-step hierarchy so a main road is not a side street. Choosing which
/// warm tone goes where is a decision the artboard cannot make, because it
/// has no map in it.
///
/// This is a json style string, not a cloud-hosted `mapId`. Both can carry
/// these colours; the json one is versioned in this repository, reviewable
/// in a diff, and needs no console configuration per platform key — which
/// is what keeps 0.5 from depending on an out-of-band setup step. Moving to
/// a `mapId` later changes where the same palette lives, not what it is.
///
/// Labels stay legible rather than decorative: neighbourhood and road names
/// survive in ink on paper, and everything the map would otherwise shout
/// about — businesses, transit, poi icons — is gone, as it already was.
library;

/// Kept as literals inside the style rather than referencing [AppColors]
/// because this crosses into the sdk as a json document, not as dart
/// colours — and because the map's ground is the design's palette, not the
/// app chrome's.
const catsOfIstanbulMapStyle = '''
[
  {"elementType": "geometry", "stylers": [{"color": "#f4ecde"}]},
  {"elementType": "labels.icon", "stylers": [{"visibility": "off"}]},
  {"elementType": "labels.text.fill", "stylers": [{"color": "#7a6653"}]},
  {"elementType": "labels.text.stroke", "stylers": [{"color": "#f4ecde"}, {"weight": 2}]},

  {"featureType": "administrative", "elementType": "geometry", "stylers": [{"visibility": "off"}]},
  {"featureType": "administrative.land_parcel", "stylers": [{"visibility": "off"}]},
  {"featureType": "administrative.neighborhood", "elementType": "labels.text.fill", "stylers": [{"color": "#8a7563"}]},

  {"featureType": "landscape", "elementType": "geometry", "stylers": [{"color": "#f4ecde"}]},
  {"featureType": "landscape.natural", "elementType": "geometry", "stylers": [{"color": "#eee6d5"}]},

  {"featureType": "poi", "stylers": [{"visibility": "off"}]},
  {"featureType": "poi.park", "stylers": [{"visibility": "on"}]},
  {"featureType": "poi.park", "elementType": "geometry", "stylers": [{"color": "#d5dab0"}]},
  {"featureType": "poi.park", "elementType": "labels", "stylers": [{"visibility": "off"}]},

  {"featureType": "road", "elementType": "geometry.stroke", "stylers": [{"visibility": "off"}]},
  {"featureType": "road", "elementType": "labels.icon", "stylers": [{"visibility": "off"}]},
  {"featureType": "road", "elementType": "labels.text.fill", "stylers": [{"color": "#8a7563"}]},
  {"featureType": "road.local", "elementType": "geometry", "stylers": [{"color": "#e8dcc7"}]},
  {"featureType": "road.local", "elementType": "labels", "stylers": [{"visibility": "off"}]},
  {"featureType": "road.arterial", "elementType": "geometry", "stylers": [{"color": "#ded0b6"}]},
  {"featureType": "road.highway", "elementType": "geometry", "stylers": [{"color": "#d2bf9f"}]},

  {"featureType": "transit", "stylers": [{"visibility": "off"}]},

  {"featureType": "water", "elementType": "geometry", "stylers": [{"color": "#c9d6cd"}]},
  {"featureType": "water", "elementType": "labels.text.fill", "stylers": [{"color": "#75897f"}]},
  {"featureType": "water", "elementType": "labels.text.stroke", "stylers": [{"visibility": "off"}]}
]
''';
