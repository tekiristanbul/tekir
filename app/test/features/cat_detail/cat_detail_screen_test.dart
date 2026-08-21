import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/states/initial_read_gate.dart';
import 'package:app/core/states/shimmer_sweep.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/core/utils/relative_time.dart';
import 'package:app/features/cat_detail/data/cat_detail.dart';
import 'package:app/features/cat_detail/data/cat_detail_api.dart';
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
  Future<SessionIdentity?> refreshIfExpired() async => null;

  @override
  Future<void> save(SessionIdentity identity) async {}

  @override
  Future<void> logout({String? deviceToken}) async {}
}

// Only fetchMedia is ever exercised through this file's screen tests — the
// fixed notifier above (see _FixedCatDetailNotifier) bypasses
// fetchDetail/fetchUpdates entirely, and none of these tests submit or
// correct an update — so every other method stays an UnimplementedError
// tripwire rather than a real fake.
class _FakeCatMediaApi implements CatDetailApi {
  _FakeCatMediaApi([this.media = const [], this.setCoverResult]);

  final List<CatMediaItem> media;

  // setCoverPhoto (issue #156) — configurable response plus captured
  // arguments, mirroring the class's own "tripwire unless a test needs it"
  // convention above.
  CatDetail? setCoverResult;
  String? capturedSetCoverCatId;
  String? capturedSetCoverMediaId;

  // renameCat (issue #227) — same scoped convention as setCoverPhoto above.
  CatDetail? renameResult;
  Object? renameError;
  String? capturedRenameCatId;
  String? capturedRenameName;

  // deleteCat (issue #228) — same scoped convention as renameCat above.
  Object? deleteError;
  String? capturedDeleteCatId;

  @override
  Future<CatDetail> fetchDetail(String catId) => throw UnimplementedError();

  @override
  Future<UpdatesPage> fetchUpdates(String catId, {String? cursor}) =>
      throw UnimplementedError();

  @override
  Future<CatUpdateEntry> createUpdate(
    String catId, {
    required List<String> statuses,
    bool needsHelp = false,
    String? comment,
    required String idempotencyKey,
    String? mediaId,
  }) => throw UnimplementedError();

  @override
  Future<String> uploadMedia({
    required Uint8List mediaBytes,
    required String mediaFilename,
    required String idempotencyKey,
    required bool muted,
    void Function(int sent, int total)? onSendProgress,
  }) => throw UnimplementedError();

  @override
  Future<CatUpdateEntry> correctUpdate(
    String catId,
    String updateId, {
    required List<String> statuses,
    String? comment,
    bool clearNeedsHelp = false,
  }) => throw UnimplementedError();

  @override
  Future<void> deleteUpdate(String catId, String updateId) =>
      throw UnimplementedError();

  @override
  Future<List<CatMediaItem>> fetchMedia(String catId) async => media;

  @override
  Future<CatDetail> setCoverPhoto(String catId, String mediaId) async {
    capturedSetCoverCatId = catId;
    capturedSetCoverMediaId = mediaId;
    return setCoverResult!;
  }

  @override
  Future<CatDetail> renameCat(String catId, String name) async {
    capturedRenameCatId = catId;
    capturedRenameName = name;
    if (renameError != null) throw renameError!;
    return renameResult!;
  }

  @override
  Future<void> deleteCat(String catId) async {
    capturedDeleteCatId = catId;
    if (deleteError != null) throw deleteError!;
  }
}

Future<void> _pump(
  WidgetTester tester,
  CatDetailState state, {
  List<CatMediaItem> media = const [],
  _FakeCatMediaApi? api,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catDetailProvider(
          _catId,
        ).overrideWith(() => _FixedCatDetailNotifier(_catId, state)),
        sessionIdentityServiceProvider.overrideWithValue(
          _GuestSessionIdentityService(),
        ),
        catDetailApiProvider.overrideWithValue(api ?? _FakeCatMediaApi(media)),
      ],
      child: const MaterialApp(home: CatDetailScreen(catId: _catId)),
    ),
  );
  await tester.pump();
}

/// A no-op [VideoPlayerPlatform] so a gallery/timeline video widget's
/// [VideoPlayerController.initialize] can actually run in a widget test
/// instead of throwing `UnimplementedError` — the real platform channel
/// has nothing to talk to under `flutter test`. Its event stream never
/// emits, so a controller under test simply stays uninitialized (the
/// still-loading placeholder), which is all these tests need: they only
/// assert on the static play-glyph/thumbnail chrome around the player, not
/// on a decoded frame.
class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  int _nextPlayerId = 0;

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose(int playerId) async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async =>
      _nextPlayerId++;

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) =>
      const Stream<VideoEvent>.empty();
}

/// A configurable [VideoPlayerPlatform] for the thumbnail-decode tests
/// below (issue #198): unlike [_FakeVideoPlayerPlatform] above, whose
/// stream never emits, this one can complete a controller's initialize()
/// successfully (the default) or make it fail ([initializeError]), and
/// records every play()/pause() call so [_VideoThumbnail]'s "force a real
/// frame instead of a blank texture" behavior is directly observable.
class _ScriptedVideoPlayerPlatform extends VideoPlayerPlatform {
  _ScriptedVideoPlayerPlatform({this.initializeError});

  final Object? initializeError;
  int _nextPlayerId = 0;
  final List<int> playCalls = [];
  final List<int> pauseCalls = [];

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose(int playerId) async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async =>
      _nextPlayerId++;

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    final error = initializeError;
    if (error != null) {
      return Stream<VideoEvent>.error(error);
    }
    return Stream<VideoEvent>.value(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 3),
        size: const Size(640, 360),
      ),
    );
  }

  @override
  Future<void> play(int playerId) async {
    playCalls.add(playerId);
  }

  @override
  Future<void> pause(int playerId) async {
    pauseCalls.add(playerId);
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Widget buildView(int playerId) => const SizedBox.shrink();
}

