import '../../map/data/cat_marker.dart';

export '../../../core/models/active_alert.dart' show ActiveAlert;

/// Wire shape from `GET /v1/cats/discover` (docs/architecture/api.md,
/// issue #82) — the same map-marker-preview fields [CatMarker] carries,
/// plus [distanceMeters], the field this endpoint adds.
///
/// [lat]/[lng] arrived with issue #284. This response deliberately had no
/// coordinates while its only consumer was a list that opened cat detail,
/// which fetches its own. Picking a search result now selects that cat on
/// the map instead, and the map needs the position in the same breath as
/// the tap — so the row carries it and [toCatMarker] hands the map exactly
/// the shape it already renders.
class DiscoverCat {
  const DiscoverCat({
    required this.id,
    this.name = '',
    required this.primaryPhoto,
    required this.lat,
    required this.lng,
    this.areaLabel,
    required this.distanceMeters,
    this.activeAlert,
    this.lastUpdateAt,
  });

  final String id;
  final String name;
  final String primaryPhoto;
  final double lat;
  final double lng;
  final String? areaLabel;
  final double distanceMeters;

  /// Present only while the cat has an active needs-help alert (issue
  /// #4/#23) — always non-null for a `filter=needs_help` result, and may or
  /// may not be present for a `filter=nearby` result.
  final ActiveAlert? activeAlert;
  final DateTime? lastUpdateAt;

  bool get needsHelp => activeAlert != null;

  /// The same cat in the shape the map's own marker layer speaks, so
  /// selecting a search result needs no second read and no second model.
  CatMarker toCatMarker() {
    return CatMarker(
      id: id,
      name: name,
      primaryPhoto: primaryPhoto,
      lat: lat,
      lng: lng,
      areaLabel: areaLabel,
      activeAlert: activeAlert,
      lastUpdateAt: lastUpdateAt,
    );
  }

  DiscoverCat copyWith({String? name}) {
    return DiscoverCat(
      id: id,
      name: name ?? this.name,
      primaryPhoto: primaryPhoto,
      lat: lat,
      lng: lng,
      areaLabel: areaLabel,
      distanceMeters: distanceMeters,
      activeAlert: activeAlert,
      lastUpdateAt: lastUpdateAt,
    );
  }

  factory DiscoverCat.fromJson(Map<String, dynamic> json) {
    final rawLastUpdate = json['last_update_at'] as String?;
    final rawActiveAlert = json['active_alert'] as Map<String, dynamic>?;
    // `area` is additive (issue #284): a response served by an api that
    // predates it still parses, and such a cat simply cannot be selected on
    // the map — it falls back to the istanbul origin rather than throwing.
    final area = json['area'] as Map<String, dynamic>?;
    return DiscoverCat(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      primaryPhoto: json['primary_photo'] as String? ?? '',
      lat: (area?['lat'] as num?)?.toDouble() ?? 0,
      lng: (area?['lng'] as num?)?.toDouble() ?? 0,
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
