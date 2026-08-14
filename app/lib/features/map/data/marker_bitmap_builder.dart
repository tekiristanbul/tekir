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

  // Doubled from the prototype's 44pt (product-owner call): at the old size
  // a cat's photo was too small to recognise at a glance, which is the whole
  // point of a photo pin rather than a dot.
  static const _displaySize = 88.0;
  // Keeps the prototype's proportion between base and selected (56 vs 40),
  // so a selected pin still reads as about a third larger.
  static const _selectedDisplaySize = 116.0;
  // Was 3.0 to stay crisp on high-dpi screens. At twice the display size the
  // bitmap is already 176pt across, so 2.0 renders at 176px * 2 = 352px —
  // still above any current device's pixel density for this size, and it
  // keeps a screenful of pins from costing four times the memory the 44pt
  // ones did (each pin is width * height * 4 bytes, held per cat).
  static const _renderScale = 2.0;

  final Dio _photoClient;
  final _pinCache = <String, Future<BitmapDescriptor>>{};
  // decoded photo bytes are cached independently of the rendered pin, so
  // selecting/deselecting a marker (which re-renders the pin at a different
  // size/ring) never re-fetches the same photo over the network.
  final _photoCache = <String, Future<ui.Image?>>{};

  Future<BitmapDescriptor> pin({
    required String cacheKey,
    required String photoUrl,
    required bool needsHelp,
    bool selected = false,
  }) {
    return _pinCache.putIfAbsent(
      '$cacheKey:$needsHelp:$selected',
      () => _renderPin(
        photoUrl: photoUrl,
        needsHelp: needsHelp,
        selected: selected,
      ),
    );
  }

  Future<BitmapDescriptor> _renderPin({
    required String photoUrl,
    required bool needsHelp,
    required bool selected,
  }) async {
    final displaySize = selected ? _selectedDisplaySize : _displaySize;
    final px = (displaySize * _renderScale).round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(px / 2, px / 2);
    final ringWidth = (needsHelp ? 4.0 : (selected ? 3.0 : 2.0)) * _renderScale;
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
      canvas.drawCircle(center, radius, Paint()..color = AppColors.surface);
      _drawGlyph(canvas, center, Icons.pets, radius);
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

    return _finish(recorder, px, displaySize);
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
