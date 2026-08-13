import '../../../core/models/active_alert.dart';

export '../../../core/models/active_alert.dart' show ActiveAlert;

/// Wire shape from `GET /v1/cats/discover` (docs/architecture/api.md,
/// issue #82) — the same map-marker-preview fields [CatMarker] carries,
/// minus `area` (this is a distance-ordered list, not a viewport — opening
/// an entry goes through the existing cat-detail flow, which fetches its
/// own coordinates), plus [distanceMeters], the field this endpoint adds.
class DiscoverCat {
  const DiscoverCat({
    required this.id,
    this.name = '',
    required this.primaryPhoto,
    this.areaLabel,
    required this.distanceMeters,
    this.activeAlert,
    this.lastUpdateAt,
  });

  final String id;
  final String name;
  final String primaryPhoto;
  final String? areaLabel;
  final double distanceMeters;

  /// Present only while the cat has an active needs-help alert (issue
  /// #4/#23) — always non-null for a `filter=needs_help` result, and may or
  /// may not be present for a `filter=nearby` result.
  final ActiveAlert? activeAlert;
  final DateTime? lastUpdateAt;

  bool get needsHelp => activeAlert != null;

  DiscoverCat copyWith({String? name}) {
    return DiscoverCat(
      id: id,
      name: name ?? this.name,
      primaryPhoto: primaryPhoto,
      areaLabel: areaLabel,
      distanceMeters: distanceMeters,
      activeAlert: activeAlert,
      lastUpdateAt: lastUpdateAt,
    );
  }

  factory DiscoverCat.fromJson(Map<String, dynamic> json) {
    final rawLastUpdate = json['last_update_at'] as String?;
    final rawActiveAlert = json['active_alert'] as Map<String, dynamic>?;
    return DiscoverCat(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      primaryPhoto: json['primary_photo'] as String? ?? '',
      areaLabel: json['area_label'] as String?,
      distanceMeters: (json['distance_meters'] as num).toDouble(),
      activeAlert: rawActiveAlert != null
          ? ActiveAlert.fromJson(rawActiveAlert)
          : null,
      lastUpdateAt: rawLastUpdate != null
          ? DateTime.parse(rawLastUpdate)
          : null,
    );
  }
}
