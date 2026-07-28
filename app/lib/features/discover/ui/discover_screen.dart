import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';

import '../../../core/identity/session_identity.dart';
import '../../../core/models/active_alert.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/distance_format.dart';
import '../../../core/utils/relative_time.dart';
import '../../auth/ui/auth_gate.dart';
import '../../map/data/cat_marker.dart';
import '../data/discover_location_service.dart';
import 'discover_notifier.dart';

/// Keşfet: the three approved mvp discovery surfaces (docs/product/
/// discovery.md, issue #82) — every active cat by distance ("Yakınımda"),
/// only those with an active needs-help alert ("Yardım gerekiyor"), and the
/// account's own followed cats ("Takip ettiklerim") — matching the approved
/// prototype's segmented control exactly (prototype/app.js:707-749).
class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  final _nearbyScroll = ScrollController();
  final _needsHelpScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _nearbyScroll.addListener(
      () => _maybeLoadMore(_nearbyScroll, DiscoverTab.nearby),
    );
    _needsHelpScroll.addListener(
      () => _maybeLoadMore(_needsHelpScroll, DiscoverTab.needsHelp),
    );
    Future.microtask(_loadSelectedTabIfNeeded);
  }

  @override
  void dispose() {
    _nearbyScroll.dispose();
    _needsHelpScroll.dispose();
    super.dispose();
  }

  void _maybeLoadMore(ScrollController controller, DiscoverTab tab) {
    if (!controller.hasClients) return;
    if (controller.position.pixels <
        controller.position.maxScrollExtent - 200) {
      return;
    }
    if (tab == DiscoverTab.nearby) {
      ref.read(discoverProvider.notifier).loadMoreNearby();
    } else {
      ref.read(discoverProvider.notifier).loadMoreNeedsHelp();
    }
  }

  void _loadSelectedTabIfNeeded() {
    switch (ref.read(discoverProvider).selectedTab) {
      case DiscoverTab.nearby:
        ref.read(discoverProvider.notifier).ensureNearbyLoaded();
      case DiscoverTab.needsHelp:
        ref.read(discoverProvider.notifier).ensureNeedsHelpLoaded();
      case DiscoverTab.following:
        _loadFollowingIfAuthenticated();
    }
  }

  void _loadFollowingIfAuthenticated() {
    final state = ref.read(discoverProvider).following;
    if (ref.read(sessionIdentityServiceProvider).cached != null &&
        !state.hasLoadedOnce &&
        !state.isLoading) {
      ref.read(discoverProvider.notifier).loadFollowing();
    }
  }

  void _selectTab(DiscoverTab tab) {
    ref.read(discoverProvider.notifier).selectTab(tab);
    switch (tab) {
      case DiscoverTab.nearby:
        ref.read(discoverProvider.notifier).ensureNearbyLoaded();
      case DiscoverTab.needsHelp:
        ref.read(discoverProvider.notifier).ensureNeedsHelpLoaded();
      case DiscoverTab.following:
        _loadFollowingIfAuthenticated();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(discoverProvider);

    // DiscoverScreen lives in a persistent StatefulShellRoute branch
    // (app_shell.dart): its State survives tab switches and a push/pop to
    // cat-detail, which is exactly what keeps the selected segmented-control
    // tab intact when the user returns from a cat. This listener only
    // catches the following tab's session settling after mount (a cold
    // start, or logging in while already on this tab) — mirrors
    // ProfileScreen/the original DiscoverScreen's identical fix.
    ref.listen(sessionProvider, (previous, next) {
      if (next.value != null) _loadFollowingIfAuthenticated();
    });

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: const Text('Keşfet'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.s5,
                AppSpacing.s3,
                AppSpacing.s5,
                AppSpacing.s2,
              ),
              child: _DiscoverSegmentedControl(
                selected: state.selectedTab,
                onSelect: _selectTab,
              ),
            ),
            Expanded(
              child: switch (state.selectedTab) {
                DiscoverTab.nearby => _LocationTabBody(
                  tab: DiscoverTab.nearby,
                  state: state.nearby,
                  scrollController: _nearbyScroll,
                ),
                DiscoverTab.needsHelp => _LocationTabBody(
                  tab: DiscoverTab.needsHelp,
                  state: state.needsHelp,
                  scrollController: _needsHelpScroll,
                ),
                DiscoverTab.following => _FollowingTabBody(
                  state: state.following,
                ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscoverSegmentedControl extends StatelessWidget {
  const _DiscoverSegmentedControl({
    required this.selected,
    required this.onSelect,
  });

  final DiscoverTab selected;
  final ValueChanged<DiscoverTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _SegmentButton(
            label: 'Yakınımda',
            isOn: selected == DiscoverTab.nearby,
            onTap: () => onSelect(DiscoverTab.nearby),
          ),
        ),
        Expanded(
          child: _SegmentButton(
            label: 'Yardım gerekiyor',
            isOn: selected == DiscoverTab.needsHelp,
            onTap: () => onSelect(DiscoverTab.needsHelp),
          ),
        ),
        Expanded(
          child: _SegmentButton(
            label: 'Takip ettiklerim',
            isOn: selected == DiscoverTab.following,
            onTap: () => onSelect(DiscoverTab.following),
          ),
        ),
      ],
    );
  }
}

