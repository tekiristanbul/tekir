import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../../core/theme/app_theme.dart';
import '../data/add_cat_api.dart';
import 'add_cat_state.dart';

const _initialZoom = 17.0;

/// Cat creation (issue #70): location (with the non-blocking duplicate
/// check) → details (required photo, optional name) → submit, matching the
/// approved prototype's `renderAddLoc`/`openDuplicateModal`/
/// `renderAddDetail` (prototype/app.js) visually and interactionally. Pushed
/// only from behind [AuthGate.require] (see the map screen's add-cat
/// button) — never shown before authentication succeeds.
class AddCatScreen extends ConsumerStatefulWidget {
  const AddCatScreen({super.key});

  @override
  ConsumerState<AddCatScreen> createState() => _AddCatScreenState();
}

class _AddCatScreenState extends ConsumerState<AddCatScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(addCatProvider.notifier).start());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(addCatProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Text(
          state.step == AddCatStep.location ? 'Konumu seç' : 'Kedi ekle',
        ),
        leading: IconButton(
          icon: Icon(
            state.step == AddCatStep.location ? Icons.close : Icons.arrow_back,
          ),
          onPressed: () => state.step == AddCatStep.location
              ? Navigator.of(context).pop()
              : ref.read(addCatProvider.notifier).backToLocation(),
        ),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            switch (state.step) {
              AddCatStep.location => const _LocationStep(),
              AddCatStep.details => const _DetailsStep(),
            },
            if (state.hasDuplicates) const _DuplicateModal(),
          ],
        ),
      ),
    );
  }
}

class _LocationStep extends ConsumerStatefulWidget {
  const _LocationStep();

  @override
  ConsumerState<_LocationStep> createState() => _LocationStepState();
}

class _LocationStepState extends ConsumerState<_LocationStep> {
  GoogleMapController? _controller;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(addCatProvider);
    final center = state.lat != null && state.lng != null
        ? LatLng(state.lat!, state.lng!)
        : null;

