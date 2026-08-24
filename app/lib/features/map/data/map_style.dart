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

/// Hex values are the approved design's own tokens. Kept as literals inside
/// the style rather than referencing [AppColors] because this crosses into
/// the sdk as a json document, not as dart colours — and because the map's
/// ground is the design's palette, not the app chrome's.
const catsOfIstanbulMapStyle = '''
[
  {"elementType": "geometry", "stylers": [{"color": "#ece2d1"}]},
  {"elementType": "labels.icon", "stylers": [{"visibility": "off"}]},
  {"elementType": "labels.text.fill", "stylers": [{"color": "#6a584a"}]},
  {"elementType": "labels.text.stroke", "stylers": [{"color": "#f4eee3"}, {"weight": 2}]},

  {"featureType": "administrative", "elementType": "geometry", "stylers": [{"visibility": "off"}]},
  {"featureType": "administrative.land_parcel", "stylers": [{"visibility": "off"}]},
  {"featureType": "administrative.neighborhood", "elementType": "labels.text.fill", "stylers": [{"color": "#8a7563"}]},

  {"featureType": "landscape.man_made", "elementType": "geometry", "stylers": [{"color": "#e7dcc9"}]},
  {"featureType": "landscape.natural", "elementType": "geometry", "stylers": [{"color": "#ece2d1"}]},

  {"featureType": "poi", "stylers": [{"visibility": "off"}]},
  {"featureType": "poi.park", "stylers": [{"visibility": "on"}]},
  {"featureType": "poi.park", "elementType": "geometry", "stylers": [{"color": "#dde0c0"}]},
  {"featureType": "poi.park", "elementType": "labels", "stylers": [{"visibility": "off"}]},

  {"featureType": "road", "elementType": "geometry", "stylers": [{"color": "#e2d7c5"}]},
  {"featureType": "road", "elementType": "geometry.stroke", "stylers": [{"visibility": "off"}]},
  {"featureType": "road", "elementType": "labels.icon", "stylers": [{"visibility": "off"}]},
  {"featureType": "road.arterial", "elementType": "geometry", "stylers": [{"color": "#e5dbc9"}]},
  {"featureType": "road.highway", "elementType": "geometry", "stylers": [{"color": "#dccdb6"}]},
  {"featureType": "road.local", "elementType": "geometry", "stylers": [{"color": "#e7ddcc"}]},
  {"featureType": "road.local", "elementType": "labels", "stylers": [{"visibility": "off"}]},

  {"featureType": "transit", "stylers": [{"visibility": "off"}]},

  {"featureType": "water", "elementType": "geometry", "stylers": [{"color": "#cdd9d0"}]},
  {"featureType": "water", "elementType": "labels.text.fill", "stylers": [{"color": "#7d9187"}]},
  {"featureType": "water", "elementType": "labels.text.stroke", "stylers": [{"visibility": "off"}]}
]
''';
