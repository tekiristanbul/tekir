import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/analytics/analytics.dart';
import '../../../core/identity/session_identity.dart';
import '../../../core/motion/press_response.dart';
import '../../../core/motion/tekir_motion.dart';
import '../../../core/states/fallback_location_note.dart';
import '../../../core/states/initial_read_gate.dart';
import '../../../core/states/inline_spinner.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/distance_format.dart';
import '../../../core/utils/relative_time.dart';
import '../../auth/ui/auth_gate.dart';
import '../../map/data/cat_marker.dart';
import '../data/discover_location_service.dart';
import 'discover_notifier.dart';
import 'discover_skeleton.dart';

/// How long the field waits after the last keystroke before searching.
/// Long enough that typing a name is one request rather than six, short
/// enough that the list feels like it is following the typing.
const _searchDebounce = Duration(milliseconds: 300);

/// Cat search (issue #284, approved design artboard 03) — the surface the
/// map's top-strip search pill opens.
///
/// This is the keşfet screen's three approved surfaces (docs/product/
/// discovery.md) re-presented as one panel with three chips, plus search by
/// the cat's own name. It replaces `/discover` as a destination: the tab bar
/// it used to live behind is gone, and a list of cats is something you reach
/// while looking at the map, not a place you navigate to.
///
/// Picking a row does not open cat detail. It closes the panel and hands the
/// cat back to the map, which selects it — which is why [DiscoverCat] now
/// carries coordinates.
class CatSearchPanel extends ConsumerStatefulWidget {
  const CatSearchPanel({super.key});

