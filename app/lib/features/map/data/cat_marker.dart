import '../../../core/models/active_alert.dart';

export '../../../core/models/active_alert.dart' show ActiveAlert;

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
    this.activeAlert,
    this.lastUpdateAt,
  });

  final String id;
  final String name;
  final String primaryPhoto;
  final double lat;
  final double lng;
  final String? areaLabel;

  /// Present only while the cat has an active needs-help alert (issue
  /// #4/#23) — never a bare boolean, so the preview sheet has the category
  /// and lifecycle it needs to render context, not just "something's wrong".
  final ActiveAlert? activeAlert;
  final DateTime? lastUpdateAt;

  bool get needsHelp => activeAlert != null;

  CatMarker copyWith({String? name}) {
    return CatMarker(
      id: id,
      name: name ?? this.name,
      primaryPhoto: primaryPhoto,
      lat: lat,
      lng: lng,
      areaLabel: areaLabel,
      activeAlert: activeAlert,
      lastUpdateAt: lastUpdateAt,
    );
  }

  factory CatMarker.fromJson(Map<String, dynamic> json) {
    final area = json['area'] as Map<String, dynamic>;
    final rawLastUpdate = json['last_update_at'] as String?;
    final rawActiveAlert = json['active_alert'] as Map<String, dynamic>?;
    return CatMarker(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      primaryPhoto: json['primary_photo'] as String? ?? '',
      lat: (area['lat'] as num).toDouble(),
      lng: (area['lng'] as num).toDouble(),
      areaLabel: json['area_label'] as String?,
      activeAlert: rawActiveAlert != null
          ? ActiveAlert.fromJson(rawActiveAlert)
          : null,
      lastUpdateAt: rawLastUpdate != null
          ? DateTime.parse(rawLastUpdate)
          : null,
    );
  }
}
