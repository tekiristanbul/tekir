import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/cat_detail/data/cat_detail.dart';
import 'package:app/features/cat_detail/ui/cat_detail_notifier.dart';
import 'package:app/features/cat_detail/ui/cat_detail_screen.dart';

const _catId = 'cat-1';

// primaryPhoto is deliberately null on every fixture in this file: feeding a
// real url to CachedNetworkImage would fire an actual network request the
// moment it mounts, which these widget tests must not depend on. the
// "missing photo" test below covers this exact code path (the null branch
// in _CatPhoto) directly — there's no separate "photo loads successfully"
// path that can be exercised without a real or intercepted network call.
final _detailWithTraits = CatDetail(
  id: _catId,
  name: 'tekir',
  lat: 41.0256,
  lng: 28.9744,
  primaryPhoto: null,
  traits: const [CatTrait(key: 'friendly', label: 'Friendly')],
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdateAt: DateTime.utc(2026, 1, 2),
);

final _detailMissingPhoto = CatDetail(
  id: _catId,
  name: 'boncuk',
  lat: 41.0257,
  lng: 28.9745,
  primaryPhoto: null,
  traits: const [],
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdateAt: null,
);

/// A Notifier subclass whose build() returns a fixed, caller-supplied
/// state — the same technique the map feature's widget tests use
/// (test/widget_test.dart's _FixedCatsMapNotifier) to drive the ui without
/// exercising the real network/api layer.
class _FixedCatDetailNotifier extends CatDetailNotifier {
  _FixedCatDetailNotifier(super.catId, this._state);

  final CatDetailState _state;

  @override
  CatDetailState build() => _state;

  // load() is called from initState; the fixed state above should not be
  // clobbered by a real network call in these widget tests.
  @override
  Future<void> load() async {}
}

Future<void> _pump(WidgetTester tester, CatDetailState state) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catDetailProvider(
          _catId,
        ).overrideWith(() => _FixedCatDetailNotifier(_catId, state)),
      ],
      child: const MaterialApp(home: CatDetailScreen(catId: _catId)),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows a spinner while loading and not yet loaded once', (
    tester,
  ) async {
    await _pump(tester, const CatDetailState(isLoading: true));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('tekir'), findsNothing);
  });

  testWidgets('shows the not-found state on a 404', (tester) async {
    await _pump(
      tester,
      const CatDetailState(hasLoadedOnce: true, notFound: true),
    );

    expect(find.text('cat not found'), findsOneWidget);
  });

  testWidgets('shows the error state with a retry action', (tester) async {
    await _pump(
      tester,
      CatDetailState(hasLoadedOnce: true, error: Exception('network down')),
    );

    expect(find.text("couldn't load cat"), findsOneWidget);
    expect(find.text('retry'), findsOneWidget);
  });

  testWidgets('populated: shows name, traits, and the update history', (
    tester,
  ) async {
    await _pump(
      tester,
      CatDetailState(
        detail: _detailWithTraits,
        updates: [
          CatUpdateEntry(
            id: 'u1',
            statuses: const ['seen', 'water_provided'],
            comment: 'topped up the water bowl',
            createdAt: DateTime.utc(2026, 1, 2),
          ),
        ],
        hasLoadedOnce: true,
      ),
    );

    expect(find.text('tekir'), findsWidgets);
    expect(find.text('Friendly'), findsOneWidget);
    // statuses render as chips, the comment as separate italic body text —
    // both must be present and distinguishable, not merged into one string.
    expect(find.text('seen'), findsOneWidget);
    // _UpdateTile displays statuses with underscores replaced by spaces.
    expect(find.text('water provided'), findsOneWidget);
    expect(find.text('topped up the water bowl'), findsOneWidget);
  });

  testWidgets('empty history: shows the empty state, not an error', (
    tester,
  ) async {
    await _pump(
      tester,
      CatDetailState(
        detail: _detailWithTraits,
        updates: const [],
        hasLoadedOnce: true,
      ),
    );

    expect(find.text('no updates yet'), findsOneWidget);
  });

  testWidgets(
    'missing photo: falls back to a placeholder, not a broken image',
    (tester) async {
      await _pump(
        tester,
        CatDetailState(
          detail: _detailMissingPhoto,
          updates: const [],
          hasLoadedOnce: true,
        ),
      );

      expect(find.text('boncuk'), findsWidgets);
      expect(find.byIcon(Icons.pets), findsOneWidget);
    },
  );
}
