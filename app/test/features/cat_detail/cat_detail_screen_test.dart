import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/theme/app_theme.dart';
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

// A guest session (never restored) — this file only asserts on read-path
// rendering, not the follow feature (issue #65), so FollowsNotifier just
// needs to resolve to an empty set without ever reaching a real network
// call: watching a guest session is exactly what makes it do that.
class _GuestSessionIdentityService implements SessionIdentityService {
  @override
  SessionIdentity? get cached => null;

  @override
  Future<SessionIdentity?> restore() async => null;

  @override
  Future<void> save(SessionIdentity identity) async {}

  @override
  Future<void> logout({String? deviceToken}) async {}
}

Future<void> _pump(WidgetTester tester, CatDetailState state) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catDetailProvider(
          _catId,
        ).overrideWith(() => _FixedCatDetailNotifier(_catId, state)),
        sessionIdentityServiceProvider.overrideWithValue(
          _GuestSessionIdentityService(),
        ),
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
      // "görüldü" appears twice: once as the three-stat header's own
      // label (issue #121), once as this entry's timeline chip.
      expect(find.text('görüldü'), findsNWidgets(2));
      expect(find.text('su verildi'), findsOneWidget);
      expect(find.text('kase boştu, doldurduk'), findsOneWidget);
      // raw lat/lng must never render anywhere on the detail screen.
      expect(find.textContaining('41.0256'), findsNothing);
      expect(find.textContaining('28.9744'), findsNothing);
      // permanent trait chips are not part of the mvp surface (issue #42).
      expect(find.textContaining(RegExp(r'^\+\d+ daha$')), findsNothing);
      expect(find.text('daha az göster'), findsNothing);
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
    'missing photo: falls back to a branded placeholder at the same 16:9 '
    'cover geometry, not a broken image',
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
      // The cover keeps the binding design's fixed 16:9 ratio even without
      // a photo — the placeholder shares the real photo's footprint.
      final cover = tester.getSize(find.byType(AspectRatio));
      expect(cover.width / cover.height, closeTo(16 / 9, 0.01));
    },
  );

  testWidgets(
    'a photoless cover is not tappable — no full-screen view to open',
    (tester) async {
      await _pump(
        tester,
        CatDetailState(
          detail: _detailMissingPhoto,
          updates: const [],
          hasLoadedOnce: true,
        ),
      );

      await tester.tap(find.byType(AspectRatio), warnIfMissed: false);
      await tester.pumpAndSettle();

      // Still on the profile — nothing was pushed over it.
      expect(find.text('boncuk'), findsWidgets);
      expect(find.byIcon(Icons.close), findsNothing);
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
    'an active help state shows the fixed title, the note, and expiry — never a category',
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
          comment: 'kabı bomboştu ve halsizdi',
          createdAt: now.subtract(const Duration(hours: 1)),
          expiresAt: now.add(const Duration(hours: 71)),
        ),
      );
      await _pump(
        tester,
        CatDetailState(detail: detail, updates: const [], hasLoadedOnce: true),
      );

      expect(find.text('Yardıma ihtiyacı var'), findsOneWidget);
      expect(find.text('kabı bomboştu ve halsizdi'), findsOneWidget);
      expect(find.textContaining('sona eriyor'), findsOneWidget);
    },
  );

  testWidgets('an active help state without a note omits the note line', (
    tester,
  ) async {
    final now = DateTime.now();
    final detail = CatDetail(
      id: _catId,
      name: 'duman',
      lat: 41.0256,
      lng: 28.9744,
      areaLabel: null,
      primaryPhoto: null,
      createdAt: DateTime.utc(2026, 1, 1),
      lastUpdateAt: null,
      activeAlert: ActiveAlert(
        comment: null,
        createdAt: now.subtract(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 71)),
      ),
    );
    await _pump(
      tester,
      CatDetailState(detail: detail, updates: const [], hasLoadedOnce: true),
    );

    expect(find.text('Yardıma ihtiyacı var'), findsOneWidget);
    expect(find.textContaining('sona eriyor'), findsOneWidget);
  });

  testWidgets('no active alert shows no alert banner or warm callout', (
    tester,
  ) async {
    await _pump(
      tester,
      CatDetailState(detail: _detail, updates: const [], hasLoadedOnce: true),
    );

    // The 0.1 needs-help callout is gone (issue #102: help lives inside
    // the update sheet), so with no active alert nothing on this screen
    // renders the warning icon at all.
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    expect(find.text('Yardıma ihtiyacı var'), findsNothing);
  });

  testWidgets(
    'a legacy category-bearing help entry renders the fixed chip, expired without active emphasis — never its category',
    (tester) async {
      final now = DateTime.now();
      // The wire shape a legacy record arrives in through the
      // compatibility window: kind-based, category fields present, no
      // needs_help flag. It must stay renderable, category-free.
      final legacy = CatUpdateEntry.fromJson({
        'id': 'u1',
        'kind': 'needs_help',
        'statuses': const <String>[],
        'comment': null,
        'created_at': now
            .subtract(const Duration(hours: 100))
            .toIso8601String(),
        'needs_help_category': 'water_needed',
        'needs_help_category_label': 'suya ihtiyacı var',
        'needs_help_expires_at': now
            .subtract(const Duration(hours: 28))
            .toIso8601String(),
        'needs_help_active': false,
      });
      await _pump(
        tester,
        CatDetailState(detail: _detail, updates: [legacy], hasLoadedOnce: true),
      );

      expect(find.text('yardım gerekiyor'), findsOneWidget);
      expect(find.text('suya ihtiyacı var'), findsNothing);
      // the three-stat header's own "su" label is unrelated to the legacy
      // category and legitimately renders (issue #121) — only the leaked
      // category text itself must never appear.
      expect(find.textContaining('suya'), findsNothing);
      // an expired entry must never render with the active help color —
      // that emphasis is reserved for the active-alert banner alone, and
      // this fixture has no active alert at all.
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    },
  );

  testWidgets(
    'a combined status + help update renders as one event: help chip, status tag, and help-tinted note',
    (tester) async {
      final now = DateTime.now();
      await _pump(
        tester,
        CatDetailState(
          detail: _detail,
          updates: [
            CatUpdateEntry(
              id: 'u1',
              needsHelp: true,
              statuses: const ['water_provided'],
              comment: 'su bıraktım ama akşam biri daha bakabilir mi?',
              createdAt: now.subtract(const Duration(hours: 1)),
              needsHelpExpiresAt: now.add(const Duration(hours: 71)),
              needsHelpActive: true,
            ),
          ],
          hasLoadedOnce: true,
        ),
      );

      expect(find.text('yardım gerekiyor'), findsOneWidget);
      expect(find.text('su verildi'), findsOneWidget);
      expect(
        find.text('su bıraktım ama akşam biri daha bakabilir mi?'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'each status kind gets its own chip color, never one shared pill',
    (tester) async {
      await _pump(
        tester,
        CatDetailState(
          detail: _detail,
          updates: [
            CatUpdateEntry(
              id: 'u1',
              statuses: const ['seen', 'fed', 'water_provided'],
              comment: null,
              createdAt: DateTime.utc(2026, 1, 2),
            ),
          ],
          hasLoadedOnce: true,
        ),
      );

      // Scoped to the chip row's own Wrap: "görüldü" also legitimately
      // appears as the three-stat header's label (issue #121), which
      // isn't inside this Wrap.
      Color chipColor(String label) {
        final container = tester.widget<Container>(
          find.ancestor(
            of: find.descendant(
              of: find.byType(Wrap),
              matching: find.text(label),
            ),
            matching: find.byType(Container),
          ),
        );
        return (container.decoration! as BoxDecoration).color!;
      }

      expect(chipColor('görüldü'), AppColors.seenBg);
      expect(chipColor('mama verildi'), AppColors.fedBg);
      expect(chipColor('su verildi'), AppColors.waterBg);
    },
  );

  testWidgets(
    'the identity block (name + area) renders below the cover, not overlaid on it',
    (tester) async {
      await _pump(
        tester,
        CatDetailState(detail: _detail, updates: const [], hasLoadedOnce: true),
      );

      final coverBottom = tester.getBottomLeft(find.byType(AspectRatio)).dy;
      final nameTop = tester.getTopLeft(find.text('tekir')).dy;
      final areaTop = tester
          .getTopLeft(find.text('Galata Kulesi çevresi, Beyoğlu'))
          .dy;

      expect(nameTop, greaterThanOrEqualTo(coverBottom));
      expect(areaTop, greaterThan(nameTop));
    },
  );

  testWidgets(
    'the follow control is the icon-only glass button on the cover, not a labeled button in the body',
    (tester) async {
      await _pump(
        tester,
        CatDetailState(detail: _detail, updates: const [], hasLoadedOnce: true),
      );

      expect(find.text('Takip et'), findsNothing);
      expect(find.text('Takip ediliyor'), findsNothing);
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);

      final coverBottom = tester.getBottomLeft(find.byType(AspectRatio)).dy;
      final followIconBottom = tester
          .getBottomLeft(find.byIcon(Icons.favorite_border))
          .dy;
      expect(followIconBottom, lessThanOrEqualTo(coverBottom));
    },
  );
}
