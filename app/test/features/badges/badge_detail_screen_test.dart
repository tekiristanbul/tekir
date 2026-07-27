import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/badges/data/badge.dart';
import 'package:app/features/badges/data/badges_api.dart';
import 'package:app/features/badges/ui/badge_detail_screen.dart';

class _FakeBadgesApi implements BadgesApi {
  _FakeBadgesApi({this.nextItems = const []});

  List<BadgeStatus> nextItems;
  int calls = 0;

  @override
  Future<List<BadgeStatus>> fetch() async {
    calls++;
    return nextItems;
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required String badgeId,
  required _FakeBadgesApi api,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [badgesApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: AppTheme.light,
        home: BadgeDetailScreen(badgeId: badgeId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('deep-linking straight to a badge triggers its own load', (
    tester,
  ) async {
    final api = _FakeBadgesApi(
      nextItems: [
        BadgeStatus(
          id: 'feeder',
          name: 'Mamacı',
          icon: 'bowl',
          condition: '5 kez besle',
          descr: 'Açıklama',
          value: 3,
          target: 5,
          earned: false,
          earnedAt: null,
        ),
      ],
    );
    await _pump(tester, badgeId: 'feeder', api: api);

    expect(api.calls, 1);
    expect(find.text('Mamacı'), findsOneWidget);
    expect(find.text('3 / 5'), findsOneWidget);
  });

  testWidgets('shows the earned date for an earned badge', (tester) async {
    final api = _FakeBadgesApi(
      nextItems: [
        BadgeStatus(
          id: 'first_sighting',
          name: 'İlk Görüş',
          icon: 'eye',
          condition: 'İlk görüldü paylaş',
          descr: 'Açıklama',
          value: 1,
          target: 1,
          earned: true,
          earnedAt: DateTime.now().subtract(const Duration(days: 2)),
        ),
      ],
    );
    await _pump(tester, badgeId: 'first_sighting', api: api);

    expect(find.textContaining('kazanıldı'), findsOneWidget);
  });

  testWidgets('an unknown badge id shows a not-found message', (tester) async {
    final api = _FakeBadgesApi(
      nextItems: [
        BadgeStatus(
          id: 'feeder',
          name: 'Mamacı',
          icon: 'bowl',
          condition: 'condition',
          descr: 'descr',
          value: 0,
          target: 5,
          earned: false,
          earnedAt: null,
        ),
      ],
    );
    await _pump(tester, badgeId: 'does-not-exist', api: api);

    expect(find.text('Rozet bulunamadı'), findsOneWidget);
  });
}
