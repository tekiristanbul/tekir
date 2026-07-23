/// Wire shape from `GET /v1/cats?bbox=` (docs/architecture/api.md): the
/// minimum fields a map marker needs — not the full cat-detail shape.
class CatMarker {
  const CatMarker({
    required this.id,
    required this.primaryPhoto,
    required this.lat,
    required this.lng,
    required this.needsHelp,
    this.lastUpdateAt,
  });

  final String id;
  final String primaryPhoto;
  final double lat;
  final double lng;
  final bool needsHelp;
  final DateTime? lastUpdateAt;

  factory CatMarker.fromJson(Map<String, dynamic> json) {
    final area = json['area'] as Map<String, dynamic>;
    final rawLastUpdate = json['last_update_at'] as String?;
    return CatMarker(
      id: json['id'] as String,
      primaryPhoto: json['primary_photo'] as String? ?? '',
      lat: (area['lat'] as num).toDouble(),
      lng: (area['lng'] as num).toDouble(),
      needsHelp: json['needs_help'] as bool? ?? false,
      lastUpdateAt: rawLastUpdate != null
          ? DateTime.parse(rawLastUpdate)
          : null,
    );
  }
}
