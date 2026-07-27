import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/identity/session_identity.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/relative_time.dart';
import '../../badges/data/badge.dart';
import '../../badges/ui/badge_icons.dart';
import '../data/profile.dart';
import 'edit_display_name_sheet.dart';
import 'profile_notifier.dart';

const _statusLabelsTr = {
  'seen': 'görüldü',
  'fed': 'mama verildi',
  'water_provided': 'su verildi',
};

/// The minimal authenticated profile surface (issue #80): display name,
/// contribution totals, earned badges, and recent contributions — ported
/// from the approved prototype's `profileBodyHTML`/`profileGuestHTML`
/// (prototype/app.js:756-799). No avatar (curated-avatar selection is
/// deferred past this mvp slice — docs/product/badges.md's implementation
/// note) and no follower count/leaderboard/streak, matching
/// docs/product/community.md's minimal-profile decision exactly.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (ref.read(sessionIdentityServiceProvider).cached != null) {
        ref.read(profileProvider.notifier).load();
      }
    });
  }

  Future<void> _openEditDisplayName(String? currentName) async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      // ProfileScreen is a StatefulShellRoute branch root (app_router.dart)
      // with its own nested Navigator — without this, the sheet paints
      // underneath the shell's persistent add-cat fab (app_shell.dart),
      // mirroring map_screen.dart's identical CatPreviewSheet fix.
      useRootNavigator: true,
      builder: (_) => EditDisplayNameSheet(currentName: currentName),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(profileProvider);
    final isAuthenticated = ref.watch(sessionProvider).value != null;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: const Text('Profil'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s5),
          child: isAuthenticated
              ? _authenticatedBody(state)
              : const _GuestBody(),
        ),
      ),
    );
  }

  Widget _authenticatedBody(ProfileState state) {
    if (state.isLoading && !state.hasLoadedOnce) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.profile == null) {
      return _ErrorRetry(
        onRetry: () => ref.read(profileProvider.notifier).load(),
      );
    }
    final profile = state.profile;
    if (profile == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () => _openEditDisplayName(profile.displayName),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    profile.displayName ?? 'İsimsiz kullanıcı',
                    style: Theme.of(context).textTheme.titleLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: AppSpacing.s2),
                const Icon(
                  Icons.edit_outlined,
                  size: 18,
                  color: AppColors.faint,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.s5),
        _StatRow(totals: profile.totals),
        const SizedBox(height: AppSpacing.s6),
        Row(
          children: [
            Expanded(
              child: Text(
                'Rozetler',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            TextButton(
              onPressed: () => context.push('/badges'),
              child: const Text('Tümünü gör'),
            ),
          ],
        ),
        if (profile.badges.any((b) => b.earned))
          _BadgeStrip(badges: profile.badges)
        else
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpacing.s4),
            child: Text(
              'Henüz rozet kazanmadın. İlk katkını paylaş, buradan takip et.',
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
          ),
        const SizedBox(height: AppSpacing.s2),
        Text('Son katkılar', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpacing.s3),
        if (profile.recentContributions.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.s4),
            child: Text(
              'Henüz katkın yok. Bir kediyi gördüğünde "Gördüm" ile başla.',
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
          )
        else
          for (final c in profile.recentContributions) ...[
            _ContributionRow(contribution: c),
            const SizedBox(height: AppSpacing.s1),
          ],
        const SizedBox(height: AppSpacing.s5),
        SizedBox(
          height: kTapMin,
          child: OutlinedButton.icon(
            onPressed: () => context.push('/account'),
            icon: const Icon(Icons.tune, size: 18),
            label: const Text('Ayarlar'),
          ),
        ),
      ],
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.totals});

  final ContributionTotals totals;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatTile(value: totals.updates, label: 'güncelleme'),
        ),
        const SizedBox(width: AppSpacing.s2),
        Expanded(
          child: _StatTile(value: totals.helps, label: 'yardım bildirimi'),
        ),
        const SizedBox(width: AppSpacing.s2),
        Expanded(
          child: _StatTile(value: totals.catsAdded, label: 'eklenen kedi'),
        ),
        const SizedBox(width: AppSpacing.s2),
        Expanded(
          child: _StatTile(value: totals.distinctCats, label: 'kediye katkı'),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        vertical: AppSpacing.s3,
        horizontal: AppSpacing.s1,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        children: [
          Text(
            '$value',
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 18,
              color: AppColors.ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, color: AppColors.muted),
          ),
        ],
      ),
    );
  }
}

