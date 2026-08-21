import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/theme/app_theme.dart';

/// WCAG 2.x relative luminance of a fully opaque color.
double _luminance(Color color) {
  double channel(double c) =>
      c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Composites [foreground] at [alpha] over [background], the way a
/// translucent label actually renders.
Color _over(Color foreground, Color background, double alpha) {
  return Color.from(
    alpha: 1,
    red: foreground.r * alpha + background.r * (1 - alpha),
    green: foreground.g * alpha + background.g * (1 - alpha),
    blue: foreground.b * alpha + background.b * (1 - alpha),
  );
}

/// The palette's text colors against the grounds they are actually painted
/// on. `faint` shipped at 2.42:1 on `surfaceAlt` while carrying every
/// timeline timestamp, the cat's area label, the inactive segment label
/// and the line confirming a contribution was saved — none of it readable
/// outdoors. These lock the floor so the next palette edit has to keep it.
void main() {
  const grounds = {
    'bg': AppColors.bg,
    'surface': AppColors.surface,
    'surfaceAlt': AppColors.surfaceAlt,
  };

  group('body text clears WCAG AA (4.5:1)', () {
    for (final ground in grounds.entries) {
      test('faint on ${ground.key}', () {
        expect(
          _contrast(AppColors.faint, ground.value),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('muted on ${ground.key}', () {
        expect(
          _contrast(AppColors.muted, ground.value),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('ink on ${ground.key}', () {
        expect(
          _contrast(AppColors.ink, ground.value),
          greaterThanOrEqualTo(4.5),
        );
      });
    }
  });

  test('faint stays subordinate to muted', () {
    // The palette leans on a two-step hierarchy: muted for secondary text,
    // faint for tertiary. Darkening faint to make it readable must not
    // collapse that distinction — if it ever reads as strong as muted, the
    // fix has eaten the design decision it was protecting.
    expect(
      _contrast(AppColors.faint, AppColors.surfaceAlt),
      lessThan(_contrast(AppColors.muted, AppColors.surfaceAlt)),
    );
  });

  test('the help palette stays readable on its own tint', () {
    expect(
      _contrast(AppColors.helpStrong, AppColors.helpSoft),
      greaterThanOrEqualTo(4.5),
    );
  });

  test('a disabled primary action stays readable', () {
    // Not decoration: the composer opens disabled, and that label is what
    // explains what is missing. Material's default disabled pair
    // (onSurface at 38% over lineStrong) renders it at 2.09:1, which is
    // why both submit surfaces name their own pair instead.
    expect(
      _contrast(AppColors.muted, AppColors.surfaceAlt),
      greaterThanOrEqualTo(4.5),
    );
    final materialDefault = _over(AppColors.ink, AppColors.lineStrong, 0.38);
    expect(
      _contrast(materialDefault, AppColors.lineStrong),
      lessThan(4.5),
      reason: 'the pair this app must not fall back to',
    );
  });
}
