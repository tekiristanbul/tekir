import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/states/photo_upload_progress.dart';
import '../../../core/theme/app_theme.dart';
import 'cat_update_composer_notifier.dart';

const _statusLabelsTr = {
  'seen': 'Görüldü',
  'fed': 'Mama verildi',
  'water_provided': 'Su verildi',
};

/// Compact multi-status composition flow (issue #43): cat_detail_screen's
/// single "+ update" primary action opens this over the content instead
/// of navigating to a full screen, matching the map's marker-preview sheet
/// pattern (cat_preview_sheet.dart). Pops `true` on a successful
/// submission so the caller shows the lightweight, non-blocking success
/// toast itself, from a context that outlives this sheet.
///
/// Since issue #102 (the #100 simplified help contract), `yardıma ihtiyacı
/// var` is one of the options here — a single help mark beside the status
/// pills, no categories — per the binding design at
/// docs/design/screens/cat-profile.html (frame C): selecting it reveals
/// the takipçilere-bildirim banner, changes the note field's invitation,
/// and turns the submit action into the help-red `yardım çağrısıyla
/// paylaş`.
class CatUpdateSheet extends ConsumerStatefulWidget {
  const CatUpdateSheet({super.key, required this.catId});

  final String catId;

  @override
  ConsumerState<CatUpdateSheet> createState() => _CatUpdateSheetState();
}

enum _MediaPick { cameraPhoto, cameraVideo, galleryPhoto, galleryVideo }

