import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../../core/geo/istanbul_bounds.dart';
import '../../../core/states/photo_upload_progress.dart';
import '../../../core/states/submitting_button.dart';
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
  int? _lastAnimatedRevision;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  // Moves the camera when lat/lng changed because device location was
  // (re-)resolved (locationRevision incremented) rather than because the
  // user panned the map themselves (setLocation never bumps it) — panning
  // must never fight the user's own gesture. `initialCameraPosition` is
  // only honored once by GoogleMap, so an explicit "use current location"
  // tap needs this to actually move the pin.
  void _syncCameraToResolvedLocation(AddCatState state) {
    final controller = _controller;
    if (controller == null) return;
    if (state.lat == null || state.lng == null) return;
    if (state.locationRevision == _lastAnimatedRevision) return;
    _lastAnimatedRevision = state.locationRevision;
    controller.animateCamera(
      CameraUpdate.newLatLng(LatLng(state.lat!, state.lng!)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(addCatProvider);
    ref.listen(
      addCatProvider,
      (_, next) => _syncCameraToResolvedLocation(next),
    );
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
                      cameraTargetBounds: CameraTargetBounds(istanbulBounds),
                      minMaxZoomPreference: const MinMaxZoomPreference(
                        istanbulMinZoom,
                        istanbulMaxZoom,
                      ),
                      myLocationButtonEnabled: false,
                      zoomControlsEnabled: false,
                      mapToolbarEnabled: false,
                      onMapCreated: (controller) {
                        _controller = controller;
                        _lastAnimatedRevision = state.locationRevision;
                      },
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
        // creating a new one. The modal is a state-driven overlay atop
        // /add-cat (AddCatScreen.build's `if (state.hasDuplicates)`), never
        // a pushed route/dialog — there is nothing to pop; popping the
        // Navigator here would instead close /add-cat itself.
        context.go('/cats/${candidate.id}');
      },
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s2),
        child: Row(
          children: [
            // The design's `.dup-candidate__photo`: a 44px circle, not a
            // rounded square.
            ClipOval(
              child: candidate.primaryPhoto.isEmpty
                  ? Container(
                      width: 44,
                      height: 44,
                      color: AppColors.surfaceAlt,
                    )
                  : CachedNetworkImage(
                      imageUrl: candidate.primaryPhoto,
                      width: 44,
                      height: 44,
                      fit: BoxFit.cover,
                      placeholder: (_, _) => Container(
                        width: 44,
                        height: 44,
                        color: AppColors.surfaceAlt,
                      ),
                      errorWidget: (_, _, _) => Container(
                        width: 44,
                        height: 44,
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
            onTap: () => _choosePhotoSource(context, ref),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              // The design's `.photo-well`: a dashed line-strong outline
              // around the whole well, in both its empty and filled state.
              child: CustomPaint(
                painter: const _DashedBorderPainter(
                  color: AppColors.lineStrong,
                  radius: AppRadius.lg,
                ),
                child: Container(
                  height: 150,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                  ),
                  alignment: Alignment.center,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (state.photoBytes == null)
                        const Center(
                          child: Column(
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
                          ),
                        )
                      else ...[
                        Image.memory(state.photoBytes!, fit: BoxFit.cover),
                        // The only percentage anywhere in the app
                        // (docs/design/app-states.md): the photo leaving
                        // the device.
                        if (state.saving && state.uploadProgress != null)
                          PhotoUploadProgress(progress: state.uploadProgress!),
                        if (!state.saving && state.error == AddCatError.network)
                          const Positioned(
                            left: AppSpacing.s3,
                            bottom: AppSpacing.s3,
                            child: _UploadFailedBadge(),
                          ),
                      ],
                      // The design's `.required-tag`: pinned to the well
                      // itself, regardless of whether a photo is picked
                      // yet — not just the field label's own "(zorunlu)".
                      // Top-left, not bottom-left: the upload-failed badge
                      // also anchors bottom-left and would overlap it.
                      const Positioned(
                        left: AppSpacing.s2,
                        top: AppSpacing.s2,
                        child: _RequiredTag(),
                      ),
                    ],
                  ),
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
          TextFormField(
            // initialValue, not a controller: this widget is recreated
            // from scratch whenever the switch in AddCatScreen.build steps
            // away from and back to the details step (e.g. a
            // duplicate-candidates race sends the user back to the
            // location step) — initialValue is what survives that, reading
            // back whatever was last saved to AddCatState.name.
            initialValue: state.name,
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
          // State 11 presents the transient network failure as the sheet
          // plus the photo badge; the inline banner stays for the
          // user-fixable validation-class failures only.
          if (state.error != null && state.error != AddCatError.network) ...[
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
          SubmittingButton(
            label: state.error != null ? 'Tekrar dene' : 'Kaydet',
            submittingLabel: 'haritaya ekleniyor',
            submitting: state.saving,
            onPressed: () => _save(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _save(BuildContext context, WidgetRef ref) async {
    final catId = await ref.read(addCatProvider.notifier).save();
    if (!context.mounted) return;
    if (catId != null) {
      context.go('/cats/$catId');
      return;
    }
    // State 11 · gönderilemedi (docs/design/app-states.md, slice 5): the
    // transient connection failure gets the contract's failure sheet. The
    // form behind it keeps every entered value; retry reuses the flow's
    // idempotency key. "taslak olarak sakla" and the automatic-retry
    // footer depend on the durable draft queue, which issue #99 keeps out
    // of 0.2 — they are not rendered.
    if (ref.read(addCatProvider).error == AddCatError.network) {
      await _showFailureSheet(context, ref);
    }
  }

  Future<void> _showFailureSheet(BuildContext context, WidgetRef ref) {
    final typedName = ref.read(addCatProvider).name.trim();
    final title = typedName.isEmpty
        ? 'kedi haritaya eklenemedi'
        : '$typedName haritaya eklenemedi';
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s5,
            0,
            AppSpacing.s5,
            AppSpacing.s6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.helpSoft,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: const SizedBox(
                      width: kTapMin,
                      height: kTapMin,
                      child: Icon(
                        Icons.warning_amber_rounded,
                        size: 21,
                        color: AppColors.help,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s3 + 2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(sheetContext).textTheme.titleMedium
                              ?.copyWith(fontSize: 20, height: 1.3),
                        ),
                        const SizedBox(height: AppSpacing.s1 + 2),
                        const Text(
                          'fotoğraf yüklenirken bağlantı koptu. '
                          'yazdıkların telefonunda duruyor.',
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.55,
                            color: AppColors.faint,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s5),
              SizedBox(
                height: kTapMin,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    _save(context, ref);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.primaryInk,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    textStyle: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('tekrar dene'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // "capture/selection" (docs/architecture/flutter.md) — a contributor can
  // photograph a street cat on the spot, not just pick an existing photo.
  Future<void> _choosePhotoSource(BuildContext context, WidgetRef ref) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Kameradan çek'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Galeriden seç'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !context.mounted) return;
    await ref.read(addCatProvider.notifier).pickPhoto(source);
  }
}

/// State 11's photo badge (docs/design/app-states.md): sits on the picked
/// photo after a failed submission — the photo itself is retained, only
/// its upload didn't happen.
class _UploadFailedBadge extends StatelessWidget {
  const _UploadFailedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.help.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, size: 12, color: Colors.white),
          SizedBox(width: 7),
          Text(
            'yüklenemedi',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// The design's `.photo-well .required-tag`: a small pill fixed to the
/// well's corner, present whether or not a photo has been picked yet.
class _RequiredTag extends StatelessWidget {
  const _RequiredTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        border: Border.all(color: AppColors.lineStrong),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: const Text(
        'zorunlu',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: AppColors.muted,
        ),
      ),
    );
  }
}

/// Draws the design's dashed outline (`.photo-well`'s `border:1.5px dashed`)
/// around a rounded rectangle — Flutter has no built-in dashed
/// `BoxDecoration` border, so this paints one directly.
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  static const _dashWidth = 5.0;
  static const _dashGap = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.75, 0.75, size.width - 1.5, size.height - 1.5),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = distance + _dashWidth;
        canvas.drawPath(
          metric.extractPath(distance, next.clamp(0, metric.length)),
          paint,
        );
        distance = next + _dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
