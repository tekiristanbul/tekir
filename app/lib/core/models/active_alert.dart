/// An active `yardıma ihtiyacı var` state (issue #4/#23, reshaped by the
/// issue #100/#101 simplified help contract) — shared between the map's
/// `CatMarker` and `CatDetail` (docs/architecture/api.md), since both
/// `GET /v1/cats?bbox=` and `GET /v1/cats/{cat_id}` embed the same
/// `active_alert` shape. The map/cat-detail responses only ever include
/// this object while the state is still active — the server derives that
/// from its own clock, so this object's mere presence (not a separate
/// boolean) means "active".
///
/// The wire object still carries `category`/`category_label` for 0.1
/// clients; this 0.2 model deliberately never reads them — legacy help
/// categories are never reproduced in the 0.2 interface in any form
/// (docs/product/alerts.md). `comment` is the reporter's optional note,
/// the field 0.2 clients render.
class ActiveAlert {
  const ActiveAlert({
    this.comment,
    required this.createdAt,
    required this.expiresAt,
  });

  final String? comment;
  final DateTime createdAt;
  final DateTime expiresAt;

  factory ActiveAlert.fromJson(Map<String, dynamic> json) {
    return ActiveAlert(
      comment: json['comment'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      expiresAt: DateTime.parse(json['expires_at'] as String),
    );
  }
}
