/// Wire shapes from `GET /v1/me/profile` (docs/architecture/api.md, issue
/// #80) — the minimal authenticated profile surface: display name,
/// contribution totals, badge progress, and a capped recent-contributions
/// list, all derived server-side from account-owned data. No avatar field
/// (curated-avatar selection is deferred past this mvp slice — see
/// docs/product/badges.md's implementation note).
library;

import '../../badges/data/badge.dart';

class ContributionTotals {
  const ContributionTotals({
    required this.updates,
    required this.helps,
    required this.catsAdded,
    required this.distinctCats,
  });

  final int updates;
  final int helps;
  final int catsAdded;
  final int distinctCats;

  factory ContributionTotals.fromJson(Map<String, dynamic> json) {
    return ContributionTotals(
      updates: json['updates'] as int,
      helps: json['helps'] as int,
      catsAdded: json['cats_added'] as int,
      distinctCats: json['distinct_cats'] as int,
    );
  }
}

/// One entry of the profile's newest-first recent-contributions list.
/// `statuses`/`needsHelpCategory` mirror [CatUpdateEntry]'s own shape so the
/// client composes display copy the same way it already does for the
/// cat-detail timeline — the server never pre-composes a label string.
class RecentContribution {
  const RecentContribution({
    required this.type,
    required this.catId,
    required this.catName,
    required this.catPrimaryPhoto,
    required this.statuses,
    required this.needsHelpCategory,
    required this.needsHelpCategoryLabel,
    required this.createdAt,
  });

  final String type; // 'update' | 'help' | 'cat_added'
  final String catId;
  final String catName;
  final String? catPrimaryPhoto;
  final List<String> statuses;
  final String? needsHelpCategory;
  final String? needsHelpCategoryLabel;
  final DateTime createdAt;

  bool get isUpdate => type == 'update';
  bool get isHelp => type == 'help';
  bool get isCatAdded => type == 'cat_added';

  factory RecentContribution.fromJson(Map<String, dynamic> json) {
    return RecentContribution(
      type: json['type'] as String,
      catId: json['cat_id'] as String,
      catName: json['cat_name'] as String,
      catPrimaryPhoto: json['cat_primary_photo'] as String?,
      statuses:
          (json['statuses'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      needsHelpCategory: json['needs_help_category'] as String?,
      needsHelpCategoryLabel: json['needs_help_category_label'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

class Profile {
  const Profile({
    required this.displayName,
    required this.totals,
    required this.badges,
    required this.recentContributions,
  });

  final String? displayName;
  final ContributionTotals totals;
  final List<BadgeStatus> badges;
  final List<RecentContribution> recentContributions;

  /// Only ever used to reflect a just-saved display name immediately
  /// (issue #80 product-owner review, finding 2), so a full re-fetch isn't
  /// needed for the edit sheet's own success path.
  Profile copyWith({String? displayName}) {
    return Profile(
      displayName: displayName ?? this.displayName,
      totals: totals,
      badges: badges,
      recentContributions: recentContributions,
    );
  }

  factory Profile.fromJson(Map<String, dynamic> json) {
    return Profile(
      displayName: json['display_name'] as String?,
      totals: ContributionTotals.fromJson(
        json['contribution_totals'] as Map<String, dynamic>,
      ),
      badges: (json['badges'] as List<dynamic>)
          .map((e) => BadgeStatus.fromJson(e as Map<String, dynamic>))
          .toList(),
      recentContributions: (json['recent_contributions'] as List<dynamic>)
          .map((e) => RecentContribution.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
