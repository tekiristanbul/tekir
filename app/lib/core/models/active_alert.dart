/// An active needs-help alert (issue #4/#23) — shared between the map's
/// `CatMarker` and `CatDetail` (docs/architecture/api.md), since both
/// `GET /v1/cats?bbox=` and `GET /v1/cats/{cat_id}` embed the same
/// `active_alert` shape. The map/cat-detail responses only ever include
/// this object while the alert is still active — the server derives that
/// from its own clock, so this object's mere presence (not a separate
/// boolean) means "active".
class ActiveAlert {
  const ActiveAlert({
    required this.category,
    required this.categoryLabel,
    required this.createdAt,
    required this.expiresAt,
  });

  final String category;
  final String categoryLabel;
  final DateTime createdAt;
  final DateTime expiresAt;

  factory ActiveAlert.fromJson(Map<String, dynamic> json) {
    return ActiveAlert(
      category: json['category'] as String,
      categoryLabel: json['category_label'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      expiresAt: DateTime.parse(json['expires_at'] as String),
    );
  }
}
