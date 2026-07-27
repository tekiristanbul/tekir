import 'package:flutter/material.dart';

/// Maps [BadgeStatus.icon]'s server-provided key (docs/product/badges.md's
/// fixed 5-badge vocabulary, ported from the approved prototype's icon
/// names — prototype/data.js's `icon('eye'|'bowl'|'droplet'|'pin'|'paw')`)
/// onto a concrete Material icon. Kept as one small lookup, mirroring how
/// `_statusLabelsTr` is duplicated per-screen elsewhere in this app rather
/// than over-abstracted for two callers.
IconData badgeIconFor(String key) {
  return switch (key) {
    'eye' => Icons.visibility,
    'bowl' => Icons.ramen_dining,
    'droplet' => Icons.water_drop,
    'pin' => Icons.location_on,
    'paw' => Icons.pets,
    _ => Icons.emoji_events,
  };
}
