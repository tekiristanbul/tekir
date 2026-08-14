import 'package:flutter/widgets.dart';

/// How large a network image may be decoded into memory, in device pixels.
///
/// The backend stores and serves exactly one canonical image per media item —
/// there are no thumbnail or medium variants (see docs/architecture/db.md) —
/// so a 2643x4698 phone photo is what every surface receives, including a
/// 54pt notification row. Decoded, that single image occupies width * height *
/// 4 bytes: about 47 MB. Flutter's image cache defaults to 100 MB, so two of
/// them fill it, and on iOS a few live at once cross the process memory high
/// watermark and the app is killed mid-navigation.
///
/// Passing the result as `memCacheWidth` makes `CachedNetworkImage` decode at
/// the size actually painted rather than the size uploaded: the same photo in
/// a 132pt avatar on a 3x screen becomes ~1 MB instead of ~47 MB.
///
/// [logicalWidth] is the width the widget really occupies, not a guess — a
/// value larger than the painted box wastes memory again, and a smaller one
/// shows a visibly soft image.
int decodeWidthFor(BuildContext context, double logicalWidth) {
  final scaled = logicalWidth * MediaQuery.devicePixelRatioOf(context);
  // Never below 1: a zero or negative constraint would make the decoder
  // reject the request outright rather than clamp it.
  return scaled < 1 ? 1 : scaled.round();
}

/// The ceiling for Flutter's own decoded-image cache, applied once at startup.
///
/// The default is 100 MB, which was chosen for images that are already sized
/// for their surface. With full-resolution photos it is a liability rather
/// than a budget: it will happily hold two of them and keep them alive. 48 MB
/// is enough for a screenful of correctly-sized images (see [decodeWidthFor])
/// with room to scroll, and small enough that the cache can never be the
/// reason the process is killed.
const int imageCacheMaxBytes = 48 * 1024 * 1024;
