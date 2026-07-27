import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/badges/data/badge.dart';
import 'package:app/features/badges/data/badges_api.dart';
import 'package:app/features/badges/ui/badge_detail_screen.dart';
import 'package:app/features/badges/ui/badges_screen.dart';

class _FakeBadgesApi implements BadgesApi {
  _FakeBadgesApi({this.nextItems = const [], this.nextError});

  List<BadgeStatus> nextItems;
  Object? nextError;
  int calls = 0;

  @override
  Future<List<BadgeStatus>> fetch() async {
    calls++;
    if (nextError != null) throw nextError!;
    return nextItems;
  }
}

BadgeStatus _badge(
  String id, {
  bool earned = false,
  int value = 0,
  int target = 5,
  DateTime? earnedAt,
}) => BadgeStatus(
  id: id,
  name: 'Name $id',
  icon: 'eye',
  condition: 'Condition $id',
  descr: 'Descr $id',
  value: value,
  target: target,
  earned: earned,
  earnedAt: earnedAt,
);

Future<void> _pump(WidgetTester tester, _FakeBadgesApi api) async {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => const BadgesScreen()),
      GoRoute(
        path: '/badges/:id',
        builder: (context, state) =>
            BadgeDetailScreen(badgeId: state.pathParameters['id']!),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [badgesApiProvider.overrideWithValue(api)],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the zero-earned summary line', (tester) async {
    final api = _FakeBadgesApi(nextItems: [_badge('first_sighting')]);
    await _pump(tester, api);

    expect(
      find.text(
        'Henüz hiç rozet kazanmadın. Aşağıdaki katkılarla ilk rozetini kazanabilirsin.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('shows the earned-count summary once at least one is earned', (
    tester,
  ) async {
    final api = _FakeBadgesApi(
      nextItems: [
        _badge('first_sighting', earned: true, value: 1, target: 1),
        _badge('feeder'),
      ],
    );
    await _pump(tester, api);

    expect(find.text('1 / 2 rozet kazanıldı.'), findsOneWidget);
    expect(find.text('Kazanıldı'), findsOneWidget);
    expect(find.text('0 / 5'), findsOneWidget);
  });

  testWidgets('a load failure shows a retry state', (tester) async {
    final api = _FakeBadgesApi(nextError: Exception('boom'));
    await _pump(tester, api);

    expect(find.text('Rozetler yüklenemedi'), findsOneWidget);

    api.nextError = null;
    api.nextItems = [_badge('first_sighting')];
    await tester.tap(find.text('Tekrar dene'));
    await tester.pumpAndSettle();

    expect(find.text('Rozetler yüklenemedi'), findsNothing);
  });

  testWidgets('tapping a badge navigates to its detail screen', (tester) async {
    final api = _FakeBadgesApi(
      nextItems: [
        _badge(
          'first_sighting',
          earned: true,
          value: 1,
          target: 1,
          earnedAt: DateTime.utc(2026, 1, 1),
        ),
      ],
    );
    await _pump(tester, api);

    await tester.tap(find.text('Name first_sighting'));
    await tester.pumpAndSettle();

    expect(find.text('Condition first_sighting'), findsOneWidget);
    expect(find.text('Descr first_sighting'), findsOneWidget);
  });
}
