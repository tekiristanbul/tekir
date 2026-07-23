import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/theme/app_theme.dart';

/// google_maps_flutter markers are images, not arbitrary widgets (unlike
/// flutter_map), so a cat's photo has to be fetched, cropped into a circle,
/// and encoded into a [BitmapDescriptor] here. Results are cached per cat,
/// since the marker set is rebuilt on every fetched cat-list change, not
/// just once per cat. Cluster bubbles themselves are rendered natively by
/// the sdk (google_maps_flutter's ClusterManager) and aren't built here.
class MarkerBitmapBuilder {
  MarkerBitmapBuilder({Dio? photoClient}) : _photoClient = photoClient ?? Dio();

  static const _displaySize = 44.0;
  static const _renderScale = 3.0; // crisp on high-dpi screens

  final Dio _photoClient;
  final _pinCache = <String, Future<BitmapDescriptor>>{};

  Future<BitmapDescriptor> pin({
    required String cacheKey,
    required String photoUrl,
    required bool needsHelp,
  }) {
    return _pinCache.putIfAbsent(
      '$cacheKey:$needsHelp',
      () => _renderPin(photoUrl: photoUrl, needsHelp: needsHelp),
    );
  }

  Future<BitmapDescriptor> _renderPin({
    required String photoUrl,
    required bool needsHelp,
  }) async {
    final px = (_displaySize * _renderScale).round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(px / 2, px / 2);
    final ringWidth = (needsHelp ? 3.0 : 2.0) * _renderScale;
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
      canvas.drawCircle(center, radius, Paint()..color = AppColors.panel);
      _drawGlyph(canvas, center, Icons.pets, radius);
    }
    canvas.restore();

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth
        ..color = needsHelp ? Colors.red : AppColors.accent,
    );

    return _finish(recorder, px);
  }

  void _drawGlyph(Canvas canvas, Offset center, IconData icon, double radius) {
    final painter = TextPainter(textDirection: TextDirection.ltr)
      ..text = TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: radius,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: AppColors.line,
        ),
      )
      ..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  Future<ui.Image?> _decodePhoto(String url) async {
    if (url.isEmpty) return null;
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

  Future<BitmapDescriptor> _finish(ui.PictureRecorder recorder, int px) async {
    final image = await recorder.endRecording().toImage(px, px);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(
      bytes!.buffer.asUint8List(),
      width: _displaySize,
      height: _displaySize,
    );
  }
}

final markerBitmapBuilderProvider = Provider<MarkerBitmapBuilder>(
  (ref) => MarkerBitmapBuilder(),
);