class _SegmentButton extends StatelessWidget {
  const _SegmentButton({
    required this.label,
    required this.isOn,
    required this.onTap,
  });

  final String label;
  final bool isOn;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isOn ? AppColors.primarySoft : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Container(
          height: kTapMin,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: isOn ? AppColors.primaryStrong : AppColors.muted,
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared body for the two location-aware tabs — resolves down to one of:
/// full-screen loading, a recoverable location-trouble state (permission
/// denied/denied forever/service disabled/unavailable), a generic
/// error-retry, an empty state, or the paginated cat list.
class _LocationTabBody extends ConsumerWidget {
  const _LocationTabBody({
    required this.tab,
    required this.state,
    required this.scrollController,
  });

  final DiscoverTab tab;
  final DiscoverLocationTabState state;
  final ScrollController scrollController;

  bool get _isNearby => tab == DiscoverTab.nearby;

  void _retry(WidgetRef ref) {
    if (_isNearby) {
      ref.read(discoverProvider.notifier).retryNearby();
    } else {
      ref.read(discoverProvider.notifier).retryNeedsHelp();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.isLoading && !state.hasLoadedOnce) {
      return const Center(child: CircularProgressIndicator());
    }

    final outcome = state.locationOutcome;
    if (outcome != null && outcome is! DiscoverLocationResolved) {
      return _LocationTrouble(outcome: outcome, onRetry: () => _retry(ref));
    }

    if (state.error != null && state.cats.isEmpty) {
      return _ErrorRetry(onRetry: () => _retry(ref));
    }

    if (state.cats.isEmpty) {
      return _EmptyDiscoverList(tab: tab);
    }

    return ListView.separated(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s5),
      itemCount: state.cats.length + (state.hasMore ? 1 : 0),
      separatorBuilder: (_, _) =>
          const Divider(height: 1, color: AppColors.line),
      itemBuilder: (context, index) {
        if (index >= state.cats.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.s4),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final cat = state.cats[index];
        return _DiscoverCatRow(
          id: cat.id,
          name: cat.name,
          primaryPhoto: cat.primaryPhoto,
          areaLabel: cat.areaLabel,
          activeAlert: cat.activeAlert,
          lastUpdateAt: cat.lastUpdateAt,
          distanceMeters: cat.distanceMeters,
        );
      },
    );
  }
}

/// The recoverable location states issue #82 requires explicitly: denied
/// (ask again may work), denied forever (only the system settings can
/// help), service disabled (device gps is off), or a plain
/// unavailable/timeout. Losing location must never break the following
/// tab — this widget only ever renders inside a location-aware tab's own
/// body, never affecting `following`.
class _LocationTrouble extends StatelessWidget {
  const _LocationTrouble({required this.outcome, required this.onRetry});

