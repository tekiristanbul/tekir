/// Wire shape from `GET /v1/cats?bbox=` (docs/architecture/api.md): the
/// minimum fields a map marker needs. `name` and `areaLabel` were added for
/// the issue #21 prototype-parity correction — the minimum extra fields the
/// map's marker-preview sheet needs, so selecting a marker never triggers a
/// second full cat-detail fetch.
class CatMarker {
  const CatMarker({
    required this.id,
    this.name = '',
    required this.primaryPhoto,
    required this.lat,
    required this.lng,
    this.areaLabel,
    required this.needsHelp,
    this.lastUpdateAt,
  });

  final String id;
  final String name;
  final String primaryPhoto;
  final double lat;
  final double lng;
  final String? areaLabel;
  final bool needsHelp;
  final DateTime? lastUpdateAt;

  factory CatMarker.fromJson(Map<String, dynamic> json) {
    final area = json['area'] as Map<String, dynamic>;
    final rawLastUpdate = json['last_update_at'] as String?;
    return CatMarker(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      primaryPhoto: json['primary_photo'] as String? ?? '',
      lat: (area['lat'] as num).toDouble(),
      lng: (area['lng'] as num).toDouble(),
      areaLabel: json['area_label'] as String?,
      needsHelp: json['needs_help'] as bool? ?? false,
      lastUpdateAt: rawLastUpdate != null
          ? DateTime.parse(rawLastUpdate)
          : null,
    );
  }
}
