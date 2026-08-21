import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/theme/app_theme.dart';
import 'reach_tier.dart';

/// Concept 2's two reduced pins.
///
/// Deliberately a separate builder rather than a parameter added to the
/// shipped [MarkerBitmapBuilder]: the spike must be removable by deleting
/// this directory, and the production builder keeps rendering exactly the
/// one pin it renders today. Identity tier is not built here at all — the
/// map asks the real builder for it, so the concept can never quietly
/// redraw the shipped pin.
///
/// Both pins are the shipped pin's own language at lower resolution: same
/// ring colours, same circle, same needs-help red. Nothing new is invented
/// for a smaller size.
class ReachPinBuilder {
  ReachPinBuilder({Dio? photoClient}) : _photoClient = photoClient ?? Dio();

  static const _presenceSize = 40.0;
  static const _traceSize = 14.0;
  static const _renderScale = 2.0;

  final Dio _photoClient;
  final _pinCache = <String, Future<BitmapDescriptor>>{};
  final _photoCache = <String, Future<ui.Image?>>{};

  Future<BitmapDescriptor> pin({
    required String cacheKey,
    required String photoUrl,
    required bool needsHelp,
    required bool selected,
    required ReachTier tier,
  }) {
    assert(tier != ReachTier.identity, 'identity is the shipped pin');
    return _pinCache.putIfAbsent(
      '$cacheKey:$needsHelp:$selected:${tier.name}',
      () => tier == ReachTier.trace
          ? _renderTrace(needsHelp: needsHelp, selected: selected)
          : _renderPresence(
              photoUrl: photoUrl,
              needsHelp: needsHelp,
              selected: selected,
            ),
    );
  }

  Future<BitmapDescriptor> _renderPresence({
    required String photoUrl,
    required bool needsHelp,
    required bool selected,
  }) async {
    final px = (_presenceSize * _renderScale).round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(px / 2, px / 2);
    // Thinner than identity's ring in the same proportion the pin itself
    // shrank, so the ring reads as the same ring seen from further away
    // rather than as a different pin.
    final ringWidth = (needsHelp ? 2.5 : 1.5) * _renderScale;
    final radius = px / 2 - ringWidth;

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
      canvas.drawCircle(center, radius, Paint()..color = AppColors.primarySoft);
    }
    canvas.restore();

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth
        ..color = needsHelp
            ? AppColors.help
            : (selected ? AppColors.primaryStrong : AppColors.primary),
    );

    return _finish(recorder, px, _presenceSize);
  }

  Future<BitmapDescriptor> _renderTrace({
    required bool needsHelp,
    required bool selected,
  }) async {
    final px = (_traceSize * _renderScale).round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(px / 2, px / 2);
    // A hairline of the page background around the dot: at city zoom the
    // dots overlap constantly, and without it a dense group renders as one
    // shapeless blob instead of a countable cluster.
    canvas.drawCircle(center, px / 2, Paint()..color = AppColors.bg);
    canvas.drawCircle(
      center,
      px / 2 - 1.5 * _renderScale,
      Paint()
        ..color = needsHelp
            ? AppColors.help
            : (selected ? AppColors.primaryStrong : AppColors.primary),
    );
    return _finish(recorder, px, _traceSize);
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

final reachPinBuilderProvider = Provider<ReachPinBuilder>(
  (ref) => ReachPinBuilder(),
);