  final DiscoverLocationOutcome outcome;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final (title, body) = switch (outcome) {
      DiscoverLocationPermissionDeniedForever() => (
        'Konum izni kapalı',
        'Yakındaki ve yardım bekleyen kedileri görmek için ayarlardan konum iznini açman gerekir.',
      ),
      DiscoverLocationPermissionDenied() => (
        'Konum izni gerekli',
        'Yakındaki ve yardım bekleyen kedileri mesafeye göre gösterebilmemiz için konumuna ihtiyacımız var.',
      ),
      DiscoverLocationServiceDisabled() => (
        'Konum servisleri kapalı',
        'Cihazının konum servislerini açtıktan sonra tekrar dene.',
      ),
      _ => (
        'Konum alınamadı',
        'Konumun alınırken bir sorun oluştu. Tekrar dener misin?',
      ),
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.location_off_outlined,
              size: 40,
              color: AppColors.faint,
            ),
            const SizedBox(height: AppSpacing.s3),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.s2),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted, height: 1.5),
            ),
            const SizedBox(height: AppSpacing.s5),
            if (outcome is DiscoverLocationPermissionDeniedForever)
              OutlinedButton(
                onPressed: Geolocator.openAppSettings,
                child: const Text('Ayarları aç'),
              )
            else if (outcome is DiscoverLocationServiceDisabled)
              OutlinedButton(
                onPressed: Geolocator.openLocationSettings,
                child: const Text('Konum ayarlarını aç'),
              ),
            const SizedBox(height: AppSpacing.s2),
            ElevatedButton(
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.primaryInk,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
              ),
              child: const Text('Tekrar dene'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyDiscoverList extends StatelessWidget {
  const _EmptyDiscoverList({required this.tab});

  final DiscoverTab tab;

  @override
  Widget build(BuildContext context) {
    final (icon, title, body) = switch (tab) {
      DiscoverTab.needsHelp => (
        Icons.warning_amber_rounded,
        'Şu an yardım bekleyen kedi yok',
        'Aktif bir yardım bildirimi olduğunda burada görünecek.',
      ),
      _ => (
        Icons.explore_outlined,
        'Yakında kedi bulunamadı',
        'Daha sonra tekrar dene.',
      ),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.faint),
            const SizedBox(height: AppSpacing.s3),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.s2),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _FollowingTabBody extends ConsumerWidget {
  const _FollowingTabBody({required this.state});

  final DiscoverFollowingTabState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAuthenticated = ref.watch(sessionProvider).value != null;
    if (!isAuthenticated) return const _GuestFollowingBody();

    if (state.isLoading && !state.hasLoadedOnce) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.cats.isEmpty) {
      return _ErrorRetry(
        onRetry: () => ref.read(discoverProvider.notifier).loadFollowing(),
      );
    }
    if (state.cats.isEmpty) {
      return const _EmptyFollows();
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s5),
      itemCount: state.cats.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, color: AppColors.line),
      itemBuilder: (context, index) {
        final cat = state.cats[index];
        return _DiscoverCatRow(
          id: cat.id,
          name: cat.name,
          primaryPhoto: cat.primaryPhoto,
          areaLabel: cat.areaLabel,
          activeAlert: cat.activeAlert,
          lastUpdateAt: cat.lastUpdateAt,
          distanceMeters: null,
        );
      },
    );
  }
}

/// One cat row shared by all three tabs (issue #82's flutter scope: "reuse
/// existing cat cards"). `distanceMeters` is null on the following tab —
/// that tab is account-owned state, not location-aware, and issue #82
/// explicitly requires requesting location only when a location-dependent
/// view needs it, so following's rows never trigger or display it.
class _DiscoverCatRow extends StatelessWidget {
  const _DiscoverCatRow({
    required this.id,
    required this.name,
    required this.primaryPhoto,
    required this.areaLabel,
    required this.activeAlert,
    required this.lastUpdateAt,
    required this.distanceMeters,
  });

  final String id;
  final String name;
  final String primaryPhoto;
  final String? areaLabel;
  final ActiveAlert? activeAlert;
  final DateTime? lastUpdateAt;
  final double? distanceMeters;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => context.push('/cats/$id'),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: AppColors.surfaceAlt,
                backgroundImage: primaryPhoto.isNotEmpty
                    ? CachedNetworkImageProvider(primaryPhoto)
                    : null,
                child: primaryPhoto.isEmpty
                    ? const Icon(Icons.pets, color: AppColors.faint)
                    : null,
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isNotEmpty ? name : 'İsimsiz kedi',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink,
                      ),
                    ),
                    if (areaLabel != null)
                      Text(
                        areaLabel!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.muted,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (activeAlert != null)
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: AppColors.help,
                    )
                  else if (lastUpdateAt != null)
                    Text(
                      relativeTimeTr(lastUpdateAt!),
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.faint,
                      ),
                    ),
                  if (distanceMeters != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      formatDistanceTr(distanceMeters!),
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.faint,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyFollows extends StatelessWidget {
  const _EmptyFollows();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.compass_calibration,
              size: 40,
              color: AppColors.faint,
            ),
            const SizedBox(height: AppSpacing.s3),
            Text(
              'Henüz takip ettiğin kedi yok',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.s2),
            const Text(
              'Bir kedinin detayından takip etmeye başladığında burada listelenir.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _GuestFollowingBody extends ConsumerWidget {
  const _GuestFollowingBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.compass_calibration,
              size: 40,
              color: AppColors.faint,
            ),
            const SizedBox(height: AppSpacing.s3),
            Text(
              'Giriş yapmadın',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.s2),
            const Text(
              'Takip ettiğin kedileri burada görmek için giriş yapman gerekir.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, height: 1.5),
            ),
            const SizedBox(height: AppSpacing.s5),
            SizedBox(
              height: kTapMin,
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => _signIn(context, ref),
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
        ),
      ),
    );
  }

  // Gate-at-intent (auth_gate.dart), the same mechanism FollowButton
  // already reuses: on success, resumes the intent by loading the
  // account's followed cats immediately, rather than relying only on the
  // screen's own session listener.
  void _signIn(BuildContext context, WidgetRef ref) {
    AuthGate.require(
      context,
      ref,
      contextText: 'Takip ettiğin kedileri görmek için giriş yap',
      onAuthenticated: () =>
          ref.read(discoverProvider.notifier).loadFollowing(),
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