void main() {
  VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform();

  // The timing contract (docs/design/app-states.md) for an initial read:
  // nothing loading-related before 400 ms, the screen's own layout as a
  // skeleton after it, and at 6 s the wait ends in the error state. The
  // read itself is never cancelled — bounded reads end the *wait*.
  group('initial read follows the timing contract', () {
    testWidgets('shows no skeleton body before 400 ms', (tester) async {
      await _pump(tester, const CatDetailState(isLoading: true));

      expect(find.byType(ShimmerSweep), findsNothing);
      expect(find.text('tekir'), findsNothing);
    });

    testWidgets('renders the screen\'s own layout as a skeleton after 400 ms', (
      tester,
    ) async {
      await _pump(tester, const CatDetailState(isLoading: true));
      await tester.pump(kInitialReadDelay);

      expect(find.byType(ShimmerSweep), findsWidgets);
      // Never a bare spinner screen: the standing shapes are the layout.
      expect(find.text('Kedi yüklenemedi'), findsNothing);
    });

    testWidgets('ends the wait in the error state at 6 s', (tester) async {
      await _pump(tester, const CatDetailState(isLoading: true));
      await tester.pump(kInitialReadTimeout);

      expect(find.text('Kedi yüklenemedi'), findsOneWidget);
      expect(find.text('Tekrar dene'), findsOneWidget);
      expect(find.byType(ShimmerSweep), findsNothing);
      // The header stays put, the way the map keeps its ground visible
      // behind its own fallback.
      expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    });

    // Not asserted here: that a late response still replaces the
    // timed-out state. Nothing in this screen or its notifier cancels a
    // read — there is no cancellation code to regress — and the fixed
    // notifier this harness injects cannot swap its state mid-test, so a
    // test for it would exercise the harness rather than the contract.
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
    'missing photo: falls back to a branded placeholder in the same circular '
    'profile-photo footprint, not a broken image',
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
      // issue #236: the profile photo is a circle of fixed size, and the
      // placeholder occupies exactly the same footprint — square, so the
      // clip never distorts what it crops.
      final avatar = tester.getSize(find.byType(ClipOval).first);
      expect(avatar.width, closeTo(avatar.height, 0.01));
    },
  );

  testWidgets(
    'a photoless profile photo is not tappable — no full-screen view to open',
    (tester) async {
      await _pump(
        tester,
        CatDetailState(
          detail: _detailMissingPhoto,
          updates: const [],
          hasLoadedOnce: true,
        ),
      );

      await tester.tap(find.byType(ClipOval).first, warnIfMissed: false);
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
    'the identity block (name + area) renders below the profile photo, not overlaid on it',
    (tester) async {
      await _pump(
        tester,
        CatDetailState(detail: _detail, updates: const [], hasLoadedOnce: true),
      );

      final avatarBottom = tester.getBottomLeft(find.byType(ClipOval).first).dy;
      final nameTop = tester.getTopLeft(find.text('tekir')).dy;
      final areaTop = tester
          .getTopLeft(find.text('Galata Kulesi çevresi, Beyoğlu'))
          .dy;

      expect(nameTop, greaterThanOrEqualTo(avatarBottom));
      expect(areaTop, greaterThan(nameTop));
    },
  );

  testWidgets(
    'the follow control is the icon-only round button in the header, not a labeled button in the body',
    (tester) async {
      await _pump(
        tester,
        CatDetailState(detail: _detail, updates: const [], hasLoadedOnce: true),
      );

      expect(find.text('Takip et'), findsNothing);
      expect(find.text('Takip ediliyor'), findsNothing);
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);

      // It sits above the profile photo, in the header row with the back
      // control — not down in the body with the timeline.
      final avatarTop = tester.getTopLeft(find.byType(ClipOval).first).dy;
      final followIconBottom = tester
          .getBottomLeft(find.byIcon(Icons.favorite_border))
          .dy;
      expect(followIconBottom, lessThanOrEqualTo(avatarTop));
    },
  );

  testWidgets(
    'issue #137: the cover\'s back/follow glass controls clear the top '
    'safe-area inset instead of sitting under the status bar/notch',
    (tester) async {
      // FakeViewPadding is in physical pixels — pin the device pixel ratio
      // so the 47px inset below maps to 47 logical pixels.
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(top: 47);
      addTearDown(tester.view.reset);

      await _pump(
        tester,
        CatDetailState(detail: _detail, updates: const [], hasLoadedOnce: true),
      );

      final backTop = tester.getTopLeft(find.byIcon(Icons.chevron_left)).dy;
      final followTop = tester
          .getTopLeft(find.byIcon(Icons.favorite_border))
          .dy;
      expect(backTop, greaterThanOrEqualTo(47));
      expect(followTop, greaterThanOrEqualTo(47));
    },
  );

  testWidgets(
    'three-stat header: each tile shows its own status time, independently, '
    'falling back to "henüz yok" only for a status with no update yet',
    (tester) async {
      final now = DateTime.now();
      final detail = CatDetail(
        id: _catId,
        name: 'tekir',
        lat: 41.0256,
        lng: 28.9744,
        areaLabel: null,
        primaryPhoto: null,
        createdAt: DateTime.utc(2026, 1, 1),
        lastUpdateAt: null,
        lastSeenAt: now.subtract(const Duration(hours: 2)),
        lastFedAt: null,
        lastWaterAt: now.subtract(const Duration(days: 1)),
      );

      await _pump(
        tester,
        CatDetailState(detail: detail, updates: const [], hasLoadedOnce: true),
      );

      expect(find.text(relativeTimeTr(detail.lastSeenAt!)), findsOneWidget);
      expect(find.text(relativeTimeTr(detail.lastWaterAt!)), findsOneWidget);
      // mama (fed) has no update yet — its own tile falls back, and only
      // its own tile, since seen/su both have a real time above.
      expect(find.text('henüz yok'), findsOneWidget);
    },
  );

  testWidgets(
    'timeline avatar: shows the author\'s own first letter, lowercase',
    (tester) async {
      await _pump(
        tester,
        CatDetailState(
          detail: _detail,
          updates: [
            CatUpdateEntry(
              id: 'u1',
              statuses: const ['seen'],
              comment: null,
              createdAt: DateTime.utc(2026, 1, 2),
              authorDisplayName: 'Aslı',
            ),
          ],
          hasLoadedOnce: true,
        ),
      );

      expect(find.text('a'), findsOneWidget);
      expect(find.byIcon(Icons.person_outline), findsNothing);
      // issue #169: the avatar initial alone doesn't satisfy #154 — the
      // full name must also render as visible text.
      expect(find.text('Aslı'), findsOneWidget);
    },
  );

  testWidgets(
    'timeline avatar: falls back to a person glyph when the author has no '
    'display name, never inventing an initial',
    (tester) async {
      await _pump(
        tester,
        CatDetailState(
          detail: _detail,
          updates: [
            CatUpdateEntry(
              id: 'u1',
              statuses: const ['seen'],
              comment: null,
              createdAt: DateTime.utc(2026, 1, 2),
              authorDisplayName: null,
            ),
            CatUpdateEntry(
              id: 'u2',
              statuses: const ['fed'],
              comment: null,
              createdAt: DateTime.utc(2026, 1, 1),
              authorDisplayName: '   ',
            ),
          ],
          hasLoadedOnce: true,
        ),
      );

      expect(find.byIcon(Icons.person_outline), findsNWidgets(2));
    },
  );

  group('block affordance (issue #234)', () {
    // The menu only appears when the content names an account that is not
    // the caller. Everything else — a seed cat with no owner, the caller's
    // own cat — keeps the single-action report button it had before.
    testWidgets("cat detail: a non-owner sees engelle next to şikayet et", (
      tester,
    ) async {
      await _pump(
        tester,
        CatDetailState(
          detail: CatDetail(
            id: _catId,
            name: 'tekir',
            lat: 41.0256,
            lng: 28.9744,
            areaLabel: null,
            primaryPhoto: null,
            createdAt: DateTime.utc(2026, 1, 1),
            lastUpdateAt: null,
            isOwner: false,
            ownerUserId: 'owner-1',
          ),
          updates: const [],
          hasLoadedOnce: true,
        ),
      );

      await tester.tap(find.byTooltip('Kedi işlemleri'));
      await tester.pumpAndSettle();

      expect(find.text('Şikayet et'), findsOneWidget);
      expect(find.text('Engelle'), findsOneWidget);
    });

    testWidgets(
      'cat detail: the owner is never offered engelle on their own cat',
      (tester) async {
        await _pump(
          tester,
          CatDetailState(
            detail: CatDetail(
              id: _catId,
              name: 'tekir',
              lat: 41.0256,
              lng: 28.9744,
              areaLabel: null,
              primaryPhoto: null,
              createdAt: DateTime.utc(2026, 1, 1),
              lastUpdateAt: null,
              isOwner: true,
              ownerUserId: 'me',
            ),
            updates: const [],
            hasLoadedOnce: true,
          ),
        );

        await tester.tap(find.byTooltip('Kedi işlemleri'));
        await tester.pumpAndSettle();

        expect(find.text('Engelle'), findsNothing);
      },
    );

    // A seed cat predates accounts, so there is no account to block — the
    // affordance must not appear rather than appear and fail.
    testWidgets('cat detail: a cat with no owner account offers no engelle', (
      tester,
    ) async {
      await _pump(
        tester,
        CatDetailState(detail: _detail, updates: const [], hasLoadedOnce: true),
      );

      await tester.tap(find.byTooltip('Kedi işlemleri'));
      await tester.pumpAndSettle();

      expect(find.text('Engelle'), findsNothing);
    });

    testWidgets('timeline: another account\'s update offers engelle', (
      tester,
    ) async {
      await _pump(
        tester,
        CatDetailState(
          detail: _detail,
          updates: [
            CatUpdateEntry(
              id: 'u1',
              statuses: const ['seen'],
              comment: null,
              createdAt: DateTime.utc(2026, 1, 2),
              authorUserId: 'someone-else',
              authorDisplayName: 'Komşu',
            ),
          ],
          hasLoadedOnce: true,
        ),
      );

      await tester.ensureVisible(find.byTooltip('Güncelleme işlemleri'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Güncelleme işlemleri'));
      await tester.pumpAndSettle();

      expect(find.text('Engelle'), findsOneWidget);
    });
  });

  group('report affordance (issue #233)', () {
    testWidgets(
      'cat detail: the bildir icon renders for both owner and non-owner',
      (tester) async {
        for (final isOwner in [true, false]) {
          await _pump(
            tester,
            CatDetailState(
              detail: CatDetail(
                id: _catId,
                name: 'tekir',
                lat: 41.0256,
                lng: 28.9744,
                areaLabel: null,
                primaryPhoto: null,
                createdAt: DateTime.utc(2026, 1, 1),
                lastUpdateAt: null,
                isOwner: isOwner,
              ),
              updates: const [],
              hasLoadedOnce: true,
            ),
          );

          expect(find.byTooltip('Kedi işlemleri'), findsOneWidget);
        }
      },
    );

    testWidgets(
      'cat detail: tapping bildir as a guest shows the auth gate, never the sheet directly',
      (tester) async {
        await _pump(
          tester,
          CatDetailState(
            detail: _detail,
            updates: const [],
            hasLoadedOnce: true,
          ),
        );

        await tester.tap(find.byTooltip('Kedi işlemleri'));
        await tester.pumpAndSettle();

        expect(find.text('İçeriği bildirmek için giriş yap'), findsOneWidget);
        expect(find.text('İçeriği bildir'), findsNothing);
      },
    );

    testWidgets(
      'timeline: an entry without an open correction window shows bildir instead',
      (tester) async {
        await _pump(
          tester,
          CatDetailState(
            detail: _detail,
            updates: [
              CatUpdateEntry(
                id: 'u1',
                statuses: const ['seen'],
                comment: null,
                createdAt: DateTime.utc(2026, 1, 2),
              ),
            ],
            hasLoadedOnce: true,
          ),
        );

        expect(find.byTooltip('Güncelleme işlemleri'), findsOneWidget);
        expect(find.byTooltip('Güncellemeyi düzelt'), findsNothing);
      },
    );

    testWidgets(
      "timeline: the author's own entry inside its correction window shows "
      'the correction menu, never bildir',
      (tester) async {
        await _pump(
          tester,
          CatDetailState(
            detail: _detail,
            updates: [
              CatUpdateEntry(
                id: 'u1',
                statuses: const ['seen'],
                comment: null,
                createdAt: DateTime.utc(2026, 1, 2),
                authorIsMe: true,
                correctionExpiresAt: DateTime.now().add(
                  const Duration(minutes: 5),
                ),
              ),
            ],
            hasLoadedOnce: true,
          ),
        );

        expect(find.byTooltip('Güncellemeyi düzelt'), findsOneWidget);
        expect(find.byTooltip('Güncelleme işlemleri'), findsNothing);
      },
    );

    testWidgets('medya tab: each tile carries its own bildir overlay', (
      tester,
    ) async {
      await _pump(
        tester,
        CatDetailState(
          detail: CatDetail(
            id: _catId,
            name: 'tekir',
            lat: 41.0256,
            lng: 28.9744,
            areaLabel: null,
            primaryPhoto: null,
            createdAt: DateTime.utc(2026, 1, 1),
            lastUpdateAt: null,
            mediaCount: 2,
          ),
          updates: const [],
          hasLoadedOnce: true,
        ),
        media: [
          CatMediaItem(
            id: 'm1',
            url: 'https://example.com/cover.jpg',
            isCover: true,
            createdAt: DateTime.utc(2026, 1, 2),
          ),
          CatMediaItem(
            id: 'm2',
            url: 'https://example.com/other.jpg',
            isCover: false,
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        ],
      );

      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pump();
      await tester.tap(find.text('medya'));
      await tester.pump();
      await tester.pump();

      expect(
        find.descendant(
          of: find.byType(GridView),
          matching: find.byIcon(Icons.more_vert),
        ),
        findsNWidgets(2),
      );
    });
  });

  group('issue #121 media parity', () {
    testWidgets(
      'cover photo counter: shown with the real media_count, hidden at zero',
      (tester) async {
        await _pump(
          tester,
          CatDetailState(
            detail: CatDetail(
              id: _catId,
              name: 'tekir',
              lat: 41.0256,
              lng: 28.9744,
              areaLabel: null,
              primaryPhoto: null,
              createdAt: DateTime.utc(2026, 1, 1),
              lastUpdateAt: null,
              mediaCount: 3,
            ),
            updates: const [],
            hasLoadedOnce: true,
          ),
        );

        expect(find.byIcon(Icons.camera_alt_outlined), findsOneWidget);
        // both the cover pill and the segmented control's "medya" badge
        // read the same real media_count — two "3"s, not an invented one.
        expect(find.text('3'), findsNWidgets(2));
      },
    );

    testWidgets('cover photo counter: never shown when media_count is zero', (
      tester,
    ) async {
      await _pump(
        tester,
        CatDetailState(detail: _detail, updates: const [], hasLoadedOnce: true),
      );

      expect(find.byIcon(Icons.camera_alt_outlined), findsNothing);
    });

    testWidgets(
      'timeline thumbnail: rendered only when an entry carries a photo_url',
      (tester) async {
        await _pump(
          tester,
          CatDetailState(
            detail: _detail,
            updates: [
              CatUpdateEntry(
                id: 'u1',
                statuses: const ['seen'],
                comment: null,
                createdAt: DateTime.utc(2026, 1, 2),
                photoUrl: 'https://example.com/photo.jpg',
              ),
              CatUpdateEntry(
                id: 'u2',
                statuses: const ['fed'],
                comment: null,
                createdAt: DateTime.utc(2026, 1, 1),
              ),
            ],
            hasLoadedOnce: true,
          ),
        );

        expect(find.byType(CachedNetworkImage), findsOneWidget);
      },
    );

    testWidgets(
      'timeline thumbnail: a video-carrying entry renders as a video, '
      'never as a plain image (issue #153)',
      (tester) async {
        await _pump(
          tester,
          CatDetailState(
            detail: _detail,
            updates: [
              CatUpdateEntry(
                id: 'u1',
                statuses: const ['seen'],
                comment: null,
                createdAt: DateTime.utc(2026, 1, 2),
                photoUrl: 'https://example.com/clip.mp4',
                mediaContentType: 'video/mp4',
              ),
            ],
            hasLoadedOnce: true,
          ),
        );

        expect(find.byType(CachedNetworkImage), findsNothing);
        expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
      },
    );

    testWidgets('medya tab: switching shows the archive grid with the ana '
        'badge on the cover entry, never on any other', (tester) async {
      await _pump(
        tester,
        CatDetailState(
          detail: CatDetail(
            id: _catId,
            name: 'tekir',
            lat: 41.0256,
            lng: 28.9744,
            areaLabel: null,
            primaryPhoto: null,
            createdAt: DateTime.utc(2026, 1, 1),
            lastUpdateAt: null,
            mediaCount: 2,
          ),
          updates: const [],
          hasLoadedOnce: true,
        ),
        media: [
          CatMediaItem(
            id: 'm1',
            url: 'https://example.com/cover.jpg',
            isCover: true,
            createdAt: DateTime.utc(2026, 1, 2),
            uploaderDisplayName: 'asli',
          ),
          CatMediaItem(
            id: 'm2',
            url: 'https://example.com/other.jpg',
            isCover: false,
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        ],
      );

      // The segmented control sits below the fold at the default test
      // viewport size — scroll it into view before tapping.
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pump();
      await tester.tap(find.text('medya'));
      await tester.pump();
      await tester.pump();

      expect(find.text('profil'), findsOneWidget);
      expect(find.byType(CachedNetworkImage), findsNWidgets(2));
      // issue #154: the uploader's name surfaces via the same tile the
      // "ana" badge sits on, consistent with the timeline's own avatar.
      expect(find.byTooltip('asli'), findsOneWidget);
    });

    testWidgets(
      'medya tab: a video-carrying entry renders as a video thumbnail, '
      'never as a plain image (issue #179)',
      (tester) async {
        await _pump(
          tester,
          CatDetailState(
            detail: CatDetail(
              id: _catId,
              name: 'tekir',
              lat: 41.0256,
              lng: 28.9744,
              areaLabel: null,
              primaryPhoto: null,
              createdAt: DateTime.utc(2026, 1, 1),
              lastUpdateAt: null,
              mediaCount: 1,
            ),
            updates: const [],
            hasLoadedOnce: true,
          ),
          media: [
            CatMediaItem(
              id: 'm1',
              url: 'https://example.com/clip.mp4',
              isCover: false,
              createdAt: DateTime.utc(2026, 1, 1),
              mediaContentType: 'video/mp4',
            ),
          ],
        );

        await tester.drag(find.byType(ListView), const Offset(0, -400));
        await tester.pump();
        await tester.tap(find.text('medya'));
        await tester.pump();
        await tester.pump();

        expect(find.byType(CachedNetworkImage), findsNothing);
        expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
      },
    );

    testWidgets(
      'medya tab: a video thumbnail forces a real decoded frame instead of '
      'staying blank once its controller finishes initializing (issue #198)',
      (tester) async {
        final platform = _ScriptedVideoPlayerPlatform();
        VideoPlayerPlatform.instance = platform;
        addTearDown(
          () => VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform(),
        );

        await _pump(
          tester,
          CatDetailState(
            detail: CatDetail(
              id: _catId,
              name: 'tekir',
              lat: 41.0256,
              lng: 28.9744,
              areaLabel: null,
              primaryPhoto: null,
              createdAt: DateTime.utc(2026, 1, 1),
              lastUpdateAt: null,
              mediaCount: 1,
            ),
            updates: const [],
            hasLoadedOnce: true,
          ),
          media: [
            CatMediaItem(
              id: 'm1',
              url: 'https://example.com/clip.mp4',
              isCover: false,
              createdAt: DateTime.utc(2026, 1, 1),
              mediaContentType: 'video/mp4',
            ),
          ],
        );

        await tester.drag(find.byType(ListView), const Offset(0, -400));
        await tester.pump();
        await tester.tap(find.text('medya'));
        await tester.pump();
        await tester.pump();
        // lets the initialize()/play()/pause() chain _VideoThumbnail kicks
        // off once initialize's stream event lands actually run to completion.
        await tester.pump();
        await tester.pump();

        // The blank/white-cover bug (issue #198) was that a video's
        // texture never advanced past an empty frame because nothing ever
        // called play() — initialize() alone only decodes metadata. This
        // is the fix's own mechanism: play() then pause() right after
        // initialize completes, so the platform player actually decodes
        // and holds a real frame.
        expect(platform.playCalls, isNotEmpty);
        expect(platform.pauseCalls, isNotEmpty);
      },
    );

    testWidgets(
      'medya tab: a video thumbnail falls back to the branded placeholder, '
      'never a blank frame, when decoding genuinely fails (issue #198)',
      (tester) async {
        final platform = _ScriptedVideoPlayerPlatform(
          initializeError: PlatformException(
            code: 'VideoError',
            message: 'decode failed',
          ),
        );
        VideoPlayerPlatform.instance = platform;
        addTearDown(
          () => VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform(),
        );

        await _pump(
          tester,
          CatDetailState(
            detail: CatDetail(
              id: _catId,
              name: 'tekir',
              lat: 41.0256,
              lng: 28.9744,
              areaLabel: null,
              primaryPhoto: null,
              createdAt: DateTime.utc(2026, 1, 1),
              lastUpdateAt: null,
              mediaCount: 1,
            ),
            updates: const [],
            hasLoadedOnce: true,
          ),
          media: [
            CatMediaItem(
              id: 'm1',
              url: 'https://example.com/clip.mp4',
              isCover: false,
              createdAt: DateTime.utc(2026, 1, 1),
              mediaContentType: 'video/mp4',
            ),
          ],
        );

        await tester.drag(find.byType(ListView), const Offset(0, -400));
        await tester.pump();
        await tester.tap(find.text('medya'));
        await tester.pump();
        await tester.pump();
        await tester.pump();
        await tester.pump();

        // A failed decode gets the same branded fallback a failed photo
        // load already uses (never a blank texture) — scoped to the grid
        // so this doesn't also match the screen's own top cover, which
        // renders the identical icon for its own unrelated "no photo"
        // state in this fixture.
        expect(
          find.descendant(
            of: find.byType(GridView),
            matching: find.byIcon(Icons.pets),
          ),
          findsOneWidget,
        );
        expect(platform.playCalls, isEmpty);
      },
    );

    testWidgets('medya tab: an empty archive shows the empty-state message', (
      tester,
    ) async {
      await _pump(
        tester,
        CatDetailState(detail: _detail, updates: const [], hasLoadedOnce: true),
      );

      // The segmented control sits below the fold at the default test
      // viewport size — scroll it into view before tapping.
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pump();
      await tester.tap(find.text('medya'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Henüz medya yok'), findsOneWidget);
    });

    // ── cover photo change (issue #156) ─────

    final ownerMedia = [
      CatMediaItem(
        id: 'm1',
        url: 'https://example.com/cover.jpg',
        isCover: true,
        createdAt: DateTime.utc(2026, 1, 2),
      ),
      CatMediaItem(
        id: 'm2',
        url: 'https://example.com/other.jpg',
        isCover: false,
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    ];

    CatDetailState ownerState({required bool isOwner}) => CatDetailState(
      detail: CatDetail(
        id: _catId,
        name: 'tekir',
        lat: 41.0256,
        lng: 28.9744,
        areaLabel: null,
        primaryPhoto: null,
        createdAt: DateTime.utc(2026, 1, 1),
        lastUpdateAt: null,
        mediaCount: 2,
        isOwner: isOwner,
      ),
      updates: const [],
      hasLoadedOnce: true,
    );

    Future<void> openFullScreenFor(WidgetTester tester, String url) async {
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pump();
      await tester.tap(find.text('medya'));
      await tester.pump();
      await tester.pump();
      final tile = find.byWidgetPredicate(
        (w) => w is CachedNetworkImage && w.imageUrl == url,
      );
      // the fixed "+ update" bar overlaps the bottom of the grid at this
      // viewport size — ensureVisible scrolls the tile clear of it before
      // tapping, rather than guessing a drag distance that happens to work.
      await tester.ensureVisible(tile);
      await tester.pump();
      await tester.tap(tile);
      // not pumpAndSettle: the fixture urls are fake network addresses, so
      // CachedNetworkImage's own retry/error handling never truly settles —
      // the same reason every other network-image assertion in this file
      // uses a fixed pump count instead (see the medya-tab test above).
      await tester.pump();
      await tester.pump();
    }

    testWidgets(
      'owner: a non-cover tile opens with "profil fotoğrafı yap" enabled',
      (tester) async {
        await _pump(
          tester,
          ownerState(isOwner: true),
          api: _FakeCatMediaApi(ownerMedia),
        );

        await openFullScreenFor(tester, 'https://example.com/other.jpg');

        expect(find.text('profil fotoğrafı yap'), findsOneWidget);
      },
    );

    testWidgets('owner: the current cover tile shows the passive label', (
      tester,
    ) async {
      await _pump(
        tester,
        ownerState(isOwner: true),
        api: _FakeCatMediaApi(ownerMedia),
      );

      await openFullScreenFor(tester, 'https://example.com/cover.jpg');

      expect(find.text('profil fotoğrafı'), findsOneWidget);
      expect(find.text('profil fotoğrafı yap'), findsNothing);
    });

    testWidgets('non-owner: the full-screen view carries no cover action', (
      tester,
    ) async {
      await _pump(
        tester,
        ownerState(isOwner: false),
        api: _FakeCatMediaApi(ownerMedia),
      );

      await openFullScreenFor(tester, 'https://example.com/other.jpg');

      expect(find.text('profil fotoğrafı yap'), findsNothing);
      expect(find.text('profil fotoğrafı'), findsNothing);
    });

    testWidgets(
      'owner: a video tile opens the video player with no cover action '
      '(issue #179 — a video can never become the cover)',
      (tester) async {
        final videoMedia = [
          ...ownerMedia,
          CatMediaItem(
            id: 'm3',
            url: 'https://example.com/clip.mp4',
            isCover: false,
            createdAt: DateTime.utc(2026, 1, 3),
            mediaContentType: 'video/mp4',
          ),
        ];
        await _pump(
          tester,
          ownerState(isOwner: true),
          api: _FakeCatMediaApi(videoMedia),
        );

        await tester.drag(find.byType(ListView), const Offset(0, -400));
        await tester.pump();
        await tester.tap(find.text('medya'));
        await tester.pump();
        await tester.pump();
        final tile = find.byWidgetPredicate(
          (w) => w is Icon && w.icon == Icons.play_circle_fill,
        );
        await tester.ensureVisible(tile);
        await tester.pump();
        await tester.tap(tile);
        await tester.pump();
        await tester.pump();

        expect(find.text('profil fotoğrafı yap'), findsNothing);
        expect(find.text('profil fotoğrafı'), findsNothing);
      },
    );

    testWidgets(
      'a muted video entry (issue #194) offers no unmute affordance at all — '
      'the stored flag is honored, not just the playback-level default',
      (tester) async {
        final videoMedia = [
          CatMediaItem(
            id: 'm1',
            url: 'https://example.com/clip.mp4',
            isCover: false,
            createdAt: DateTime.utc(2026, 1, 3),
            mediaContentType: 'video/mp4',
            mediaMuted: true,
          ),
        ];
        await _pump(
          tester,
          ownerState(isOwner: false),
          api: _FakeCatMediaApi(videoMedia),
        );

        await tester.drag(find.byType(ListView), const Offset(0, -400));
        await tester.pump();
        await tester.tap(find.text('medya'));
        await tester.pump();
        await tester.pump();
        final tile = find.byWidgetPredicate(
          (w) => w is Icon && w.icon == Icons.play_circle_fill,
        );
        await tester.ensureVisible(tile);
        await tester.pump();
        await tester.tap(tile);
        await tester.pump();
        await tester.pump();

        expect(find.byIcon(Icons.volume_off), findsNothing);
        expect(find.byIcon(Icons.volume_up), findsNothing);
      },
    );

    testWidgets(
      'an unmuted video entry (issue #194) offers an unmute affordance, '
      'starting muted regardless (playback-level default)',
      (tester) async {
        final videoMedia = [
          CatMediaItem(
            id: 'm1',
            url: 'https://example.com/clip.mp4',
            isCover: false,
            createdAt: DateTime.utc(2026, 1, 3),
            mediaContentType: 'video/mp4',
            mediaMuted: false,
          ),
        ];
        await _pump(
          tester,
          ownerState(isOwner: false),
          api: _FakeCatMediaApi(videoMedia),
        );

        await tester.drag(find.byType(ListView), const Offset(0, -400));
        await tester.pump();
        await tester.tap(find.text('medya'));
        await tester.pump();
        await tester.pump();
        final tile = find.byWidgetPredicate(
          (w) => w is Icon && w.icon == Icons.play_circle_fill,
        );
        await tester.ensureVisible(tile);
        await tester.pump();
        await tester.tap(tile);
        await tester.pump();
        await tester.pump();

        // Starts muted (issue #194's playback-level default) even though
        // the stored flag allows audio — the volume_off glyph is the
        // unmute affordance itself, offered only because mediaMuted is
        // false.
        expect(find.byIcon(Icons.volume_off), findsOneWidget);
        expect(find.byIcon(Icons.volume_up), findsNothing);
      },
    );

    testWidgets(
      'owner: tapping "profil fotoğrafı yap" submits and closes the view',
      (tester) async {
        final api = _FakeCatMediaApi(
          ownerMedia,
          CatDetail(
            id: _catId,
            name: 'tekir',
            lat: 41.0256,
            lng: 28.9744,
            areaLabel: null,
            primaryPhoto: 'https://example.com/other.jpg',
            createdAt: DateTime.utc(2026, 1, 1),
            lastUpdateAt: null,
            mediaCount: 2,
            isOwner: true,
          ),
        );
        await _pump(tester, ownerState(isOwner: true), api: api);

        await openFullScreenFor(tester, 'https://example.com/other.jpg');
        await tester.tap(find.text('profil fotoğrafı yap'));
        await tester.pump();
        await tester.pump();
        await tester.pump();

        expect(api.capturedSetCoverCatId, _catId);
        expect(api.capturedSetCoverMediaId, 'm2');
        // the full-screen view pops back to the medya grid on success.
        expect(find.text('profil fotoğrafı yap'), findsNothing);
      },
    );
  });

  group('rename affordance (issue #227)', () {
    CatDetail detailWith({required bool isOwner}) => CatDetail(
      id: _catId,
      name: 'tekir',
      lat: 41.0256,
      lng: 28.9744,
      areaLabel: null,
      primaryPhoto: null,
      createdAt: DateTime.utc(2026, 1, 1),
      lastUpdateAt: null,
      isOwner: isOwner,
    );

    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'owner: the name is tappable with a faint rename glyph beside it',
      (tester) async {
        await _pump(
          tester,
          CatDetailState(
            detail: detailWith(isOwner: true),
            updates: const [],
            hasLoadedOnce: true,
          ),
        );

        expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      },
    );

    testWidgets('non-owner (another signed-in account, or a guest): no rename '
        'affordance at all — is_owner is false either way, and the client '
        'never distinguishes the two', (tester) async {
      await _pump(
        tester,
        CatDetailState(
          detail: detailWith(isOwner: false),
          updates: const [],
          hasLoadedOnce: true,
        ),
      );

      expect(find.byIcon(Icons.edit_outlined), findsNothing);
    });

    testWidgets(
      'empty/whitespace-only input is rejected before ever calling the api',
      (tester) async {
        final api = _FakeCatMediaApi();
        await _pump(
          tester,
          CatDetailState(
            detail: detailWith(isOwner: true),
            updates: const [],
            hasLoadedOnce: true,
          ),
          api: api,
        );

        await openSheet(tester);
        await tester.enterText(find.byType(TextField), '   ');
        await tester.tap(find.text('Kaydet'));
        await tester.pump();

        expect(find.text('Bir isim gir'), findsOneWidget);
        expect(api.capturedRenameName, isNull);
      },
    );

    testWidgets(
      'a successful rename updates the name on screen without a manual refresh',
      (tester) async {
        final api = _FakeCatMediaApi()
          ..renameResult = CatDetail(
            id: _catId,
            name: 'boncuk',
            lat: 41.0256,
            lng: 28.9744,
            areaLabel: null,
            primaryPhoto: null,
            createdAt: DateTime.utc(2026, 1, 1),
            lastUpdateAt: null,
            isOwner: true,
          );
        await _pump(
          tester,
          CatDetailState(
            detail: detailWith(isOwner: true),
            updates: const [],
            hasLoadedOnce: true,
          ),
          api: api,
        );

        await openSheet(tester);
        await tester.enterText(find.byType(TextField), 'boncuk');
        await tester.tap(find.text('Kaydet'));
        await tester.pump();
        await tester.pump();

        expect(api.capturedRenameCatId, _catId);
        expect(api.capturedRenameName, 'boncuk');
        expect(find.text('boncuk'), findsWidgets);
        expect(find.text('tekir'), findsNothing);
        // the sheet closes on success — its own save button is gone.
        expect(find.text('Kaydet'), findsNothing);
      },
    );

    testWidgets(
      '403 (not the owner) surfaces as an error and leaves the old name in place',
      (tester) async {
        final api = _FakeCatMediaApi()
          ..renameError = const RenameCatForbiddenException();
        await _pump(
          tester,
          CatDetailState(
            detail: detailWith(isOwner: true),
            updates: const [],
            hasLoadedOnce: true,
          ),
          api: api,
        );

        await openSheet(tester);
        await tester.enterText(find.byType(TextField), 'boncuk');
        await tester.tap(find.text('Kaydet'));
        await tester.pump();
        await tester.pump();

        expect(
          find.text('Sunucuya ulaşılamadı, birazdan tekrar dene.'),
          findsOneWidget,
        );
        expect(find.text('tekir'), findsWidgets);
      },
    );

    testWidgets(
      '404 (cat not found) surfaces as an error and leaves the old name in place',
      (tester) async {
        final api = _FakeCatMediaApi()
          ..renameError = const CatNotFoundException();
        await _pump(
          tester,
          CatDetailState(
            detail: detailWith(isOwner: true),
            updates: const [],
            hasLoadedOnce: true,
          ),
          api: api,
        );

        await openSheet(tester);
        await tester.enterText(find.byType(TextField), 'boncuk');
        await tester.tap(find.text('Kaydet'));
        await tester.pump();
        await tester.pump();

        expect(
          find.text('Sunucuya ulaşılamadı, birazdan tekrar dene.'),
          findsOneWidget,
        );
        expect(find.text('tekir'), findsWidgets);
      },
    );

    testWidgets(
      'a network failure surfaces its own distinct error and leaves the old '
      'name in place',
      (tester) async {
        final api = _FakeCatMediaApi()
          ..renameError = const UpdateNetworkException();
        await _pump(
          tester,
          CatDetailState(
            detail: detailWith(isOwner: true),
            updates: const [],
            hasLoadedOnce: true,
          ),
          api: api,
        );

        await openSheet(tester);
        await tester.enterText(find.byType(TextField), 'boncuk');
        await tester.tap(find.text('Kaydet'));
        await tester.pump();
        await tester.pump();

        expect(find.text('Bağlantı sorunu, tekrar dene.'), findsOneWidget);
        expect(find.text('tekir'), findsWidgets);
      },
    );
  });

  group('delete affordance (issue #228)', () {
    CatDetail detailWith({required bool isOwner}) => CatDetail(
      id: _catId,
      name: 'tekir',
      lat: 41.0256,
      lng: 28.9744,
      areaLabel: null,
      primaryPhoto: null,
      createdAt: DateTime.utc(2026, 1, 1),
      lastUpdateAt: null,
      isOwner: isOwner,
    );

    // Unlike _pump above, this pushes the screen onto a real GoRouter with a
    // previous route beneath it — the delete flow's own success path calls
    // context.pop() (product-owner decision: back to whichever screen
    // opened the cat detail view), which needs a real router in the tree
    // and something to land on.
    Future<void> pumpRouted(
      WidgetTester tester,
      CatDetailState state, {
      _FakeCatMediaApi? api,
    }) async {
      final router = GoRouter(
        initialLocation: '/previous',
        routes: [
          GoRoute(
            path: '/previous',
            builder: (context, state) =>
                const Scaffold(body: Text('önceki ekran')),
          ),
          GoRoute(
            path: '/cats/:id',
            builder: (context, state) => const CatDetailScreen(catId: _catId),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            catDetailProvider(
              _catId,
            ).overrideWith(() => _FixedCatDetailNotifier(_catId, state)),
            sessionIdentityServiceProvider.overrideWithValue(
              _GuestSessionIdentityService(),
            ),
            catDetailApiProvider.overrideWithValue(api ?? _FakeCatMediaApi()),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      router.push('/cats/$_catId');
      await tester.pumpAndSettle();
    }

    testWidgets('owner: a delete affordance sits beside the rename glyph', (
      tester,
    ) async {
      await pumpRouted(
        tester,
        CatDetailState(
          detail: detailWith(isOwner: true),
          updates: const [],
          hasLoadedOnce: true,
        ),
      );

      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });

    testWidgets('non-owner (another signed-in account, or a guest): no delete '
        'affordance at all — is_owner is false either way, and the client '
        'never distinguishes the two', (tester) async {
      await pumpRouted(
        tester,
        CatDetailState(
          detail: detailWith(isOwner: false),
          updates: const [],
          hasLoadedOnce: true,
        ),
      );

      expect(find.byIcon(Icons.delete_outline), findsNothing);
    });

    testWidgets(
      'cancelling the confirmation leaves the cat in place and never calls '
      'the api',
      (tester) async {
        final api = _FakeCatMediaApi();
        await pumpRouted(
          tester,
          CatDetailState(
            detail: detailWith(isOwner: true),
            updates: const [],
            hasLoadedOnce: true,
          ),
          api: api,
        );

        await tester.tap(find.byIcon(Icons.delete_outline));
        await tester.pumpAndSettle();

        expect(
          find.text(
            'Bu kediyi silmek istediğine emin misin? Bu işlem geri alınamaz.',
          ),
          findsOneWidget,
        );

        await tester.tap(find.text('Vazgeç'));
        await tester.pumpAndSettle();

        expect(api.capturedDeleteCatId, isNull);
        expect(find.text('tekir'), findsWidgets);
        expect(find.text('önceki ekran'), findsNothing);
      },
    );

    testWidgets(
      'a successful delete calls the api, leaves the cat detail screen, and '
      'shows the turkish success toast',
      (tester) async {
        final api = _FakeCatMediaApi();
        await pumpRouted(
          tester,
          CatDetailState(
            detail: detailWith(isOwner: true),
            updates: const [],
            hasLoadedOnce: true,
          ),
          api: api,
        );

        await tester.tap(find.byIcon(Icons.delete_outline));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sil'));
        await tester.pumpAndSettle();

        expect(api.capturedDeleteCatId, _catId);
        // back on whichever screen opened the cat detail view — never a
        // forced destination (product-owner decision).
        expect(find.text('önceki ekran'), findsOneWidget);
        expect(find.text('Kedi silindi.'), findsOneWidget);
      },
    );

    testWidgets(
      '403 (not the owner) surfaces as an error and leaves the cat in place',
      (tester) async {
        final api = _FakeCatMediaApi()
          ..deleteError = const DeleteCatForbiddenException();
        await pumpRouted(
          tester,
          CatDetailState(
            detail: detailWith(isOwner: true),
            updates: const [],
            hasLoadedOnce: true,
          ),
          api: api,
        );

        await tester.tap(find.byIcon(Icons.delete_outline));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sil'));
        await tester.pumpAndSettle();

        expect(find.text('Kedi silinemedi, tekrar dene.'), findsOneWidget);
        expect(find.text('tekir'), findsWidgets);
        expect(find.text('önceki ekran'), findsNothing);
      },
    );

    testWidgets(
      '404 (cat not found) surfaces as an error and leaves the cat in place',
      (tester) async {
        final api = _FakeCatMediaApi()
          ..deleteError = const CatNotFoundException();
        await pumpRouted(
          tester,
          CatDetailState(
            detail: detailWith(isOwner: true),
            updates: const [],
            hasLoadedOnce: true,
          ),
          api: api,
        );

        await tester.tap(find.byIcon(Icons.delete_outline));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sil'));
        await tester.pumpAndSettle();

        expect(find.text('Kedi silinemedi, tekrar dene.'), findsOneWidget);
        expect(find.text('tekir'), findsWidgets);
        expect(find.text('önceki ekran'), findsNothing);
      },
    );

    testWidgets(
      'a network failure surfaces as an error and leaves the cat in place',
      (tester) async {
        final api = _FakeCatMediaApi()
          ..deleteError = const UpdateNetworkException();
        await pumpRouted(
          tester,
          CatDetailState(
            detail: detailWith(isOwner: true),
            updates: const [],
            hasLoadedOnce: true,
          ),
          api: api,
        );

        await tester.tap(find.byIcon(Icons.delete_outline));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sil'));
        await tester.pumpAndSettle();

        expect(find.text('Kedi silinemedi, tekrar dene.'), findsOneWidget);
        expect(find.text('tekir'), findsWidgets);
        expect(find.text('önceki ekran'), findsNothing);
      },
    );
  });

  // The backend serves one full-resolution image everywhere, so an
  // unconstrained decode is ~47 MB per photo and a few live at once cross
  // iOS's memory high watermark. Every image on this screen must therefore
  // declare the size it is painted at.
  testWidgets('every network image on cat detail caps its decode size', (
    tester,
  ) async {
    await _pump(
      tester,
      CatDetailState(
        detail: CatDetail(
          id: _catId,
          name: 'tekir',
          lat: 41.0256,
          lng: 28.9744,
          areaLabel: null,
          primaryPhoto: 'https://example.invalid/cover.jpg',
          createdAt: DateTime.utc(2026, 1, 1),
          lastUpdateAt: null,
          mediaCount: 1,
        ),
        updates: const [],
        hasLoadedOnce: true,
      ),
      media: [
        CatMediaItem(
          id: 'm1',
          url: 'https://example.invalid/m1.jpg',
          mediaContentType: 'image/jpeg',
          isCover: false,
          createdAt: DateTime.utc(2026, 1, 3),
        ),
      ],
    );
    await tester.pump();

    final images = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .toList();
    expect(images, isNotEmpty);
    for (final image in images) {
      expect(
        image.memCacheWidth,
        isNotNull,
        reason: 'missing memCacheWidth on ${image.imageUrl}',
      );
    }
  });
}
