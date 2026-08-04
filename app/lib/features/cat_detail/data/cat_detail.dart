/// Wire shapes from `GET /v1/cats/{cat_id}` and `GET /v1/cats/{cat_id}/updates`
/// (docs/architecture/api.md).
library;

import '../../../core/models/active_alert.dart';

export '../../../core/models/active_alert.dart' show ActiveAlert;

class CatDetail {
  const CatDetail({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.areaLabel,
    required this.primaryPhoto,
    required this.createdAt,
    required this.lastUpdateAt,
    this.activeAlert,
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
  final DateTime createdAt;
  final DateTime? lastUpdateAt;
  final ActiveAlert? activeAlert;

  factory CatDetail.fromJson(Map<String, dynamic> json) {
    final area = json['area'] as Map<String, dynamic>;
    final rawLastUpdate = json['last_update_at'] as String?;
    final rawActiveAlert = json['active_alert'] as Map<String, dynamic>?;
    return CatDetail(
      id: json['id'] as String,
      name: json['name'] as String,
      lat: (area['lat'] as num).toDouble(),
      lng: (area['lng'] as num).toDouble(),
      areaLabel: json['area_label'] as String?,
      primaryPhoto: json['primary_photo'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      lastUpdateAt: rawLastUpdate != null
          ? DateTime.parse(rawLastUpdate)
          : null,
      activeAlert: rawActiveAlert != null
          ? ActiveAlert.fromJson(rawActiveAlert)
          : null,
    );
  }
}

/// One entry of a cat's newest-first history: one or more structured
/// statuses, the `yardıma ihtiyacı var` flag (issue #100/#101 simplified
/// help contract), or both in a single record, plus an optional free-text
/// comment — which doubles as the help note on a help-carrying entry.
/// needsHelpActive is server-decided (the server's clock, never the
/// client's) and is only meaningful when [needsHelp]; an expired
/// help-carrying entry stays in history exactly like an ordinary one, just
/// with needsHelpActive false.
///
/// The wire entry still carries `kind` and the
/// `needs_help_category`/`needs_help_category_label` compat fields for 0.1
/// clients; this 0.2 model reads the flag and deliberately never reads the
/// category fields — legacy help categories are never reproduced in the
/// 0.2 interface in any form (docs/product/alerts.md). `kind` survives
/// only as a parse fallback so a legacy category-bearing payload without
/// the flag stays renderable through the compatibility window.
class CatUpdateEntry {
  const CatUpdateEntry({
    required this.id,
    this.needsHelp = false,
    required this.statuses,
    required this.comment,
    required this.createdAt,
    this.needsHelpExpiresAt,
    this.needsHelpActive,
    this.authorIsMe = false,
    this.correctionExpiresAt,
  });

  final String id;
  final bool needsHelp;
  final List<String> statuses;
  final String? comment;
  final DateTime createdAt;

  final DateTime? needsHelpExpiresAt;
  final bool? needsHelpActive;

  /// Server-derived (issue #80): true only when this entry was returned to
  /// its own author's authenticated read of `GET .../updates` — always
  /// false for a guest read or someone else's update. Never left for the
  /// client to compute by comparing ids itself.
  final bool authorIsMe;

  /// Non-null only when [authorIsMe] and the row is a correctable resource
  /// (issue #80, extended by #101: every post-migration row, help-carrying
  /// or not — a legacy pre-#101 help subtype row never gets one):
  /// `created_at` + the fixed 10-minute correction window
  /// (docs/product/updates.md). Used only to decide whether to show the
  /// correction affordance/countdown — the server remains the sole
  /// authority on whether an actual correction attempt succeeds.
  final DateTime? correctionExpiresAt;

  /// Whether this entry is still eligible for the caller's own
  /// correction/delete action — its own copy of PATCH/DELETE's window
  /// check for ui purposes only; the server re-checks this independently
  /// against its own clock on every request.
  bool isCorrectionOpen({DateTime? now}) {
    final expiresAt = correctionExpiresAt;
    if (!authorIsMe || expiresAt == null) return false;
    return expiresAt.isAfter(now ?? DateTime.now());
  }

  factory CatUpdateEntry.fromJson(Map<String, dynamic> json) {
    final rawExpiresAt = json['needs_help_expires_at'] as String?;
    final rawCorrectionExpiresAt = json['correction_expires_at'] as String?;
    return CatUpdateEntry(
      id: json['id'] as String,
      // A payload predating the flag (legacy 0.1 shape) stays renderable
      // through the compatibility window via its kind.
      needsHelp:
          json['needs_help'] as bool? ??
          (json['kind'] as String?) == 'needs_help',
      statuses: (json['statuses'] as List<dynamic>? ?? const [])
          .map((e) => e as String)
          .toList(),
      comment: json['comment'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      needsHelpExpiresAt: rawExpiresAt != null
          ? DateTime.parse(rawExpiresAt)
          : null,
      needsHelpActive: json['needs_help_active'] as bool?,
      authorIsMe: json['author_is_me'] as bool? ?? false,
      correctionExpiresAt: rawCorrectionExpiresAt != null
          ? DateTime.parse(rawCorrectionExpiresAt)
          : null,
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
