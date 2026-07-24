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
// in _HeroPlaceholder) directly — there's no separate "photo loads
// successfully" path that can be exercised without a real or intercepted
// network call.
final _detail = CatDetail(
  id: _catId,
  name: 'tekir',
  lat: 41.0256,
  lng: 28.9744,
  areaLabel: 'Galata Kulesi çevresi, Beyoğlu',
  primaryPhoto: null,
  createdAt: DateTime.utc(2026, 1, 1),
  lastUpdateAt: DateTime.utc(2026, 1, 2),
);

final _detailMissingPhoto = CatDetail(
  id: _catId,
  name: 'boncuk',
  lat: 41.0257,
  lng: 28.9745,
  areaLabel: null,
  primaryPhoto: null,
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

  testWidgets('shows the not-found state, in turkish, with a back action', (
    tester,
  ) async {
    await _pump(
      tester,
      const CatDetailState(hasLoadedOnce: true, notFound: true),
    );

    expect(find.text('Kedi bulunamadı'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);
  });

  testWidgets('shows the error state with a turkish retry action', (
    tester,
  ) async {
    await _pump(
      tester,
      CatDetailState(hasLoadedOnce: true, error: Exception('network down')),
    );

    expect(find.text('Kedi yüklenemedi'), findsOneWidget);
    expect(find.text('Tekrar dene'), findsOneWidget);
  });

  testWidgets(
    'populated: shows name, area label, and turkish status history — never raw coordinates, never a trait chip',
    (tester) async {
      await _pump(
        tester,
        CatDetailState(
          detail: _detail,
          updates: [
            CatUpdateEntry(
              id: 'u1',
              statuses: const ['seen', 'water_provided'],
              comment: 'kase boştu, doldurduk',
              createdAt: DateTime.utc(2026, 1, 2),
            ),
          ],
          hasLoadedOnce: true,
        ),
      );

      expect(find.text('tekir'), findsWidgets);
      expect(find.text('Galata Kulesi çevresi, Beyoğlu'), findsOneWidget);
      // structured statuses render as turkish tags, the comment as
      // separate (non-italic) body text — both present, never merged.
      expect(find.text('görüldü'), findsOneWidget);
      expect(find.text('su verildi'), findsOneWidget);
      expect(find.text('kase boştu, doldurduk'), findsOneWidget);
      // raw lat/lng must never render anywhere on the detail screen.
      expect(find.textContaining('41.0256'), findsNothing);
      expect(find.textContaining('28.9744'), findsNothing);
      // permanent trait chips are not part of the mvp surface (issue #42).
      expect(find.textContaining('daha'), findsNothing);
    },
  );

  testWidgets('empty history: shows the turkish empty state, not an error', (
    tester,
  ) async {
    await _pump(
      tester,
      CatDetailState(detail: _detail, updates: const [], hasLoadedOnce: true),
    );

    expect(find.text('Henüz güncelleme yok'), findsOneWidget);
  });

  testWidgets(
    'missing photo: falls back to a branded placeholder at the same hero size, not a broken image',
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
      final heroBoxes = tester
          .widgetList<SizedBox>(find.byType(SizedBox))
          .where((box) => box.height == 280);
      expect(
        heroBoxes,
        isNotEmpty,
        reason: 'the hero region keeps its 280px height even without a photo',
      );
    },
  );

  testWidgets('load more renders as a secondary (outlined) action', (
    tester,
  ) async {
    await _pump(
      tester,
      CatDetailState(
        detail: _detail,
        updates: [
          CatUpdateEntry(
            id: 'u1',
            statuses: const ['fed'],
            comment: null,
            createdAt: DateTime.utc(2026, 1, 2),
          ),
        ],
        nextCursor: 'next',
        hasLoadedOnce: true,
      ),
    );

    expect(find.text('mama verildi'), findsOneWidget);
    expect(find.text('Daha fazla göster'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsWidgets);
  });

  testWidgets(
    'an active needs-help alert shows a prominent category + expiry banner',
    (tester) async {
      final now = DateTime.now();
      final detail = CatDetail(
        id: _catId,
        name: 'duman',
        lat: 41.0256,
        lng: 28.9744,
        areaLabel: 'Galata Kulesi çevresi, Beyoğlu',
        primaryPhoto: null,
        createdAt: DateTime.utc(2026, 1, 1),
        lastUpdateAt: null,
        activeAlert: ActiveAlert(
          category: 'injured_or_sick',
          categoryLabel: 'yaralı / hasta',
          createdAt: now.subtract(const Duration(hours: 1)),
          expiresAt: now.add(const Duration(hours: 71)),
        ),
      );
      await _pump(
        tester,
        CatDetailState(detail: detail, updates: const [], hasLoadedOnce: true),
      );

      expect(find.textContaining('yaralı / hasta'), findsOneWidget);
      expect(find.textContaining('sona eriyor'), findsOneWidget);
    },
  );

  testWidgets('no active alert shows no alert banner', (tester) async {
    await _pump(
      tester,
      CatDetailState(detail: _detail, updates: const [], hasLoadedOnce: true),
    );

    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  testWidgets(
    'a needs-help timeline entry shows its category, expired without active emphasis',
    (tester) async {
      final now = DateTime.now();
      await _pump(
        tester,
        CatDetailState(
          detail: _detail,
          updates: [
            CatUpdateEntry(
              id: 'u1',
              kind: 'needs_help',
              statuses: const [],
              comment: null,
              createdAt: now.subtract(const Duration(hours: 100)),
              needsHelpCategory: 'water_needed',
              needsHelpCategoryLabel: 'suya ihtiyacı var',
              needsHelpExpiresAt: now.subtract(const Duration(hours: 28)),
              needsHelpActive: false,
            ),
          ],
          hasLoadedOnce: true,
        ),
      );

      expect(find.text('suya ihtiyacı var'), findsOneWidget);
      // an expired entry must never render with the active help color —
      // that emphasis is reserved for the active-alert banner alone, and
      // this fixture has no active alert at all.
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    },
  );
}
