import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../../core/theme/app_theme.dart';
import 'spike.dart';

/// The reviewer's control for issue #280: move between the three concepts
/// and the shipped behaviour without a rebuild.
///
/// Developer chrome, not product surface. It exists only in a build given
/// `--dart-define=MAP_SPIKE=...`, it is not a navigation control — every
/// option renders the same map, at the same route, with one interaction
/// rule swapped — and it is deleted with the rest of this directory.
///
/// Drawn as a plain strip on the map's own surface rather than a floating
/// pill, so it stays visually subordinate to the map and never becomes a
/// thing being evaluated alongside the concepts.
class MapSpikeSwitcher extends ConsumerWidget {
  const MapSpikeSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(mapSpikeProvider);
    return PointerInterceptor(
      child: Material(
        color: AppColors.surface,
        child: Container(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.lineStrong)),
          ),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).padding.bottom,
          ),
          child: Row(
            children: [
              for (final concept in MapSpikeConcept.values)
                Expanded(
                  child: InkWell(
                    onTap: () =>
                        ref.read(mapSpikeProvider.notifier).select(concept),
                    child: Container(
                      height: kTapMin,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            width: 2,
                            color: concept == active
                                ? AppColors.primary
                                : Colors.transparent,
                          ),
                        ),
                      ),
                      child: Text(
                        concept.label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: concept == active
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: concept == active
                              ? AppColors.primaryStrong
                              : AppColors.muted,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
