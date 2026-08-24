import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/theme/app_theme.dart';
import 'marker_tier.dart';

/// google_maps_flutter markers are images, not arbitrary widgets, so every
/// mark on this map — a cat at each of its three resolutions, and the
/// bubble standing in for a group of them — is drawn here and encoded into
/// a [BitmapDescriptor].
///
/// Clustering is ours since issue #285. The sdk's own [ClusterManager]
/// exposes only `clusterManagerId` and `onClusterTap`; the bubble it draws
/// is native, in its own blue and its own type, and cannot be restyled.
/// A cluster is therefore just another marker with a bitmap this class
/// renders, which costs nothing extra and puts the whole map in one visual
/// language.
///
/// Caching matters more than it looks. Every mark is rebuilt whenever the
/// cat list, the selection or the camera's tier changes, so an uncached
/// render would redraw a screenful of bitmaps on every settle. Photos are
/// cached separately from pins, so selecting a cat re-renders one pin
/// without re-fetching its photo; silhouettes, dots and cluster bubbles
/// carry no per-cat content at all and are cached once per variant.
class MarkerBitmapBuilder {
  MarkerBitmapBuilder({Dio? photoClient}) : _photoClient = photoClient ?? Dio();

  /// The approved design's avatar marker: 54pt with a 2.5pt paper contour.
  /// Public because the halo layer's rings start at this marker's own edge
  /// — the two are the same object seen from two layers.
  static const avatarSize = 54.0;
  static const _avatarRing = 2.5;

  /// Keeps the shipped proportion between a resting and a selected pin, so
  /// a selected cat still reads as about a third larger. Public because the
  /// selection halo is drawn as a flutter layer over the map and has to
  /// surround exactly this, not a number that happens to look close.
  static const selectedAvatarSize = 70.0;

  /// The approved design's other two resolutions.
  static const _silhouetteSize = 30.0;
  static const _dotSize = 10.0;

  /// Every bitmap is laid out on a canvas at least this wide, with the
  /// visible mark centred inside it. A marker's tap target is its image, so
  /// a 10pt dot drawn on a 10pt canvas would be a 10pt tap target — an
  /// unhittable one. The transparent margin is what keeps every resolution
  /// at the product's 44pt minimum.
  static const _minCanvas = kTapMin;

  static const _clusterSize = 46.0;

  /// Was 3.0 to stay crisp on high-dpi screens; 2.0 still renders above any
  /// current device's pixel density at these sizes and keeps a screenful of
  /// marks from costing four times the memory.
  static const _renderScale = 2.0;

  final Dio _photoClient;
  final _pinCache = <String, Future<BitmapDescriptor>>{};
  final _photoCache = <String, Future<ui.Image?>>{};

  /// Urls whose image is decoded and in hand. Distinct from [_photoCache],
  /// which holds pending work too — this is what [hasPhoto] answers from
  /// without awaiting anything.
  final _settledPhotos = <String>{};

  /// One cat, at [tier].
  ///
  /// [photoUrl] is ignored for anything but [MarkerTier.avatar] — the
  /// approved design is explicit that no photo request is issued for a cat
  /// drawn as a dot, and the same holds for a silhouette. The caller is
  /// still free to pass the url; not fetching it is decided here, in one
  /// place, rather than at every call site.
  ///
  /// [restingHelpMark] false draws a cat that needs help as if it did not.
  /// That is only ever right when something else is saying so at the same
  /// moment: the halo layer's pulse, which runs on the avatar tier while
  /// the platform allows motion. Where the pulse cannot run — reduced
  /// motion, or a zoom where the cat is a silhouette or a dot — the ring
  /// and the badge are the whole of the mark and stay put. The caller owns
  /// that condition, because the caller is what knows whether a pulse is
  /// being drawn.
  Future<BitmapDescriptor> pin({
    required String cacheKey,
    required String photoUrl,
    required bool needsHelp,
    required MarkerTier tier,
    bool selected = false,
    bool restingHelpMark = true,
  }) {
    // A silhouette and a dot carry nothing of the individual cat, so every
    // cat at that tier shares one bitmap and one cache entry. They also
    // never take a pulse — a screenful of expanding rings at those zooms
    // is weather, not a signal — so they always keep the resting mark and
    // it stays out of their key.
    final key = switch (tier) {
      MarkerTier.avatar =>
        'avatar:$cacheKey:$needsHelp:$selected:$restingHelpMark',
      MarkerTier.silhouette => 'silhouette:$needsHelp:$selected',
      MarkerTier.dot => 'dot:$needsHelp:$selected',
    };
    return _pinCache.putIfAbsent(
      key,
      () => switch (tier) {
        MarkerTier.avatar => _renderAvatar(
          photoUrl: photoUrl,
          needsHelp: needsHelp && restingHelpMark,
          selected: selected,
        ),
        MarkerTier.silhouette => _renderSilhouette(needsHelp: needsHelp),
        MarkerTier.dot => _renderDot(needsHelp: needsHelp),
      },
    );
  }

