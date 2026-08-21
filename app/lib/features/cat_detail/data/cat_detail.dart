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
    this.lastSeenAt,
    this.lastFedAt,
    this.lastWaterAt,
    this.activeAlert,
    this.mediaCount = 0,
    this.isOwner = false,
    this.ownerUserId,
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

  /// Each null when the cat has never had an update carrying that
  /// structured status — independent from [lastUpdateAt] and from each
  /// other (issue #121's three-stat header parity gap).
  final DateTime? lastSeenAt;
  final DateTime? lastFedAt;
  final DateTime? lastWaterAt;
  final ActiveAlert? activeAlert;

  /// Size of the cat's photo archive (`GET /v1/cats/{cat_id}/media`) — the
  /// cover photo's count pill and the "medya N" tab label (issue #121's
  /// media-archive/cover-counter parity gap).
  final int mediaCount;

  /// Server-derived (issue #156): true only for the cat's own owner's
  /// authenticated read — always false for a guest read or any other
  /// account. The client uses this, and only this, to decide whether to
  /// offer the "ana fotoğraf yap" (make cover photo) affordance in the
  /// media archive; the server re-checks ownership on every request
  /// regardless.
  final bool isOwner;

  /// The account that created this cat, or null for a seed cat no account
  /// owns (issue #234) — what the "engelle" action on cat detail acts on.
  final String? ownerUserId;

  /// Returns a copy with only the named fields replaced.
  ///
  /// Exists because hand-rebuilding this model in a notifier silently drops
  /// whatever the call site forgot: `CatDetailNotifier.prependUpdate` used
  /// to construct a fresh [CatDetail] field by field and omitted
  /// [lastSeenAt], [lastFedAt], [lastWaterAt] and [ownerUserId], all four of
  /// which are optional with a null default — so posting an update wiped the
  /// three-stat header and the cat's owner in one move, with no compile
  /// error to notice it. Every future optional field added to this class
  /// would have inherited the same failure. Mutate this model through
  /// `copyWith`, never by re-invoking the constructor with a subset.
  ///
  /// A null argument means "leave unchanged", never "set to null": nothing
  /// in this app needs to clear one of these fields locally, and a
  /// sentinel-based API would buy that at the cost of every call site's
  /// readability.
  CatDetail copyWith({
    String? name,
    double? lat,
    double? lng,
    String? areaLabel,
    String? primaryPhoto,
    DateTime? lastUpdateAt,
    DateTime? lastSeenAt,
    DateTime? lastFedAt,
    DateTime? lastWaterAt,
    ActiveAlert? activeAlert,
    int? mediaCount,
    bool? isOwner,
    String? ownerUserId,
  }) {
    return CatDetail(
      id: id,
      name: name ?? this.name,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      areaLabel: areaLabel ?? this.areaLabel,
      primaryPhoto: primaryPhoto ?? this.primaryPhoto,
      createdAt: createdAt,
      lastUpdateAt: lastUpdateAt ?? this.lastUpdateAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      lastFedAt: lastFedAt ?? this.lastFedAt,
      lastWaterAt: lastWaterAt ?? this.lastWaterAt,
      activeAlert: activeAlert ?? this.activeAlert,
      mediaCount: mediaCount ?? this.mediaCount,
      isOwner: isOwner ?? this.isOwner,
      ownerUserId: ownerUserId ?? this.ownerUserId,
    );
  }

  /// Advances the three-stat header's own timestamps for whichever
  /// structured statuses [entry] carries, leaving the other two untouched.
  ///
  /// The three questions — görüldü / mama / su — are independent of each
  /// other and of [lastUpdateAt], so a `fed` entry may only move
  /// [lastFedAt]. Derived locally rather than re-fetched: the entry is
  /// already server-confirmed, and a round trip to learn a timestamp the
  /// client is holding would be the slow way to be no more correct.
  ///
  /// Only ever moves a timestamp forward. A correction or an out-of-order
  /// arrival can carry an older `created_at`, and the header answers "when
  /// was this cat last fed" — never "which entry landed most recently".
  ///
  /// The keys mirror `catUpdateStatusOptions`; an entry carrying anything
  /// else (a future or legacy status) moves nothing rather than guessing
  /// which question it answers.
  CatDetail withStatusTimes(CatUpdateEntry entry) {
    DateTime? advanced(String status, DateTime? current) {
      if (!entry.statuses.contains(status)) return null;
      if (current != null && !entry.createdAt.isAfter(current)) return null;
      return entry.createdAt;
    }

    return copyWith(
      lastSeenAt: advanced('seen', lastSeenAt),
      lastFedAt: advanced('fed', lastFedAt),
      lastWaterAt: advanced('water_provided', lastWaterAt),
    );
  }

  factory CatDetail.fromJson(Map<String, dynamic> json) {
    final area = json['area'] as Map<String, dynamic>;
    final rawLastUpdate = json['last_update_at'] as String?;
    final rawLastSeen = json['last_seen_at'] as String?;
    final rawLastFed = json['last_fed_at'] as String?;
    final rawLastWater = json['last_water_at'] as String?;
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
      lastSeenAt: rawLastSeen != null ? DateTime.parse(rawLastSeen) : null,
      lastFedAt: rawLastFed != null ? DateTime.parse(rawLastFed) : null,
      lastWaterAt: rawLastWater != null ? DateTime.parse(rawLastWater) : null,
      activeAlert: rawActiveAlert != null
          ? ActiveAlert.fromJson(rawActiveAlert)
          : null,
      mediaCount: (json['media_count'] as num?)?.toInt() ?? 0,
      isOwner: json['is_owner'] as bool? ?? false,
      ownerUserId: json['owner_user_id'] as String?,
    );
  }
}

