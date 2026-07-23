import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../data/cat_detail.dart';
import 'cat_detail_notifier.dart';

/// Cat-detail view reached by selecting a map marker (docs/product/map.md):
/// identity, location, traits, and newest-first status history. Read-only —
/// posting an update, editing the cat, or needs-help rendering are out of
/// scope for issue #21.
class CatDetailScreen extends ConsumerStatefulWidget {
  const CatDetailScreen({super.key, required this.catId});

  final String catId;

  @override
  ConsumerState<CatDetailScreen> createState() => _CatDetailScreenState();
}

class _CatDetailScreenState extends ConsumerState<CatDetailScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(catDetailProvider(widget.catId).notifier).load(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(catDetailProvider(widget.catId));

    return Scaffold(
      appBar: AppBar(title: Text(state.detail?.name ?? 'cat')),
      body: _buildBody(state),
    );
  }

  Widget _buildBody(CatDetailState state) {
    if (state.notFound) {
      return const _MessageView(
        icon: Icons.search_off,
        message: 'cat not found',
      );
    }
    if (state.error != null) {
      return _MessageView(
        icon: Icons.error_outline,
        message: "couldn't load cat",
        actionLabel: 'retry',
        onAction: () =>
            ref.read(catDetailProvider(widget.catId).notifier).load(),
      );
    }
    if (state.isLoading && !state.hasLoadedOnce) {
      return const Center(child: CircularProgressIndicator());
    }
    final detail = state.detail;
    if (detail == null) {
      return const SizedBox.shrink();
    }
    return _CatDetailBody(detail: detail, state: state);
  }
}

class _CatDetailBody extends ConsumerWidget {
  const _CatDetailBody({required this.detail, required this.state});

  final CatDetail detail;
  final CatDetailState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _CatPhoto(url: detail.primaryPhoto),
        const SizedBox(height: 16),
        Text(detail.name, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Row(
          children: [
            const Icon(Icons.location_on, size: 16, color: AppColors.line),
            const SizedBox(width: 4),
            Text(
              '${detail.lat.toStringAsFixed(4)}, ${detail.lng.toStringAsFixed(4)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        if (detail.traits.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: detail.traits
                .map((t) => Chip(label: Text(t.label)))
                .toList(),
          ),
        ],
        const SizedBox(height: 24),
        Text('update history', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (state.updates.isEmpty)
          const _MessageView(
            icon: Icons.history_toggle_off,
            message: 'no updates yet',
            padded: false,
          )
        else ...[
          for (final update in state.updates) _UpdateTile(update: update),
          if (state.hasNextPage) ...[
            const SizedBox(height: 8),
            Center(
              child: state.isLoadingMore
                  ? const CircularProgressIndicator()
                  : TextButton(
                      onPressed: () => ref
                          .read(catDetailProvider(detail.id).notifier)
                          .loadMoreUpdates(),
                      child: const Text('load more'),
                    ),
            ),
          ],
        ],
      ],
    );
  }
}

class _CatPhoto extends StatelessWidget {
  const _CatPhoto({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(12);
    if (url == null) {
      return ClipRRect(
        borderRadius: radius,
        child: Container(
          height: 220,
          width: double.infinity,
          color: AppColors.paper,
          child: const Icon(Icons.pets, size: 48, color: AppColors.line),
        ),
      );
    }
    return ClipRRect(
      borderRadius: radius,
      child: CachedNetworkImage(
        imageUrl: url!,
        height: 220,
        width: double.infinity,
        fit: BoxFit.cover,
        placeholder: (context, _) => const SizedBox(
          height: 220,
          child: Center(child: CircularProgressIndicator()),
        ),
        errorWidget: (context, _, _) => Container(
          height: 220,
          color: AppColors.paper,
          child: const Icon(Icons.pets, size: 48, color: AppColors.line),
        ),
      ),
    );
  }
}

/// An update's structured statuses and free-text comment are shown as two
/// visually distinct elements (chips vs. italic body text), per issue #21's
/// requirement that the two never blur together.
class _UpdateTile extends StatelessWidget {
  const _UpdateTile({required this.update});

  final CatUpdateEntry update;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _formatTimestamp(update.createdAt),
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: update.statuses
                .map(
                  (status) => Chip(
                    label: Text(status.replaceAll('_', ' ')),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: AppColors.accent.withValues(alpha: 0.15),
                  ),
                )
                .toList(),
          ),
          if (update.comment != null) ...[
            const SizedBox(height: 4),
            Text(
              update.comment!,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic),
            ),
          ],
        ],
      ),
    );
  }

  static String _formatTimestamp(DateTime time) {
    final local = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }
}

class _MessageView extends StatelessWidget {
  const _MessageView({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.padded = true,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool padded;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 40, color: AppColors.line),
        const SizedBox(height: 8),
        Text(message),
        if (actionLabel != null && onAction != null) ...[
          const SizedBox(height: 8),
          TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ],
    );
    if (!padded) return Center(child: content);
    return Center(
      child: Padding(padding: const EdgeInsets.all(24), child: content),
    );
  }
}