class _BadgeStrip extends StatelessWidget {
  const _BadgeStrip({required this.badges});

  final List<BadgeStatus> badges;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s4),
      child: SizedBox(
        height: 84,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: badges.length,
          separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.s2),
          itemBuilder: (context, index) {
            final b = badges[index];
            return InkWell(
              borderRadius: BorderRadius.circular(AppRadius.md),
              onTap: () => context.push('/badges/${b.id}'),
              child: Container(
                width: 76,
                padding: const EdgeInsets.all(AppSpacing.s2),
                decoration: BoxDecoration(
                  color: b.earned
                      ? AppColors.primarySoft
                      : AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      badgeIconFor(b.icon),
                      size: 26,
                      color: b.earned
                          ? AppColors.primaryStrong
                          : AppColors.faint,
                    ),
                    const SizedBox(height: AppSpacing.s1),
                    Text(
                      b.name,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ContributionRow extends StatelessWidget {
  const _ContributionRow({required this.contribution});

  final RecentContribution contribution;

  IconData get _icon {
    if (contribution.isCatAdded) return Icons.location_on;
    if (contribution.isHelp) return Icons.warning_amber_rounded;
    if (contribution.statuses.isEmpty) return Icons.edit;
    return switch (contribution.statuses.first) {
      'seen' => Icons.visibility,
      'fed' => Icons.ramen_dining,
      'water_provided' => Icons.water_drop,
      _ => Icons.edit,
    };
  }

  String get _label {
    if (contribution.isCatAdded) return 'yeni kedi eklendi';
    if (contribution.isHelp) {
      final label = contribution.needsHelpCategoryLabel;
      return label != null
          ? 'yardım bildirimi · ${label.toLowerCase()}'
          : 'yardım bildirimi';
    }
    return contribution.statuses.map((s) => _statusLabelsTr[s] ?? s).join(', ');
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => context.push('/cats/${contribution.catId}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
          child: Row(
            children: [
              Icon(_icon, size: 15, color: AppColors.muted),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text.rich(
                  overflow: TextOverflow.ellipsis,
                  TextSpan(
                    style: const TextStyle(color: AppColors.ink, fontSize: 13),
                    children: [
                      TextSpan(
                        text: contribution.catName,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(text: ' — $_label'),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Text(
                relativeTimeTr(contribution.createdAt),
                style: const TextStyle(fontSize: 11, color: AppColors.faint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GuestBody extends StatelessWidget {
  const _GuestBody();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.person_outline, size: 40, color: AppColors.faint),
        const SizedBox(height: AppSpacing.s3),
        Text('Giriş yapmadın', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpacing.s2),
        const Text(
          'Katkı geçmişini ve rozetlerini görmek, kedi eklemek ve güncelleme paylaşmak için giriş yapman gerekir. Haritayı ve kedi detaylarını girişsiz gezebilirsin.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted, height: 1.5),
        ),
        const SizedBox(height: AppSpacing.s5),
        SizedBox(
          height: kTapMin,
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => context.push('/login'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: AppColors.primaryInk,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
            ),
            child: const Text('Giriş yap'),
          ),
        ),
      ],
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 32, color: AppColors.help),
          const SizedBox(height: AppSpacing.s3),
          const Text(
            'Bağlantı sorunu oldu. Tekrar dener misin?',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: AppSpacing.s3),
          OutlinedButton(onPressed: onRetry, child: const Text('Tekrar dene')),
        ],
      ),
    );
  }
}