  /// The bubble standing in for a group of cats.
  ///
  /// Cached per (count, help) pair rather than per group: two groups of
  /// four look the same, and a screenful of clusters costs a handful of
  /// bitmaps rather than one each.
  Future<BitmapDescriptor> cluster({
    required int count,
    required bool containsHelp,
  }) {
    return _pinCache.putIfAbsent(
      'cluster:$count:$containsHelp',
      () => _renderCluster(count: count, containsHelp: containsHelp),
    );
  }

  /// Whether [photoUrl] has already been fetched and decoded.
  ///
  /// Synchronous on purpose: the screen has to decide, while building this
  /// frame's marker set, whether a cat can be drawn as its own face yet or
  /// has to stand in as a silhouette until the photo lands. An answer that
  /// only arrived in a future would be an answer for the next frame.
  ///
  /// A url that failed to fetch never settles: the cat keeps its silhouette
  /// rather than flickering to an empty face.
  bool hasPhoto(String photoUrl) =>
      photoUrl.isEmpty || _settledPhotos.contains(photoUrl);

  /// Fetches and decodes [photoUrl] without rendering anything, completing
  /// with true when the cat can now be drawn as its own face.
  ///
  /// The approved design draws a cat whose avatar has not arrived as a
  /// silhouette and fades the face in when it does — no spinner. The screen
  /// asks for the photo through this and rebuilds when it settles.
  Future<bool> warmPhoto(String photoUrl) async {
    if (photoUrl.isEmpty) return false;
    if (_settledPhotos.contains(photoUrl)) return false;
    final image = await _decodePhoto(photoUrl);
    if (image == null) return false;
    return _settledPhotos.add(photoUrl);
  }

