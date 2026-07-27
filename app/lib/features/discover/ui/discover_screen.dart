import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/identity/session_identity.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/relative_time.dart';
import '../../map/data/cat_marker.dart';
import 'discover_notifier.dart';

/// Keşfet (issue #80 product-owner review, finding 2): a minimal tab for
/// information-architecture parity with the approved prototype
/// (prototype/app.js's bottomNav 'discover' entry) — shows only the
/// authenticated account's followed cats. The prototype's full nearby /
/// needs-help segmented tabs are deliberately not built here; a short note
/// says they're coming, rather than faking them with static/empty content.
class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (ref.read(sessionIdentityServiceProvider).cached != null) {
        ref.read(discoverProvider.notifier).load();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(discoverProvider);
    final isAuthenticated = ref.watch(sessionProvider).value != null;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: const Text('Keşfet'),
      ),
      body: SafeArea(
        child: isAuthenticated ? _authenticatedBody(state) : const _GuestBody(),
      ),
    );
  }

  Widget _authenticatedBody(DiscoverState state) {
    if (state.isLoading && !state.hasLoadedOnce) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.cats.isEmpty) {
      return _ErrorRetry(
        onRetry: () => ref.read(discoverProvider.notifier).load(),
      );
    }
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.s5,
            AppSpacing.s3,
            AppSpacing.s5,
            AppSpacing.s2,
          ),
          child: _ComingSoonNote(),
        ),
        Expanded(
          child: state.cats.isEmpty
              ? const _EmptyFollows()
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s5,
                  ),
                  itemCount: state.cats.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: AppColors.line),
                  itemBuilder: (context, index) =>
                      _FollowedCatRow(cat: state.cats[index]),
                ),
        ),
      ],
    );
  }
}

class _ComingSoonNote extends StatelessWidget {
  const _ComingSoonNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: const Text(
        'Yakınımda ve Yardım gerekiyor sekmeleri yakında.',
        style: TextStyle(color: AppColors.muted, fontSize: 13),
      ),
    );
  }
}

class _FollowedCatRow extends StatelessWidget {
  const _FollowedCatRow({required this.cat});

  final CatMarker cat;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => context.push('/cats/${cat.id}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: AppColors.surfaceAlt,
                backgroundImage: cat.primaryPhoto.isNotEmpty
                    ? NetworkImage(cat.primaryPhoto)
                    : null,
                child: cat.primaryPhoto.isEmpty
                    ? const Icon(Icons.pets, color: AppColors.faint)
                    : null,
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cat.name.isNotEmpty ? cat.name : 'İsimsiz kedi',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink,
                      ),
                    ),
                    if (cat.areaLabel != null)
                      Text(
                        cat.areaLabel!,
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
              if (cat.needsHelp)
                const Icon(Icons.warning_amber_rounded, color: AppColors.help)
              else if (cat.lastUpdateAt != null)
                Text(
                  relativeTimeTr(cat.lastUpdateAt!),
                  style: const TextStyle(fontSize: 11, color: AppColors.faint),
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

class _GuestBody extends StatelessWidget {
  const _GuestBody();

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
        ),
      ),
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
