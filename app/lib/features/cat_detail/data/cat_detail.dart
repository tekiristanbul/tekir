/// Wire shapes from `GET /v1/cats/{cat_id}` and `GET /v1/cats/{cat_id}/updates`
/// (docs/architecture/api.md).
library;

/// One entry of the controlled trait vocabulary (issue #21): a stable key
/// plus its current display label. Not a fixed/closed set — see
/// docs/product/cats.md.
class CatTrait {
  const CatTrait({required this.key, required this.label});

  final String key;
  final String label;

  factory CatTrait.fromJson(Map<String, dynamic> json) {
    return CatTrait(key: json['key'] as String, label: json['label'] as String);
  }
}

class CatDetail {
  const CatDetail({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.areaLabel,
    required this.primaryPhoto,
    required this.traits,
    required this.createdAt,
    required this.lastUpdateAt,
  });

  final String id;
  final String name;
  final double lat;
  final double lng;

  /// Human-readable, display-only location (e.g. "Moda Sahili, Kadıköy") —
  /// added for the issue #21 prototype-parity correction so the detail
  /// screen never has to show raw coordinates. Nullable: not every cat has
  /// one set.
  final String? areaLabel;
  final String? primaryPhoto;
  final List<CatTrait> traits;
  final DateTime createdAt;
  final DateTime? lastUpdateAt;

  factory CatDetail.fromJson(Map<String, dynamic> json) {
    final area = json['area'] as Map<String, dynamic>;
    final rawLastUpdate = json['last_update_at'] as String?;
    return CatDetail(
      id: json['id'] as String,
      name: json['name'] as String,
      lat: (area['lat'] as num).toDouble(),
      lng: (area['lng'] as num).toDouble(),
      areaLabel: json['area_label'] as String?,
      primaryPhoto: json['primary_photo'] as String?,
      traits: (json['traits'] as List<dynamic>)
          .map((e) => CatTrait.fromJson(e as Map<String, dynamic>))
          .toList(),
      createdAt: DateTime.parse(json['created_at'] as String),
      lastUpdateAt: rawLastUpdate != null
          ? DateTime.parse(rawLastUpdate)
          : null,
    );
  }
}

/// One entry of a cat's newest-first status history (issue #3): one or more
/// structured statuses plus an optional free-text comment.
class CatUpdateEntry {
  const CatUpdateEntry({
    required this.id,
    required this.statuses,
    required this.comment,
    required this.createdAt,
  });

  final String id;
  final List<String> statuses;
  final String? comment;
  final DateTime createdAt;

  factory CatUpdateEntry.fromJson(Map<String, dynamic> json) {
    return CatUpdateEntry(
      id: json['id'] as String,
      statuses: (json['statuses'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      comment: json['comment'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

/// One newest-first page of a cat's update history. nextCursor is the
/// opaque token to pass back verbatim for the next page; null once there is
/// no further page.
class UpdatesPage {
  const UpdatesPage({required this.items, required this.nextCursor});

  final List<CatUpdateEntry> items;
  final String? nextCursor;

  factory UpdatesPage.fromJson(Map<String, dynamic> json) {
    return UpdatesPage(
      items: (json['items'] as List<dynamic>)
          .map((e) => CatUpdateEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      nextCursor: json['next_cursor'] as String?,
    );
  }
}