  /// Opens the panel over the current route and completes with the cat the
  /// user picked, or null if they dismissed it.
  ///
  /// A real route rather than an overlay: the panel has a text field, so it
  /// needs the focus scope, the back gesture and the keyboard handling a
  /// route already gives it for free.
  static Future<CatMarker?> push(BuildContext context) {
    return Navigator.of(context, rootNavigator: true).push<CatMarker>(
      PageRouteBuilder<CatMarker>(
        opaque: false,
        barrierColor: null,
        transitionDuration: TekirMotion.of(context)(TekirMotion.surface),
        reverseTransitionDuration: TekirMotion.of(context)(TekirMotion.state),
        pageBuilder: (context, animation, secondaryAnimation) =>
            const CatSearchPanel(),
        transitionsBuilder: (context, animation, secondary, child) {
          // The panel comes up from the search pill it was opened from, so
          // it reads as that control expanding rather than as an unrelated
          // screen arriving. Under reduced motion the duration is already
          // zero, which leaves the fade and drops the travel.
          final curved = CurvedAnimation(
            parent: animation,
            curve: TekirMotion.enter,
            reverseCurve: TekirMotion.exit,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, -0.04),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  @override
  ConsumerState<CatSearchPanel> createState() => _CatSearchPanelState();
}

class _CatSearchPanelState extends ConsumerState<CatSearchPanel> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _scroll = ScrollController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    // The panel is the discover surface now, so it emits the same
    // screen_view the `/discover` route used to (issue #84's vocabulary is
    // unchanged — only what presents the surface moved).
    Future.microtask(() {
      if (!mounted) return;
      ref
          .read(analyticsProvider)
          .log(AnalyticsEvent.screenView(AnalyticsScreen.discover));
      _controller.text = ref.read(discoverProvider).query;
      _loadSelectedIfNeeded();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 200) {
      return;
    }
    switch (ref.read(discoverProvider).selectedTab) {
      case DiscoverTab.nearby:
        ref.read(discoverProvider.notifier).loadMoreNearby();
      case DiscoverTab.needsHelp:
        ref.read(discoverProvider.notifier).loadMoreNeedsHelp();
      case DiscoverTab.following:
        break;
    }
  }

  void _loadSelectedIfNeeded() {
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
    _loadSelectedIfNeeded();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_searchDebounce, () {
      if (!mounted) return;
      unawaited(ref.read(discoverProvider.notifier).setQuery(value));
    });
    // Rebuild now so the clear affordance appears with the first character
    // rather than after the debounce.
    setState(() {});
  }

  void _clearQuery() {
    _debounce?.cancel();
    _controller.clear();
    unawaited(ref.read(discoverProvider.notifier).setQuery(''));
    setState(() {});
  }

  void _pick(CatMarker cat) {
    Navigator.of(context).pop(cat);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(discoverProvider);

    ref.listen(sessionProvider, (previous, next) {
      if (next.value != null) _loadFollowingIfAuthenticated();
    });

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _SearchHeader(
              controller: _controller,
              focusNode: _focusNode,
              onChanged: _onQueryChanged,
              onClear: _controller.text.isEmpty ? null : _clearQuery,
              onCancel: () => Navigator.of(context).pop(),
            ),
            _ChipRow(
              selected: state.selectedTab,
              needsHelpCount: state.needsHelp.hasLoadedOnce
                  ? state.needsHelp.cats.length
                  : null,
              followingCount: state.following.hasLoadedOnce
                  ? state.filteredFollowing.length
                  : null,
              onSelect: _selectTab,
            ),
            Expanded(
              child: switch (state.selectedTab) {
                DiscoverTab.nearby => _LocationResults(
                  tab: DiscoverTab.nearby,
                  state: state.nearby,
                  query: state.query,
                  scrollController: _scroll,
                  onPick: _pick,
                ),
                DiscoverTab.needsHelp => _LocationResults(
                  tab: DiscoverTab.needsHelp,
                  state: state.needsHelp,
                  query: state.query,
                  scrollController: _scroll,
                  onPick: _pick,
                ),
                DiscoverTab.following => _FollowingResults(
                  state: state.following,
                  cats: state.filteredFollowing,
                  isSearching: state.isSearching,
                  onPick: _pick,
                  onBrowseNearby: () => _selectTab(DiscoverTab.nearby),
                ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// The panel's own field and its dismissal. The field is real and typeable —
/// unlike the map's decorative one (issue #138), which never was.
class _SearchHeader extends StatelessWidget {
  const _SearchHeader({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClear,
    required this.onCancel,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback? onClear;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s4,
        AppSpacing.s3,
        AppSpacing.s4,
        AppSpacing.s3,
      ),
      child: Row(
        children: [
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(AppRadius.full),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
                child: Row(
                  children: [
                    const Icon(Icons.search, size: 17, color: AppColors.faint),
                    const SizedBox(width: AppSpacing.s2),
                    Expanded(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: kTapMin),
                        child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          autofocus: true,
                          onChanged: onChanged,
                          textInputAction: TextInputAction.search,
                          // Submitting closes the keyboard without closing
                          // the panel: the results are behind the keyboard,
                          // and "done" means "let me look at them".
                          onSubmitted: (_) => focusNode.unfocus(),
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: AppColors.ink,
                          ),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText: 'kedi ara',
                            hintStyle: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppColors.faint,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (onClear != null)
                      Semantics(
                        button: true,
                        label: 'aramayı temizle',
                        child: InkResponse(
                          onTap: onClear,
                          radius: 20,
                          child: const SizedBox(
                            width: 32,
                            height: kTapMin,
                            child: Icon(
                              Icons.close,
                              size: 17,
                              color: AppColors.faint,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.s2),
          Semantics(
            button: true,
            label: 'aramayı kapat',
            child: PressResponse(
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.full),
                onTap: onCancel,
                child: Container(
                  constraints: const BoxConstraints(minHeight: kTapMin),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s2,
                  ),
                  child: const Text(
                    'vazgeç',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.faint,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The approved design's three chips. Same three surfaces the segmented
/// control carried, same analytics vocabulary — a chip row rather than a
/// segmented control because this panel opens over a map, not inside a tab.
class _ChipRow extends StatelessWidget {
  const _ChipRow({
    required this.selected,
    required this.needsHelpCount,
    required this.followingCount,
    required this.onSelect,
  });

  final DiscoverTab selected;
  final int? needsHelpCount;
  final int? followingCount;
  final ValueChanged<DiscoverTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kTapMin + AppSpacing.s2,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
        children: [
          _Chip(
            label: 'yakındakiler',
            isOn: selected == DiscoverTab.nearby,
            onTap: () => onSelect(DiscoverTab.nearby),
          ),
          const SizedBox(width: AppSpacing.s2 - 1),
          _Chip(
            label: 'yardım',
            count: needsHelpCount,
            isOn: selected == DiscoverTab.needsHelp,
            onTap: () => onSelect(DiscoverTab.needsHelp),
          ),
          const SizedBox(width: AppSpacing.s2 - 1),
          _Chip(
            label: 'takip',
            count: followingCount,
            isOn: selected == DiscoverTab.following,
            onTap: () => onSelect(DiscoverTab.following),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.isOn,
    required this.onTap,
    this.count,
  });

  final String label;
  final int? count;
  final bool isOn;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final motion = TekirMotion.of(context);
    final text = count == null ? label : '$label · $count';
    return Semantics(
      container: true,
      excludeSemantics: true,
      button: true,
      selected: isOn,
      label: text,
      onTap: onTap,
      child: PressResponse(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.full),
            onTap: onTap,
            child: Center(
              child: AnimatedContainer(
                duration: motion(TekirMotion.state),
                curve: TekirMotion.enter,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s4 - 2,
                  vertical: AppSpacing.s2,
                ),
                decoration: BoxDecoration(
                  color: isOn ? AppColors.ink : AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: isOn ? AppColors.primaryInk : AppColors.muted,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LocationResults extends ConsumerWidget {
  const _LocationResults({
    required this.tab,
    required this.state,
    required this.query,
    required this.scrollController,
    required this.onPick,
  });

  final DiscoverTab tab;
  final DiscoverLocationTabState state;
  final String query;
  final ScrollController scrollController;
  final ValueChanged<CatMarker> onPick;

  bool get _isNearby => tab == DiscoverTab.nearby;

  void _retry(WidgetRef ref) {
    if (_isNearby) {
      ref.read(discoverProvider.notifier).retryNearby();
    } else {
      ref.read(discoverProvider.notifier).retryNeedsHelp();
    }
  }

  Future<void> _enableLocation(WidgetRef ref) async {
    await ref.read(discoverLocationServiceProvider).recoverPermission();
    _retry(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.isLoading && !state.hasLoadedOnce) {
      return _GatedListSkeleton(onRetry: () => _retry(ref));
    }
    if (state.error != null && state.cats.isEmpty) {
      return _ErrorRetry(onRetry: () => _retry(ref));
    }

    final onFallback = state.usesFallbackLocation;
    final body = state.cats.isEmpty
        ? _EmptyResults(tab: tab, query: query)
        : _buildList(onFallback: onFallback);
    if (!onFallback) return body;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s4,
            0,
            AppSpacing.s4,
            AppSpacing.s3,
          ),
          child: FallbackLocationNote(
            onEnableLocation: () => unawaited(_enableLocation(ref)),
          ),
        ),
        Expanded(child: body),
      ],
    );
  }

  Widget _buildList({required bool onFallback}) {
    return Semantics(
      liveRegion: true,
      label: '${state.cats.length} kedi bulundu',
      child: ListView.separated(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s4,
          0,
          AppSpacing.s4,
          AppSpacing.s6,
        ),
        itemCount: state.cats.length + (state.hasMore ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.s4),
        itemBuilder: (context, index) {
          if (index >= state.cats.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.s4),
              child: Center(
                child: InlineSpinner(
                  size: 20,
                  color: AppColors.primary,
                  trackColor: AppColors.line,
                ),
              ),
            );
          }
          final cat = state.cats[index];
          return CatResultRow(
            name: cat.name,
            primaryPhoto: cat.primaryPhoto,
            areaLabel: cat.areaLabel,
            activeAlert: cat.activeAlert,
            lastUpdateAt: cat.lastUpdateAt,
            // Measured from the istanbul fallback, not from the caller — a
            // number that would read as "distance from you" and be wrong.
            distanceMeters: onFallback ? null : cat.distanceMeters,
            onTap: () => onPick(cat.toCatMarker()),
          );
        },
      ),
    );
  }
}

class _FollowingResults extends ConsumerWidget {
  const _FollowingResults({
    required this.state,
    required this.cats,
    required this.isSearching,
    required this.onPick,
    required this.onBrowseNearby,
  });

  final DiscoverFollowingTabState state;
  final List<CatMarker> cats;
  final bool isSearching;
  final ValueChanged<CatMarker> onPick;
  final VoidCallback onBrowseNearby;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAuthenticated = ref.watch(sessionProvider).value != null;
    if (!isAuthenticated) return const _GuestFollowingBody();

    if (state.isLoading && !state.hasLoadedOnce) {
      return _GatedListSkeleton(
        onRetry: () => ref.read(discoverProvider.notifier).loadFollowing(),
      );
    }
    if (state.error != null && state.cats.isEmpty) {
      return _ErrorRetry(
        onRetry: () => ref.read(discoverProvider.notifier).loadFollowing(),
      );
    }
    if (cats.isEmpty) {
      // A search that matched none of the followed cats is not the same
      // thing as following nobody, and must not offer to fix the wrong
      // problem.
      if (isSearching) {
        return const _EmptyResults(tab: DiscoverTab.following, query: '_');
      }
      return _EmptyFollows(onBrowseNearby: onBrowseNearby);
    }
    return Semantics(
      liveRegion: true,
      label: '${cats.length} kedi bulundu',
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s4,
          0,
          AppSpacing.s4,
          AppSpacing.s6,
        ),
        itemCount: cats.length,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.s4),
        itemBuilder: (context, index) {
          final cat = cats[index];
          return CatResultRow(
            name: cat.name,
            primaryPhoto: cat.primaryPhoto,
            areaLabel: cat.areaLabel,
            activeAlert: cat.activeAlert,
            lastUpdateAt: cat.lastUpdateAt,
            distanceMeters: null,
            onTap: () => onPick(cat),
          );
        },
      ),
    );
  }
}

/// One result row, shared by all three chips (the shape the keşfet screen's
/// own row had, at the approved design's 52px avatar size).
///
/// Tapping it selects the cat on the map — it does not open cat detail, so
/// unlike its predecessor it carries no navigation and no analytics source
/// of its own. The cat_opened event still fires, from the map, when the
/// selection's own sheet leads there.
class CatResultRow extends StatelessWidget {
  const CatResultRow({
    super.key,
    required this.name,
    required this.primaryPhoto,
    required this.areaLabel,
    required this.activeAlert,
    required this.lastUpdateAt,
    required this.distanceMeters,
    required this.onTap,
  });

  final String name;
  final String primaryPhoto;
  final String? areaLabel;
  final ActiveAlert? activeAlert;
  final DateTime? lastUpdateAt;
  final double? distanceMeters;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final displayName = name.isNotEmpty ? name : 'İsimsiz kedi';
    final note = _noteTr();
    return Semantics(
      container: true,
      excludeSemantics: true,
      button: true,
      label: [
        displayName,
        if (distanceMeters != null) formatDistanceTr(distanceMeters!),
        ?note,
      ].join(', '),
      onTap: onTap,
      child: PressResponse(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.md),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
              child: Row(
                children: [
                  _ResultAvatar(
                    url: primaryPhoto,
                    needsHelp: activeAlert != null,
                  ),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Flexible(
                              child: Text(
                                displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(
                                  context,
                                ).textTheme.titleMedium?.copyWith(fontSize: 18),
                              ),
                            ),
                            if (distanceMeters != null) ...[
                              const SizedBox(width: AppSpacing.s2),
                              Text(
                                formatDistanceTr(distanceMeters!),
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.faint,
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (note != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            note,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: activeAlert != null
                                  ? AppColors.helpStrong
                                  : AppColors.muted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  const Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: AppColors.lineStrong,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The row's one line of context, in the approved design's own priority:
  /// an active help call outranks a timestamp, which outranks the area.
  String? _noteTr() {
    final alert = activeAlert;
    if (alert != null) {
      return 'yardım gerekiyor · ${expiresInTr(alert.expiresAt)}';
    }
    if (lastUpdateAt != null) return relativeTimeTr(lastUpdateAt!);
    return areaLabel;
  }
}

class _ResultAvatar extends StatelessWidget {
  const _ResultAvatar({required this.url, required this.needsHelp});

  final String url;
  final bool needsHelp;

  @override
  Widget build(BuildContext context) {
    const size = 52.0;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            backgroundColor: AppColors.surfaceAlt,
            backgroundImage: url.isNotEmpty
                ? CachedNetworkImageProvider(url)
                : null,
            child: url.isEmpty
                ? const Icon(Icons.pets, color: AppColors.faint)
                : null,
          ),
          // The map's own help language: a ring, plus the badge that keeps
          // the state off colour alone.
          if (needsHelp) ...[
            Positioned(
              left: -3,
              top: -3,
              right: -3,
              bottom: -3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.help, width: 2),
                ),
              ),
            ),
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                  color: AppColors.help,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.priority_high,
                  size: 10,
                  color: AppColors.helpInk,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyResults extends StatelessWidget {
  const _EmptyResults({required this.tab, required this.query});

  final DiscoverTab tab;
  final String query;

  @override
  Widget build(BuildContext context) {
    // A search that found nothing is a different message from a surface
    // that is simply empty — the first is answerable by typing something
    // else, the second is not answerable at all.
    final (icon, title, body) = query.isNotEmpty
        ? (
            Icons.search_off,
            'Bu isimde kedi bulunamadı',
            'Yazımı değiştirip tekrar dene.',
          )
        : switch (tab) {
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

/// State 14's gate: the shared 400 ms rule decides when the skeleton may
/// appear at all, so a read finishing inside the window never flashes it
/// (docs/design/app-states.md, timing contract).
class _GatedListSkeleton extends StatefulWidget {
  const _GatedListSkeleton({required this.onRetry});

  final VoidCallback onRetry;

  @override
  State<_GatedListSkeleton> createState() => _GatedListSkeletonState();
}

class _GatedListSkeletonState extends State<_GatedListSkeleton> {
  /// Bumped on retry so the gate remounts and earns a fresh 400 ms of
  /// silence — without it the gate would still be sitting in its timed-out
  /// phase and the skeleton would never come back.
  int _attempt = 0;

  void _retry() {
    setState(() => _attempt++);
    widget.onRetry();
  }

  @override
  Widget build(BuildContext context) {
    return InitialReadGate(
      key: ValueKey(_attempt),
      reading: true,
      builder: (context, phase) {
        if (phase == InitialReadPhase.timedOut) {
          return _ErrorRetry(onRetry: _retry);
        }
        if (phase == InitialReadPhase.hidden) return const SizedBox.shrink();
        return const DiscoverListSkeleton();
      },
    );
  }
}

/// State 08 · takip listesi boş (docs/design/app-states.md): the filter
/// result is empty because the user follows no one — an invitation, not a
/// failure. The chip row above stays visible and tappable, and the single
/// quiet action redirects to the nearby list.
class _EmptyFollows extends StatelessWidget {
  const _EmptyFollows({required this.onBrowseNearby});

  final VoidCallback onBrowseNearby;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.s8,
                AppSpacing.s5,
                AppSpacing.s8,
                AppSpacing.s10,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.surfaceAlt,
                      shape: BoxShape.circle,
                    ),
                    child: SizedBox(
                      width: 88,
                      height: 88,
                      child: Icon(
                        Icons.favorite_border,
                        size: 34,
                        color: AppColors.faint,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s5),
                  Text(
                    'henüz kimseyi takip etmiyorsun',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontSize: 23,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s3),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 280),
                    child: const Text(
                      'bir kedinin sayfasındaki kalbe dokun; ona yardım '
                      'gerektiğinde haberin olsun.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.faint,
                        height: 1.6,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s5),
                  Material(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(18),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: onBrowseNearby,
                      child: Container(
                        constraints: const BoxConstraints(minHeight: kTapMin),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.s4 + 2,
                          vertical: AppSpacing.s3,
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'yakındakilere göz at',
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.muted,
                              ),
                            ),
                            SizedBox(width: AppSpacing.s1),
                            Icon(
                              Icons.chevron_right,
                              size: 16,
                              color: AppColors.faint,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
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
  // already reuses: on success, resumes the intent by loading the account's
  // followed cats immediately, rather than relying only on the panel's own
  // session listener.
  void _signIn(BuildContext context, WidgetRef ref) {
    AuthGate.require(
      context,
      ref,
      contextText: 'Takip ettiğin kedileri görmek için giriş yap',
      intent: AnalyticsAuthIntent.follow,
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
