import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/badges/data/badge.dart';
import 'package:app/features/badges/data/badges_api.dart';
import 'package:app/features/badges/ui/badges_screen.dart';

/// WCAG 2.x relative luminance of a fully opaque color.
double _luminance(Color color) {
  double channel(double c) =>
      c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

/// WCAG contrast ratio between two opaque colors.
double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

class _FakeBadgesApi implements BadgesApi {
  _FakeBadgesApi(this.items);

  final List<BadgeStatus> items;

  @override
  Future<List<BadgeStatus>> fetch() async => items;
}

BadgeStatus _badge(String id, {bool earned = false}) => BadgeStatus(
  id: id,
  name: 'Name $id',
  icon: 'eye',
  condition: 'Condition $id',
  descr: 'Descr $id',
  value: earned ? 1 : 0,
  target: 1,
  earned: earned,
  earnedAt: earned ? DateTime.utc(2026, 1, 1) : null,
);

void main() {
  // The badge icon is the element that carries the earned/unearned state,
  // so every color it takes must clear WCAG's 3:1 non-text minimum
  // against every surface the badge ui places it on (issue #109, "fix
  // badge contrast" — AppColors.faint sat at ~2.4–3.0:1 and failed).
  test('badge icon colors clear 3:1 on every badge surface', () {
    const surfaces = {
      'surface': AppColors.surface, // badges list rows
      'surfaceAlt': AppColors.surfaceAlt, // unearned strip/detail hero
      'primarySoft': AppColors.primarySoft, // earned strip/detail hero
    };
    const iconColors = {
      'primaryStrong (earned)': AppColors.primaryStrong,
      'muted (unearned)': AppColors.muted,
    };
    for (final surface in surfaces.entries) {
      for (final icon in iconColors.entries) {
        expect(
          _contrast(icon.value, surface.value),
          greaterThanOrEqualTo(3.0),
          reason: '${icon.key} on ${surface.key}',
        );
      }
    }
  });

  test(
    'the replaced faint color indeed fails — the regression this guards',
    () {
      expect(_contrast(AppColors.faint, AppColors.surfaceAlt), lessThan(3.0));
    },
  );

  testWidgets('unearned badge icons render muted, earned primaryStrong', (
    tester,
  ) async {
    final api = _FakeBadgesApi([
      _badge('earned_one', earned: true),
      _badge('unearned_one'),
    ]);
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (context, state) => const BadgesScreen()),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [badgesApiProvider.overrideWithValue(api)],
        child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    final icons = tester
        .widgetList<Icon>(find.byIcon(Icons.visibility))
        .toList();
    expect(icons, hasLength(2));
    expect(icons.map((i) => i.color), [
      AppColors.primaryStrong,
      AppColors.muted,
    ]);
  });
}