  Future<BitmapDescriptor> _renderAvatar({
    required String photoUrl,
    required bool needsHelp,
    required bool selected,
  }) async {
    final displaySize = selected ? selectedAvatarSize : avatarSize;
    final canvasSize = displaySize;
    final px = (canvasSize * _renderScale).round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(px / 2, px / 2);
    final ringWidth = _avatarRing * _renderScale;
    // The help mark's badge sits half outside the face, so the face itself
    // gives up a little room rather than the badge being clipped.
    final radius = px / 2 - ringWidth - (needsHelp ? 3 * _renderScale : 0);

    final image = await _decodePhoto(photoUrl);
    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: center, radius: radius)),
    );
    if (image != null) {
      paintImage(
        canvas: canvas,
        rect: Rect.fromCircle(center: center, radius: radius),
        image: image,
        fit: BoxFit.cover,
      );
    } else {
      canvas.drawCircle(center, radius, Paint()..color = AppColors.surfaceAlt);
      _drawGlyph(canvas, center, Icons.pets, radius * 0.9, AppColors.faint);
    }
    canvas.restore();

    // The paper contour is the design's own: the face is cut out of the
    // map, not stuck on top of it.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth
        ..color = AppColors.bgElevated,
    );
    if (needsHelp) {
      canvas.drawCircle(
        center,
        radius + ringWidth,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 * _renderScale
          ..color = AppColors.help,
      );
      _drawHelpBadge(canvas, center, radius + ringWidth);
    } else if (selected) {
      canvas.drawCircle(
        center,
        radius + ringWidth,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 * _renderScale
          ..color = AppColors.primaryStrong,
      );
    }

    return _finish(recorder, px, canvasSize);
  }

  Future<BitmapDescriptor> _renderSilhouette({required bool needsHelp}) async {
    const canvasSize = _minCanvas;
    final px = (canvasSize * _renderScale).round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(px / 2, px / 2);
    final radius = _silhouetteSize / 2 * _renderScale;

    canvas.drawCircle(
      center,
      radius,
      Paint()..color = needsHelp ? AppColors.helpSoft : AppColors.surfaceAlt,
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * _renderScale
        ..color = needsHelp ? AppColors.help : AppColors.bgElevated,
    );
    _drawGlyph(
      canvas,
      center,
      Icons.pets,
      radius,
      needsHelp ? AppColors.helpStrong : AppColors.faint,
    );
    if (needsHelp) _drawHelpBadge(canvas, center, radius);

    return _finish(recorder, px, canvasSize);
  }

  Future<BitmapDescriptor> _renderDot({required bool needsHelp}) async {
    const canvasSize = _minCanvas;
    final px = (canvasSize * _renderScale).round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(px / 2, px / 2);
    final radius = _dotSize / 2 * _renderScale;

    // A paper halo under the dot, so it stays legible over a dark road or
    // a park rather than depending on the basemap being pale.
    canvas.drawCircle(
      center,
      radius + 2.5 * _renderScale,
      Paint()..color = AppColors.bgElevated.withValues(alpha: 0.95),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = needsHelp ? AppColors.help : AppColors.primary,
    );

    return _finish(recorder, px, canvasSize);
  }

  Future<BitmapDescriptor> _renderCluster({
    required int count,
    required bool containsHelp,
  }) async {
    const canvasSize = _clusterSize;
    final px = (canvasSize * _renderScale).round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(px / 2, px / 2);
    final ringWidth = 2.5 * _renderScale;
    final radius = px / 2 - ringWidth - (containsHelp ? 3 * _renderScale : 0);

    // Filled, not hollow. A group stands in for several cats, and the cats
    // it stands in for are solid faces cut out of the map with a paper
    // contour — an empty white circle read as a hole in the map rather
    // than as something on it. Same terracotta the product's own actions
    // are, so the count belongs to tekir and not to the basemap.
    canvas.drawCircle(center, radius, Paint()..color = AppColors.primary);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth
        ..color = AppColors.bgElevated,
    );
    if (containsHelp) {
      // A group holding a cat that needs help says so, so a help mark is
      // never hidden by the grouping in front of it — by its own colour
      // *and* by the badge below, never by colour alone.
      canvas.drawCircle(
        center,
        radius + ringWidth,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 * _renderScale
          ..color = AppColors.help,
      );
    }

    final painter = TextPainter(textDirection: TextDirection.ltr)
      ..text = TextSpan(
        text: '$count',
        style: TextStyle(
          fontFamily: 'Work Sans',
          fontSize: 16 * _renderScale,
          fontWeight: FontWeight.w800,
          color: AppColors.primaryInk,
        ),
      )
      ..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
    if (containsHelp) _drawHelpBadge(canvas, center, radius + ringWidth);

    return _finish(recorder, px, canvasSize);
  }

  /// The mark that keeps "needs help" off colour alone: a filled disc with
  /// an exclamation, pinned to the upper right of whatever it annotates.
  void _drawHelpBadge(Canvas canvas, Offset center, double radius) {
    final diagonal = radius * 0.7071;
    final badgeCenter = center + Offset(diagonal, -diagonal);
    final badgeRadius = 6.5 * _renderScale;
    canvas.drawCircle(
      badgeCenter,
      badgeRadius + 1.5 * _renderScale,
      Paint()..color = AppColors.bgElevated,
    );
    canvas.drawCircle(
      badgeCenter,
      badgeRadius,
      Paint()..color = AppColors.help,
    );

    final stroke = Paint()
      ..color = AppColors.helpInk
      ..strokeWidth = 1.8 * _renderScale
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      badgeCenter + Offset(0, -badgeRadius * 0.45),
      badgeCenter + Offset(0, badgeRadius * 0.12),
      stroke,
    );
    canvas.drawPoints(ui.PointMode.points, [
      badgeCenter + Offset(0, badgeRadius * 0.48),
    ], stroke);
  }

  void _drawGlyph(
    Canvas canvas,
    Offset center,
    IconData icon,
    double size,
    Color color,
  ) {
    final painter = TextPainter(textDirection: TextDirection.ltr)
      ..text = TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: size,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: color,
        ),
      )
      ..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  Future<ui.Image?> _decodePhoto(String url) {
    if (url.isEmpty) return Future.value(null);
    return _photoCache.putIfAbsent(url, () => _fetchAndDecode(url));
  }

  Future<ui.Image?> _fetchAndDecode(String url) async {
    try {
      final response = await _photoClient.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = Uint8List.fromList(response.data!);
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  Future<BitmapDescriptor> _finish(
    ui.PictureRecorder recorder,
    int px,
    double displaySize,
  ) async {
    final image = await recorder.endRecording().toImage(px, px);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(
      bytes!.buffer.asUint8List(),
      width: displaySize,
      height: displaySize,
    );
  }
}

final markerBitmapBuilderProvider = Provider<MarkerBitmapBuilder>(
  (ref) => MarkerBitmapBuilder(),
);