class _CatUpdateSheetState extends ConsumerState<CatUpdateSheet> {
  final TextEditingController _commentController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // A previous open dismissed without submitting (or a stale error from
    // one) must not leak into this fresh open. A failed optimistic attempt
    // is the exception — reset() keeps that draft, and the field text is
    // restored from it here so the retained comment is actually visible
    // ("data is never lost").
    Future.microtask(() {
      if (!mounted) return;
      ref.read(catUpdateComposerProvider(widget.catId).notifier).reset();
      _commentController.text = ref
          .read(catUpdateComposerProvider(widget.catId))
          .comment;
    });
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final notifier = ref.read(catUpdateComposerProvider(widget.catId).notifier);
    final state = ref.read(catUpdateComposerProvider(widget.catId));
    // An ordinary, media-less submission is optimistic (docs/design/
    // app-states.md, mutation affordances): the sheet closes in the same
    // tap and the entry drops onto the timeline as a pending row while the
    // request runs in the background — the parent screen owns the row and
    // any failure surface. A help-carrying submission stays synchronous
    // here: its note must remain visible in this sheet if it fails, and
    // the active alert only ever renders from the server-confirmed entry.
    // A submission carrying a photo or video (issue #153) stays
    // synchronous too, for the same reason: the upload's own progress and
    // any failure need this sheet to still be open to show them.
    if (!state.needsHelp && state.mediaBytes == null) {
      unawaited(notifier.submit());
      Navigator.of(context).pop(false);
      return;
    }
    final ok = await notifier.submit();
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  /// Offers the four ways to attach media (issue #153's video support):
  /// photo or video, each from the camera or the gallery. A single flat
  /// list rather than a two-step (kind, then source) flow — four options
  /// fit one screen without an extra tap.
  Future<void> _chooseMediaSource() async {
    final choice = await showModalBottomSheet<_MediaPick>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Kameradan fotoğraf çek'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(_MediaPick.cameraPhoto),
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('Kameradan video çek'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(_MediaPick.cameraVideo),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Galeriden fotoğraf seç'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(_MediaPick.galleryPhoto),
            ),
            ListTile(
              leading: const Icon(Icons.video_library),
              title: const Text('Galeriden video seç'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(_MediaPick.galleryVideo),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final notifier = ref.read(catUpdateComposerProvider(widget.catId).notifier);
    switch (choice) {
      case _MediaPick.cameraPhoto:
        await notifier.pickPhoto(ImageSource.camera);
      case _MediaPick.cameraVideo:
        await notifier.pickVideo(ImageSource.camera);
      case _MediaPick.galleryPhoto:
        await notifier.pickPhoto(ImageSource.gallery);
      case _MediaPick.galleryVideo:
        await notifier.pickVideo(ImageSource.gallery);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(catUpdateComposerProvider(widget.catId));

    return Padding(
      // Keeps the comment field and submit button above the keyboard.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.bgElevated,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.xl),
          ),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s5,
              AppSpacing.s2,
              AppSpacing.s5,
              AppSpacing.s5,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: _DragHandle()),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Güncelleme ekle',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      icon: const Icon(Icons.close),
                      tooltip: 'Kapat',
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.s1),
                const Text(
                  'Durumu seç',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: AppSpacing.s2),
                Wrap(
                  spacing: AppSpacing.s2,
                  runSpacing: AppSpacing.s2,
                  children: [
                    ...catUpdateStatusOptions.map((status) {
                      return _StatusOption(
                        label: _statusLabelsTr[status]!,
                        selected: state.selectedStatuses.contains(status),
                        onTap: () => ref
                            .read(
                              catUpdateComposerProvider(widget.catId).notifier,
                            )
                            .toggleStatus(status),
                      );
                    }),
                    _HelpOption(
                      selected: state.needsHelp,
                      onTap: () => ref
                          .read(
                            catUpdateComposerProvider(widget.catId).notifier,
                          )
                          .toggleNeedsHelp(),
                    ),
                  ],
                ),
                if (state.needsHelp) ...[
                  const SizedBox(height: AppSpacing.s3),
                  const _HelpNotifyBanner(),
                ],
                const SizedBox(height: AppSpacing.s4),
                const Text(
                  'Fotoğraf / video (opsiyonel)',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: AppSpacing.s2),
                _MediaPicker(
                  mediaBytes: state.mediaBytes,
                  isVideo: state.isVideoMedia,
                  uploading: state.isSubmitting,
                  uploadProgress: state.uploadProgress,
                  onPick: state.isSubmitting ? null : _chooseMediaSource,
                  onRemove: state.isSubmitting
                      ? null
                      : () => ref
                            .read(
                              catUpdateComposerProvider(widget.catId).notifier,
                            )
                            .removeMedia(),
                ),
                const SizedBox(height: AppSpacing.s4),
                const Text(
                  'Yorum (opsiyonel)',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: AppSpacing.s2),
                TextField(
                  controller: _commentController,
                  enabled: !state.isSubmitting,
                  minLines: 2,
                  maxLines: 4,
                  // The 500-character cap applies to the help note only
                  // (docs/product/alerts.md, decision 4) — an ordinary
                  // comment stays uncapped.
                  maxLength: state.needsHelp ? helpNoteMaxLength : null,
                  onChanged: (value) => ref
                      .read(catUpdateComposerProvider(widget.catId).notifier)
                      .setComment(value),
                  decoration: InputDecoration(
                    hintText: state.needsHelp
                        ? 'ne oldu? kısaca yaz — yardıma gelen anlasın'
                        : 'Bir not ekle',
                    filled: true,
                    fillColor: AppColors.surfaceAlt,
                    contentPadding: const EdgeInsets.all(AppSpacing.s3),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                if (state.error != null) ...[
                  const SizedBox(height: AppSpacing.s3),
                  _ErrorBanner(
                    message: updateSubmitErrorMessageTr(state.error!),
                  ),
                ],
                const SizedBox(height: AppSpacing.s4),
                SizedBox(
                  height: kTapMin,
                  child: ElevatedButton(
                    onPressed: state.canSubmit ? _submit : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: state.needsHelp
                          ? AppColors.helpStrong
                          : AppColors.primary,
                      foregroundColor: state.needsHelp
                          ? AppColors.helpInk
                          : AppColors.primaryInk,
                      disabledBackgroundColor: AppColors.lineStrong,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      textStyle: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    child: state.isSubmitting
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: state.needsHelp
                                  ? AppColors.helpInk
                                  : AppColors.primaryInk,
                            ),
                          )
                        : Text(
                            state.error != null
                                ? 'Tekrar dene'
                                : state.needsHelp
                                ? 'yardım çağrısıyla paylaş'
                                : 'Paylaş',
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 4,
      margin: const EdgeInsets.only(bottom: AppSpacing.s3),
      decoration: BoxDecoration(
        color: AppColors.lineStrong,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
    );
  }
}

/// A toggleable status pill — same bold-pill visual language as the
/// timeline's read-only _StatusTag (cat_detail_screen.dart), but
/// interactive and sized to the 44px minimum touch target.
class _StatusOption extends StatelessWidget {
  const _StatusOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.primarySoft : AppColors.surfaceAlt,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.full),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: kTapMin),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                const Icon(
                  Icons.check,
                  size: 16,
                  color: AppColors.primaryStrong,
                ),
                const SizedBox(width: AppSpacing.s1),
              ],
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: selected ? AppColors.primaryStrong : AppColors.muted,
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

/// The single `yardım` mark (binding copy, docs/design/screens/
/// cat-profile.html) — the help color family, never the primary accent,
/// in both states so it always reads apart from the work-done statuses
/// beside it: soft help tint unselected, deep help red selected.
class _HelpOption extends StatelessWidget {
  const _HelpOption({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.helpStrong : AppColors.helpSoft,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.full),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: kTapMin),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: selected ? AppColors.helpInk : AppColors.helpStrong,
              ),
              const SizedBox(width: AppSpacing.s1),
              Flexible(
                child: Text(
                  'yardım',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: selected ? AppColors.helpInk : AppColors.helpStrong,
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

/// The sheet's optional photo/video attachment (issue #153; video support
/// added later in the same issue): an empty tappable well that opens the
/// camera/gallery choice, or the picked media itself with a remove badge
/// and — while [uploading] — the same upload-percentage overlay
/// [AddCatScreen] uses for a new cat's required photo. Tapping the picked
/// media re-opens the camera/gallery choice, doubling as "replace".
///
/// A picked video is never decoded into a preview frame here — that would
/// need a raw file path, which this app avoids for flutter web
/// compatibility (mirrors the photo path's own `XFile.readAsBytes`
/// approach). Instead it shows a fixed video glyph card; the real
/// playback preview is the uploaded copy the timeline renders once posted.
class _MediaPicker extends StatelessWidget {
  const _MediaPicker({
    required this.mediaBytes,
    required this.isVideo,
    required this.uploading,
    required this.uploadProgress,
    required this.onPick,
    required this.onRemove,
  });

  final Uint8List? mediaBytes;
  final bool isVideo;
  final bool uploading;
  final double? uploadProgress;
  final VoidCallback? onPick;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final bytes = mediaBytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        onTap: onPick,
        child: Container(
          height: 96,
          width: 96,
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          alignment: Alignment.center,
          child: bytes == null
              ? const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.camera_alt, size: 22, color: AppColors.muted),
                    SizedBox(height: AppSpacing.s1),
                    Text(
                      'Ekle',
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                  ],
                )
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    if (isVideo)
                      const ColoredBox(
                        color: AppColors.bgElevated,
                        child: Center(
                          key: Key('pickedVideoPreview'),
                          child: Icon(
                            Icons.play_circle_fill,
                            size: 36,
                            color: AppColors.muted,
                          ),
                        ),
                      )
                    else
                      Image.memory(bytes, fit: BoxFit.cover),
                    if (uploading && uploadProgress != null)
                      PhotoUploadProgress(progress: uploadProgress!),
                    if (!uploading && onRemove != null)
                      Positioned(
                        right: 4,
                        top: 4,
                        child: GestureDetector(
                          key: const Key('removePhotoButton'),
                          onTap: onRemove,
                          child: const DecoratedBox(
                            decoration: BoxDecoration(
                              color: AppColors.overlay,
                              shape: BoxShape.circle,
                            ),
                            child: Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(
                                Icons.close,
                                size: 16,
                                color: AppColors.primaryInk,
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

/// Shown only while the help mark is selected: submitting will notify the
/// cat's followers (binding copy). The dot pulses to carry the "this goes
/// out" weight — statically rendered when the platform asks for reduced
/// motion.
class _HelpNotifyBanner extends StatelessWidget {
  const _HelpNotifyBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s3,
      ),
      decoration: BoxDecoration(
        color: AppColors.helpSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: const Row(
        children: [
          _PulsingDot(),
          SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text(
              'takipçilere bildirim gider',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.helpStrong,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  bool _reduceMotion = false;

  // Reduced motion: a static dot, no repeating animation at all. Reading
  // MediaQuery here (not in build) both subscribes to changes and keeps
  // build side-effect free — this reruns whenever disableAnimations
  // flips, so the controller's lifecycle follows the platform setting.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.of(context).disableAnimations;
    if (_reduceMotion) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const dot = DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.helpStrong,
        shape: BoxShape.circle,
      ),
      child: SizedBox(width: 8, height: 8),
    );
    if (_reduceMotion) return dot;

    return SizedBox(
      width: 8,
      height: 8,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = Curves.easeOut.transform(_controller.value);
              return Transform.scale(
                scale: 0.4 + t * 2.4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.help.withValues(alpha: (1 - t) * 0.5),
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox(width: 8, height: 8),
                ),
              );
            },
          ),
          dot,
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: AppSpacing.s3,
      ),
      decoration: BoxDecoration(
        color: AppColors.helpSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.help),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: AppColors.help),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppColors.helpStrong, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
