/// Label-light basemap style (closer to a quiet, carto-positron-like look)
/// requested after the hi-fi prototype's "map feels busy" feedback: strip
/// poi/business/transit labels, keep water, neighborhood names, and roads.
/// Full palette restyling (positron's actual colors) is a separate design
/// decision, not made here — this only controls what's visible, not color.
const catsOfIstanbulMapStyle = '''
[
  {"featureType": "poi", "elementType": "labels", "stylers": [{"visibility": "off"}]},
  {"featureType": "poi.business", "stylers": [{"visibility": "off"}]},
  {"featureType": "transit", "stylers": [{"visibility": "off"}]},
  {"featureType": "road", "elementType": "labels.icon", "stylers": [{"visibility": "off"}]}
]
''';