/// One entry of `GET /v1/cats/{cat_id}/media`'s newest-first photo archive
/// (issue #121's media-archive parity gap). [isCover] mirrors the cat's
/// current cover photo — the client renders the design's "ana" badge on
/// exactly that entry. [mediaContentType] (issue #179) mirrors
/// [CatUpdateEntry.mediaContentType] — [isVideoMedia] is the derived check
/// the gallery grid/detail view reads instead of comparing this prefix
/// itself, exactly like the timeline already does. [mediaMuted] (issue
/// #194) is the uploader's own stored audio choice — every video playback
/// surface honors it; meaningless for a photo entry.
class CatMediaItem {
  const CatMediaItem({
    required this.id,
    required this.url,
    required this.isCover,
    required this.createdAt,
    this.uploaderDisplayName,
    this.uploaderUserId,
    this.mediaContentType,
    this.mediaMuted = true,
  });

  final String id;
  final String url;
  final bool isCover;
  final DateTime createdAt;
  final String? uploaderDisplayName;

  /// The account that uploaded this media (issue #234), or null for media
  /// predating account attribution.
  final String? uploaderUserId;
  final String? mediaContentType;
  final bool mediaMuted;

  bool get isVideoMedia => mediaContentType?.startsWith('video/') ?? false;

  factory CatMediaItem.fromJson(Map<String, dynamic> json) {
    return CatMediaItem(
      id: json['id'] as String,
      url: json['url'] as String,
      isCover: json['is_cover'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
      uploaderDisplayName: json['uploader_display_name'] as String?,
      uploaderUserId: json['uploader_user_id'] as String?,
      mediaContentType: json['media_content_type'] as String?,
      mediaMuted: json['media_muted'] as bool? ?? true,
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
    this.authorUserId,
    this.correctionExpiresAt,
    this.authorDisplayName,
    this.photoUrl,
    this.mediaContentType,
    this.mediaMuted,
  });

  final String id;
  final bool needsHelp;
  final List<String> statuses;
  final String? comment;
  final DateTime createdAt;

  final DateTime? needsHelpExpiresAt;
  final bool? needsHelpActive;

  /// The author's display name, null when the row has no author or the
  /// author never set one — the timeline renders a generic avatar in that
  /// case rather than inventing a name or initial (issue #121).
  final String? authorDisplayName;

  /// Url of the media this entry carries, null when it carries none
  /// (issue #121's timeline-thumbnail parity gap, wired up by issue #153's
  /// optional update composer photo attachment). Despite the name, this is
  /// set for both a photo and a video attachment — [mediaContentType] is
  /// what tells them apart.
  final String? photoUrl;

  /// The attached media's content type (e.g. `image/jpeg`, `video/mp4`),
  /// null under the same conditions as [photoUrl] (issue #153's video
  /// support). [isVideoMedia] is the derived check the ui reads instead of
  /// comparing this prefix itself.
  final String? mediaContentType;

  /// Whether [photoUrl] — when set — points at a video rather than an
  /// image, per the server's `media_content_type` (issue #153).
  bool get isVideoMedia => mediaContentType?.startsWith('video/') ?? false;

  /// The attached video's stored audio choice (issue #194), null under the
  /// same conditions as [photoUrl] — every video playback surface honors
  /// it. Meaningless for a photo attachment.
  final bool? mediaMuted;

  /// Server-derived (issue #80): true only when this entry was returned to
  /// its own author's authenticated read of `GET .../updates` — always
  /// false for a guest read or someone else's update. Never left for the
  /// client to compute by comparing ids itself.
  final bool authorIsMe;

  /// The account that wrote this update (issue #234), or null for an
  /// update predating account attribution.
  final String? authorUserId;

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
      authorUserId: json['author_user_id'] as String?,
      correctionExpiresAt: rawCorrectionExpiresAt != null
          ? DateTime.parse(rawCorrectionExpiresAt)
          : null,
      authorDisplayName: json['author_display_name'] as String?,
      photoUrl: json['photo_url'] as String?,
      mediaContentType: json['media_content_type'] as String?,
      mediaMuted: json['media_muted'] as bool?,
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