    return Column(
      children: [
        Expanded(
          child: center == null
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  alignment: Alignment.center,
                  children: [
                    GoogleMap(
                      initialCameraPosition: CameraPosition(
                        target: center,
                        zoom: _initialZoom,
                      ),
                      myLocationButtonEnabled: false,
                      zoomControlsEnabled: false,
                      mapToolbarEnabled: false,
                      onMapCreated: (controller) => _controller = controller,
                      onCameraMove: (position) => ref
                          .read(addCatProvider.notifier)
                          .setLocation(
                            position.target.latitude,
                            position.target.longitude,
                          ),
                    ),
                    // the pin stays fixed in the center of the screen; the
                    // map moves underneath it (prototype's location-picker).
                    IgnorePointer(
                      child: Icon(
                        Icons.location_on,
                        size: 40,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.s5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: kTapMin,
                child: OutlinedButton.icon(
                  onPressed: () =>
                      ref.read(addCatProvider.notifier).useCurrentLocation(),
                  icon: const Icon(Icons.my_location, size: 17),
                  label: const Text('Mevcut konumu kullan'),
                ),
              ),
              if (state.geoError != null) ...[
                const SizedBox(height: AppSpacing.s2),
                Row(
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 14,
                      color: AppColors.help,
                    ),
                    const SizedBox(width: AppSpacing.s1),
                    Expanded(
                      child: Text(
                        state.geoError!,
                        style: const TextStyle(
                          color: AppColors.help,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: AppSpacing.s3),
              SizedBox(
                height: kTapMin,
                child: ElevatedButton(
                  onPressed: center == null
                      ? null
                      : () =>
                            ref.read(addCatProvider.notifier).confirmLocation(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.primaryInk,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                  child: const Text('Bu konumu kullan'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Non-blocking duplicate-candidate modal (prototype's `openDuplicateModal`,
/// docs/product/cats.md/trust.md): a shortcut to an existing cat, but "yine
/// de ekle" always continues.
class _DuplicateModal extends ConsumerWidget {
  const _DuplicateModal();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final candidates = ref.watch(addCatProvider.select((s) => s.duplicates));

    return PointerInterceptor(
      child: Container(
        color: AppColors.overlay,
        alignment: Alignment.bottomCenter,
        child: Container(
          margin: const EdgeInsets.all(AppSpacing.s4),
          padding: const EdgeInsets.all(AppSpacing.s5),
          decoration: BoxDecoration(
            color: AppColors.bgElevated,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                candidates.length == 1
                    ? 'Bu bölgede zaten kayıtlı bir kedi var. Gördüğün kedi bu mu?'
                    : 'Bu bölgede zaten kayıtlı ${candidates.length} kedi var. Gördüğün kedi bunlardan biri mi?',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.s4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: AppSpacing.s2),
                  itemBuilder: (context, index) =>
                      _DuplicateCandidateTile(candidate: candidates[index]),
                ),
              ),
              const SizedBox(height: AppSpacing.s3),
              SizedBox(
                height: kTapMin,
                child: OutlinedButton(
                  onPressed: () =>
                      ref.read(addCatProvider.notifier).continueAsDifferent(),
                  child: const Text('Hayır, farklı bir kedi — yine de ekle'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DuplicateCandidateTile extends StatelessWidget {
  const _DuplicateCandidateTile({required this.candidate});

  final DuplicateCandidate candidate;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        // "gördüğün kedi bu" — go straight to the existing cat instead of
        // creating a new one; this only ever navigates away, it never
        // itself creates anything.
        Navigator.of(context).pop();
        context.go('/cats/${candidate.id}');
      },
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s2),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: candidate.primaryPhoto.isEmpty
                  ? Container(
                      width: 48,
                      height: 48,
                      color: AppColors.surfaceAlt,
                    )
                  : Image.network(
                      candidate.primaryPhoto,
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        width: 48,
                        height: 48,
                        color: AppColors.surfaceAlt,
                      ),
                    ),
            ),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Text(
                candidate.name.isEmpty ? 'İsimsiz kedi' : candidate.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const Icon(Icons.chevron_right, size: 16),
          ],
        ),
      ),
    );
  }
}

class _DetailsStep extends ConsumerWidget {
  const _DetailsStep();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(addCatProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Fotoğraf (zorunlu)',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          InkWell(
            onTap: () => ref.read(addCatProvider.notifier).pickPhoto(),
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Container(
              height: 150,
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              alignment: Alignment.center,
              child: state.photoBytes == null
                  ? const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.camera_alt,
                          size: 26,
                          color: AppColors.muted,
                        ),
                        SizedBox(height: AppSpacing.s2),
                        Text(
                          'Fotoğraf ekle',
                          style: TextStyle(color: AppColors.muted),
                        ),
                      ],
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      child: Image.memory(
                        state.photoBytes!,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: 150,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: AppSpacing.s5),
          const Text(
            'İsim (opsiyonel)',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          TextField(
            decoration: const InputDecoration(
              hintText: 'Örn. Boncuk, Minnoş…',
              filled: true,
              fillColor: AppColors.surfaceAlt,
              contentPadding: EdgeInsets.all(AppSpacing.s3),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(AppRadius.md)),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: (value) =>
                ref.read(addCatProvider.notifier).setName(value),
          ),
          if (state.error != null) ...[
            const SizedBox(height: AppSpacing.s3),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.s3),
              decoration: BoxDecoration(
                color: AppColors.helpSoft,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: AppColors.help),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 18,
                    color: AppColors.help,
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: Text(
                      addCatErrorMessageTr(state.error!),
                      style: const TextStyle(
                        color: AppColors.helpStrong,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.s6),
          SizedBox(
            height: kTapMin,
            child: ElevatedButton(
              onPressed: state.saving ? null : () => _save(context, ref),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.primaryInk,
                disabledBackgroundColor: AppColors.lineStrong,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                textStyle: const TextStyle(fontWeight: FontWeight.w600),
              ),
              child: state.saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.primaryInk,
                      ),
                    )
                  : Text(state.error != null ? 'Tekrar dene' : 'Kaydet'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save(BuildContext context, WidgetRef ref) async {
    final catId = await ref.read(addCatProvider.notifier).save();
    if (catId == null || !context.mounted) return;
    context.go('/cats/$catId');
  }
}
