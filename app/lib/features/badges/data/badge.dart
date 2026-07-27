/// Wire shape from `GET /v1/me/badges` and `GET /v1/me/profile`'s `badges`
/// array (docs/architecture/api.md, issue #80) — one of the 5 fixed mvp
/// badges (docs/product/badges.md), always returned earned or not, never a
/// filtered list.
class BadgeStatus {
  const BadgeStatus({
    required this.id,
    required this.name,
    required this.icon,
    required this.condition,
    required this.descr,
    required this.value,
    required this.target,
    required this.earned,
    required this.earnedAt,
  });

  final String id;
  final String name;
  final String icon;
  final String condition;
  final String descr;
  final int value;
  final int target;
  final bool earned;
  final DateTime? earnedAt;

  factory BadgeStatus.fromJson(Map<String, dynamic> json) {
    final rawEarnedAt = json['earned_at'] as String?;
    return BadgeStatus(
      id: json['id'] as String,
      name: json['name'] as String,
      icon: json['icon'] as String,
      condition: json['condition'] as String,
      descr: json['descr'] as String,
      value: json['value'] as int,
      target: json['target'] as int,
      earned: json['earned'] as bool,
      earnedAt: rawEarnedAt != null ? DateTime.parse(rawEarnedAt) : null,
    );
  }
}
