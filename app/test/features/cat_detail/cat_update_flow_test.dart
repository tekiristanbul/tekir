import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:app/core/identity/device_identity.dart';
import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/states/optimistic_inline_row.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/auth/data/auth_api.dart';
import 'package:app/features/auth/ui/login_screen.dart';
import 'package:app/features/cat_detail/data/cat_detail.dart';
import 'package:app/features/cat_detail/data/cat_detail_api.dart';
import 'package:app/features/cat_detail/ui/cat_detail_notifier.dart';
import 'package:app/features/cat_detail/ui/cat_detail_screen.dart';
import 'package:app/features/cat_detail/ui/cat_update_composer_notifier.dart';
import 'package:app/features/cat_detail/ui/cat_update_sheet.dart';
import 'package:app/features/follow/data/follows_api.dart';
import 'package:app/features/map/data/cat_marker.dart';

const _catId = 'cat-1';

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

CatUpdateEntry _entry(
  String id, {
  List<String> statuses = const ['seen'],
  bool authorIsMe = false,
  DateTime? correctionExpiresAt,
}) => CatUpdateEntry(
  id: id,
  statuses: statuses,
  comment: null,
  createdAt: DateTime.utc(2026, 1, 3),
  authorIsMe: authorIsMe,
  correctionExpiresAt: correctionExpiresAt,
);

/// The server's answer to a help-carrying submission: flag set, expiry 72h
/// out, active on arrival, the comment doubling as the note.
CatUpdateEntry _helpEntry(
  String id, {
  List<String> statuses = const [],
  String? comment,
}) {
  final now = DateTime.now();
  return CatUpdateEntry(
    id: id,
    needsHelp: true,
    statuses: statuses,
    comment: comment,
    createdAt: now,
    needsHelpExpiresAt: now.add(const Duration(hours: 72)),
    needsHelpActive: true,
  );
}

// ── fakes ────────────────────────────────────────────────────────────────

class _FakeStorage implements DeviceKeyValueStorage {
  final _data = <String, String>{'device_id': 'did-1', 'device_token': 'tok-1'};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

class _FakeCatDetailApi implements CatDetailApi {
  int createUpdateCalls = 0;
  int uploadMediaCalls = 0;
  List<String>? lastStatuses;
  bool? lastNeedsHelp;
  String? lastComment;
  String? lastMediaId;
  Uint8List? lastMediaBytes;
  String? lastMediaFilename;

  Completer<void>? gate;
  Completer<void>? uploadGate;
  (int, int)? uploadProgressEvent;
  Object? nextError;
  Object? uploadError;
  CatUpdateEntry? nextResult;
  String uploadedMediaId = 'media-1';

  @override
  Future<CatDetail> fetchDetail(String catId) async => _detail;

  @override
  Future<UpdatesPage> fetchUpdates(String catId, {String? cursor}) async =>
      const UpdatesPage(items: [], nextCursor: null);

  @override
  Future<CatUpdateEntry> createUpdate(
    String catId, {
    required List<String> statuses,
    bool needsHelp = false,
    String? comment,
    String idempotencyKey = '',
    String? mediaId,
  }) async {
    createUpdateCalls++;
    lastStatuses = statuses;
    lastNeedsHelp = needsHelp;
    lastComment = comment;
    lastMediaId = mediaId;
    if (gate != null) await gate!.future;
    if (nextError != null) throw nextError!;
    return nextResult!;
  }

  @override
  Future<String> uploadMedia({
    required Uint8List mediaBytes,
    required String mediaFilename,
    required String idempotencyKey,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    uploadMediaCalls++;
    lastMediaBytes = mediaBytes;
    lastMediaFilename = mediaFilename;
    final event = uploadProgressEvent;
    if (event != null) onSendProgress?.call(event.$1, event.$2);
    if (uploadGate != null) await uploadGate!.future;
    if (uploadError != null) throw uploadError!;
    return uploadedMediaId;
  }

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
  Future<List<CatMediaItem>> fetchMedia(String catId) async => const [];

  @override
  Future<CatDetail> setCoverPhoto(String catId, String mediaId) =>
      throw UnimplementedError();
}

// Same technique as cat_detail_screen_test.dart's fixed notifier: a build()
// that returns caller-supplied state so the screen never exercises a real
// network load. prependUpdate is inherited (not overridden), so a
// successful submit still mutates this notifier's real state.
class _FixedCatDetailNotifier extends CatDetailNotifier {
  _FixedCatDetailNotifier(super.catId, this._state);

  final CatDetailState _state;

  @override
  CatDetailState build() => _state;

  @override
  Future<void> load() async {}
}

// Mirrors auth_gate_test.dart's fakes exactly, reused here so gate-at-intent
// (issue #65) can be exercised end to end for the "seen"/composer entry
// points, not just AuthGate's own generic mechanism.
class _FakeSessionIdentityService implements SessionIdentityService {
  _FakeSessionIdentityService({SessionIdentity? initial}) : _cached = initial;

  SessionIdentity? _cached;

  @override
  SessionIdentity? get cached => _cached;

  @override
  Future<SessionIdentity?> restore() async => _cached;

  @override
  Future<SessionIdentity?> refreshIfExpired() async => _cached;

  @override
  Future<void> save(SessionIdentity identity) async => _cached = identity;

  @override
  Future<void> logout({String? deviceToken}) async => _cached = null;
}

class _FakeAuthApi implements AuthApi {
  AuthSession? nextSession;

  @override
  Future<void> requestOtp(String phone) async {}

  @override
  Future<AuthSession> verifyOtp({
    required String phone,
    required String code,
  }) async => nextSession!;

  @override
  Future<void> setDisplayName(String displayName) async {}
}

class _FakeImagePickerPlatform extends ImagePickerPlatform {
  XFile? nextFile;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async => nextFile;

  @override
  Future<XFile?> getVideo({
    required ImageSource source,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    Duration? maxDuration,
  }) async => nextFile;
}

const _authenticatedSession = SessionIdentity(
  accessToken: 'at',
  refreshToken: 'rt',
  userId: 'u1',
);

final _validPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAAC0lEQVQYV2NgAAIAAAUAAen63NgAAAAASUVORK5CYII=',
);

// This file's default session is authenticated, so FollowsNotifier.build()
// would otherwise call the real followsApiProvider (a live network call) —
// this fake keeps every test here focused on the ordinary-update flow, not
// follow (issue #65 gives follow its own test files).
class _FakeFollowsApi implements FollowsApi {
  @override
  Future<void> follow(String catId) async {}

  @override
  Future<void> unfollow(String catId) async {}

  @override
  Future<List<CatMarker>> fetchFollows() async => const [];
}

/// Every test below a session override sits behind a real [GoRouter] (`/`
/// → the screen under test, `/login` → the real [LoginScreen]) so
/// [AuthGate]'s guest path — pushing `/login` — works exactly as it does in
/// the app, not just in already-authenticated tests where that branch is
/// never reached. Defaults to an authenticated session so every
/// pre-existing test in this file keeps exercising the "already signed in"
/// path unchanged (issue #65 gates the caller before this screen's own
/// submit logic ever runs).
Future<void> _pump(
  WidgetTester tester, {
  required _FakeCatDetailApi api,
  CatDetailState? detailState,
  double textScale = 1.0,
  SessionIdentityService? sessionIdentityService,
  AuthApi? authApi,
}) async {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const CatDetailScreen(catId: _catId),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) =>
            LoginScreen(contextText: state.extra as String?),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catDetailApiProvider.overrideWithValue(api),
        deviceIdentityServiceProvider.overrideWithValue(
          DeviceIdentityService(
            storage: _FakeStorage(),
            dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080')),
          ),
        ),
        sessionIdentityServiceProvider.overrideWithValue(
          sessionIdentityService ??
              _FakeSessionIdentityService(initial: _authenticatedSession),
        ),
        authApiProvider.overrideWithValue(authApi ?? _FakeAuthApi()),
        followsApiProvider.overrideWithValue(_FakeFollowsApi()),
        catDetailProvider(_catId).overrideWith(
          () => _FixedCatDetailNotifier(
            _catId,
            detailState ?? CatDetailState(detail: _detail, hasLoadedOnce: true),
          ),
        ),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light,
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _openComposer(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(ElevatedButton, '+ update'));
  await tester.pumpAndSettle();
}

Future<void> _pickPhoto(WidgetTester tester) async {
  await tester.tap(find.text('Ekle'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Galeriden fotoğraf seç'));
  await tester.pumpAndSettle();
}

void main() {
  final fakePlatform = _FakeImagePickerPlatform();
  ImagePickerPlatform.instance = fakePlatform;

  testWidgets('the screen has exactly one primary action — "+ update" — and no '
      'competing Gördüm button (binding design, cat-profile.html)', (
    tester,
  ) async {
    await _pump(tester, api: _FakeCatDetailApi());

    expect(find.widgetWithText(ElevatedButton, '+ update'), findsOneWidget);
    expect(find.text('Gördüm'), findsNothing);
    expect(find.text('Güncelleme ekle'), findsNothing);
  });

  testWidgets(
    'a seen-only submission from the sheet drops the optimistic row, which '
    'settles into the confirmed timeline entry',
    (tester) async {
      final gate = Completer<void>();
      final api = _FakeCatDetailApi()
        ..nextResult = _entry('upd-1')
        ..gate = gate;
      await _pump(tester, api: api);
      await _openComposer(tester);

      await tester.tap(find.text('Görüldü'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Paylaş'));
      // Bounded pumps: the saving row's InlineSpinner animates
      // indefinitely, so pumpAndSettle would hang while it's visible.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(api.createUpdateCalls, 1);
      expect(api.lastStatuses, ['seen']);
      expect(find.text('gördün · kaydediliyor'), findsOneWidget);
      expect(find.byType(OptimisticInlineRow), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();

      // The row is replaced by the server-confirmed entry — and the old
      // success toast is gone: the row itself was the feedback.
      expect(find.byType(OptimisticInlineRow), findsNothing);
      // "görüldü" appears twice: the three-stat header's own label
      // (issue #121) plus this entry's timeline chip.
      expect(find.text('görüldü'), findsNWidgets(2));
      expect(find.text('Güncelleme paylaşıldı'), findsNothing);
    },
  );

  testWidgets(
    '+ update opens a sheet with every approved status and an optional comment field',
    (tester) async {
      await _pump(tester, api: _FakeCatDetailApi());

      await _openComposer(tester);

      expect(find.text('Görüldü'), findsOneWidget);
      expect(find.text('Mama verildi'), findsOneWidget);
      expect(find.text('Su verildi'), findsOneWidget);
      expect(find.text('Yorum (opsiyonel)'), findsOneWidget);
      // Nothing selected yet: submit stays disabled.
      final submitButton = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Paylaş'),
      );
      expect(submitButton.onPressed, isNull);
    },
  );

  testWidgets('a picked photo previews in the sheet and can be removed', (
    tester,
  ) async {
    fakePlatform.nextFile = XFile.fromData(
      _validPngBytes,
      name: 'photo.png',
      path: 'photo.png',
    );
    await _pump(tester, api: _FakeCatDetailApi());
    await _openComposer(tester);

    await _pickPhoto(tester);

    expect(find.byType(Image), findsOneWidget);
    expect(find.byKey(const Key('removePhotoButton')), findsOneWidget);

    await tester.tap(find.byKey(const Key('removePhotoButton')));
    await tester.pump();

    expect(find.byKey(const Key('removePhotoButton')), findsNothing);
    expect(find.text('Ekle'), findsOneWidget);
  });

  testWidgets(
    'a picked video previews as a video glyph, not an image, and can be '
    'removed (issue #153)',
    (tester) async {
      fakePlatform.nextFile = XFile.fromData(
        Uint8List.fromList([1, 2, 3]),
        name: 'clip.mp4',
        path: 'clip.mp4',
        mimeType: 'video/mp4',
      );
      await _pump(tester, api: _FakeCatDetailApi());
      await _openComposer(tester);

      await tester.tap(find.text('Ekle'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Galeriden video seç'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pickedVideoPreview')), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(find.byKey(const Key('removePhotoButton')), findsOneWidget);

      await tester.tap(find.byKey(const Key('removePhotoButton')));
      await tester.pump();

      expect(find.byKey(const Key('removePhotoButton')), findsNothing);
      expect(find.text('Ekle'), findsOneWidget);
    },
  );

  testWidgets(
    'dismissing the sheet with a picked photo, unsubmitted, never leaks it '
    'into the next open — not even for the very first frame (issue #202)',
    (tester) async {
      fakePlatform.nextFile = XFile.fromData(
        _validPngBytes,
        name: 'photo.png',
        path: 'photo.png',
      );
      await _pump(tester, api: _FakeCatDetailApi());
      await _openComposer(tester);
      await _pickPhoto(tester);
      expect(find.byKey(const Key('removePhotoButton')), findsOneWidget);

      await tester.tap(find.byTooltip('Kapat'));
      await tester.pumpAndSettle();
      expect(find.byType(CatUpdateSheet), findsNothing);

      // Reopen, but only pump the one frame that mounts the sheet — an
      // earlier implementation reset the draft in a post-mount microtask,
      // so this exact frame used to still render the previous open's
      // picked photo before that reset landed on the next frame.
      await tester.tap(find.widgetWithText(ElevatedButton, '+ update'));
      await tester.pump();

      expect(find.byKey(const Key('removePhotoButton')), findsNothing);

      // Drive the reopened sheet's still-mid-flight entrance transition to
      // completion before the test ends. Left running, that ticking
      // AnimationController survives into the next test in this file (the
      // widget tree persists across testWidgets bodies) and gets ticked
      // there against a freshly reset clock, producing a negative-elapsed
      // assertion in the framework's animation code — not a real bug in
      // the app, just an unsettled animation leaking across tests.
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'multi-selecting statuses enables submit, and comment is optional',
    (tester) async {
      final api = _FakeCatDetailApi()
        ..nextResult = _entry('upd-1', statuses: const ['seen', 'fed']);
      await _pump(tester, api: api);
      await _openComposer(tester);

      await tester.tap(find.text('Görüldü'));
      await tester.tap(find.text('Mama verildi'));
      await tester.pump();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Paylaş'));
      await tester.pumpAndSettle();

      expect(api.createUpdateCalls, 1);
      expect(api.lastStatuses, ['seen', 'fed']);
      expect(api.lastComment, isNull);
      // Sheet closed immediately; the confirmed entry is on the timeline
      // and no success toast fires for the optimistic path.
      expect(find.text('Paylaş'), findsNothing);
      // "görüldü" appears twice: the three-stat header's own label
      // (issue #121) plus this entry's timeline chip.
      expect(find.text('görüldü'), findsNWidgets(2));
      expect(find.text('mama verildi'), findsOneWidget);
      expect(find.text('Güncelleme paylaşıldı'), findsNothing);
    },
  );

  testWidgets('comment cannot be submitted without at least one status', (
    tester,
  ) async {
    final api = _FakeCatDetailApi();
    await _pump(tester, api: api);
    await _openComposer(tester);

    await tester.enterText(find.byType(TextField), 'sadece bir not');
    await tester.pump();

    final submitButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Paylaş'),
    );
    expect(submitButton.onPressed, isNull);
    expect(api.createUpdateCalls, 0);
  });

  testWidgets(
    'an ordinary sheet submit closes the sheet in the same tap and shows '
    'the saving row beneath',
    (tester) async {
      final gate = Completer<void>();
      final api = _FakeCatDetailApi()
        ..nextResult = _entry('upd-1', statuses: const ['water_provided'])
        ..gate = gate;
      await _pump(tester, api: api);
      await _openComposer(tester);

      await tester.tap(find.text('Su verildi'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Paylaş'));
      // Bounded pumps while the saving row's spinner animates.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(CatUpdateSheet), findsNothing);
      expect(find.text('su verdin · kaydediliyor'), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(OptimisticInlineRow), findsNothing);
      expect(find.text('su verildi'), findsOneWidget);
    },
  );

  testWidgets(
    'while a background submission is in flight the + update action is '
    'disabled — at most one request',
    (tester) async {
      final gate = Completer<void>();
      final api = _FakeCatDetailApi()
        ..nextResult = _entry('upd-1')
        ..gate = gate;
      await _pump(tester, api: api);
      await _openComposer(tester);

      await tester.tap(find.text('Görüldü'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Paylaş'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, '+ update'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(
        find.widgetWithText(ElevatedButton, '+ update'),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(find.byType(CatUpdateSheet), findsNothing);
      expect(api.createUpdateCalls, 1);

      gate.complete();
      await tester.pumpAndSettle();
    },
  );

  for (final entry in {
    const UpdateValidationException(): UpdateSubmitError.validation,
    const UpdateUnauthorizedException(): UpdateSubmitError.unauthorized,
    const CatNotFoundException(): UpdateSubmitError.notFound,
    const UpdateNetworkException(): UpdateSubmitError.network,
    const UpdateServerException(): UpdateSubmitError.server,
  }.entries) {
    testWidgets(
      '${entry.key.runtimeType}: the optimistic row flips to failed and '
      'stays, and the cause surfaces via a snack bar',
      (tester) async {
        final api = _FakeCatDetailApi()..nextError = entry.key;
        await _pump(tester, api: api);
        await _openComposer(tester);

        await tester.tap(find.text('Görüldü'));
        await tester.pump();
        await tester.tap(find.widgetWithText(ElevatedButton, 'Paylaş'));
        await tester.pumpAndSettle();

        expect(find.text('gördün · kaydedilemedi'), findsOneWidget);
        expect(
          find.text(updateSubmitErrorMessageTr(entry.value)),
          findsOneWidget,
        );

        // The failed row never disappears on its own — still there after
        // the snack bar's lifetime.
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
        expect(find.text('gördün · kaydedilemedi'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'a photo-carrying submission stays in the sheet for upload progress, then closes on success',
    (tester) async {
      fakePlatform.nextFile = XFile.fromData(
        _validPngBytes,
        name: 'photo.png',
        path: 'photo.png',
      );
      final api = _FakeCatDetailApi()
        ..nextResult = _entry('upd-1')
        ..uploadGate = Completer<void>()
        ..uploadProgressEvent = (1, 2);
      await _pump(tester, api: api);
      await _openComposer(tester);

      await _pickPhoto(tester);
      await tester.tap(find.text('Görüldü'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Paylaş'));
      await tester.pump();

      expect(find.byType(CatUpdateSheet), findsOneWidget);
      expect(find.text('%50'), findsOneWidget);
      expect(api.uploadMediaCalls, 1);
      expect(api.lastMediaFilename, 'photo.png');

      api.uploadGate!.complete();
      await tester.pumpAndSettle();

      expect(find.byType(CatUpdateSheet), findsNothing);
      expect(api.lastMediaId, 'media-1');
      expect(find.text('görüldü'), findsNWidgets(2));
    },
  );

  testWidgets(
    'a photo upload failure stays in the sheet with a clear retryable error',
    (tester) async {
      fakePlatform.nextFile = XFile.fromData(
        _validPngBytes,
        name: 'photo.png',
        path: 'photo.png',
      );
      final api = _FakeCatDetailApi()
        ..uploadError = const UpdateMediaTooLargeException();
      await _pump(tester, api: api);
      await _openComposer(tester);

      await _pickPhoto(tester);
      await tester.tap(find.text('Görüldü'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Paylaş'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(CatUpdateSheet), findsOneWidget);
      expect(
        find.text(updateSubmitErrorMessageTr(UpdateSubmitError.mediaTooLarge)),
        findsOneWidget,
      );
      expect(find.byKey(const Key('removePhotoButton')), findsOneWidget);
      expect(api.createUpdateCalls, 0);
    },
  );

  testWidgets(
    'reopening the sheet after a failed submission restores the draft, and '
    'retrying replaces the failed row until success clears it',
    (tester) async {
      final api = _FakeCatDetailApi()
        ..nextError = const UpdateNetworkException();
      await _pump(tester, api: api);
      await _openComposer(tester);

      await tester.tap(find.text('Su verildi'));
      await tester.enterText(find.byType(TextField), 'kabı doldurdum');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Paylaş'));
      await tester.pumpAndSettle();

      expect(find.text('su verdin · kaydedilemedi'), findsOneWidget);

      // Let the failure snack bar expire so the inline banner is the only
      // place the message appears once the sheet reopens.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();

      // Reopen: the draft survived the failure — selection, comment, and
      // the inline error with its retry label.
      await _openComposer(tester);
      expect(find.text('kabı doldurdum'), findsOneWidget);
      expect(
        find.text(updateSubmitErrorMessageTr(UpdateSubmitError.network)),
        findsOneWidget,
      );

      api
        ..nextError = null
        ..nextResult = _entry('upd-1', statuses: const ['water_provided']);
      await tester.ensureVisible(
        find.widgetWithText(ElevatedButton, 'Tekrar dene'),
      );
      await tester.tap(find.widgetWithText(ElevatedButton, 'Tekrar dene'));
      await tester.pumpAndSettle();

      expect(api.createUpdateCalls, 2);
      expect(api.lastComment, 'kabı doldurdum');
      expect(find.byType(OptimisticInlineRow), findsNothing);
      expect(find.text('su verildi'), findsOneWidget);
    },
  );

  testWidgets('the + update action and status options meet the 44px tap '
      'target', (tester) async {
    await _pump(tester, api: _FakeCatDetailApi());

    final ctaSize = tester.getSize(
      find.widgetWithText(ElevatedButton, '+ update'),
    );
    expect(ctaSize.height, greaterThanOrEqualTo(kTapMin));

    await _openComposer(tester);
    final statusOptionSize = tester.getSize(find.text('Görüldü'));
    // The tappable ancestor (not just the text) meets the minimum height —
    // checked via the InkWell's rendered size.
    final inkWell = find
        .ancestor(of: find.text('Görüldü'), matching: find.byType(InkWell))
        .first;
    expect(tester.getSize(inkWell).height, greaterThanOrEqualTo(kTapMin));
    expect(statusOptionSize.height, lessThanOrEqualTo(kTapMin));
  });

  testWidgets(
    'the fixed + update bar renders without overflow at large text scale',
    (tester) async {
      await _pump(tester, api: _FakeCatDetailApi(), textScale: 2.0);

      expect(find.widgetWithText(ElevatedButton, '+ update'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the composer sheet renders without overflow on a small screen with scaled text',
    (tester) async {
      // Isolated to the sheet itself (not the full cat-detail screen behind
      // it) so this only asserts on the new composer's own layout, not
      // pre-existing screen sections outside issue #43's scope.
      addTearDown(() => tester.view.resetPhysicalSize());
      tester.view.physicalSize = const Size(320, 560);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetDevicePixelRatio());

      final api = _FakeCatDetailApi();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            catDetailApiProvider.overrideWithValue(api),
            deviceIdentityServiceProvider.overrideWithValue(
              DeviceIdentityService(
                storage: _FakeStorage(),
                dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080')),
              ),
            ),
            catDetailProvider(_catId).overrideWith(
              () => _FixedCatDetailNotifier(
                _catId,
                CatDetailState(detail: _detail, hasLoadedOnce: true),
              ),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.6)),
              child: child!,
            ),
            home: const Scaffold(body: CatUpdateSheet(catId: _catId)),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Su verildi'));
      await tester.enterText(
        find.byType(TextField),
        'uzun bir yorum yazıyorum burada, satır sayısı artsın diye',
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
    },
  );

  // ── yardıma ihtiyacı var (issue #100/#102) ─────────────────────────────

  group('help mark in the composer sheet', () {
    testWidgets(
      'before marking: the yardım option renders unselected — no banner, plain note invitation, primary submit',
      (tester) async {
        await _pump(tester, api: _FakeCatDetailApi());
        await _openComposer(tester);

        expect(find.text('yardım'), findsOneWidget);
        expect(find.text('takipçilere bildirim gider'), findsNothing);
        expect(
          find.text('ne oldu? kısaca yaz — yardıma gelen anlasın'),
          findsNothing,
        );
        expect(find.widgetWithText(ElevatedButton, 'Paylaş'), findsOneWidget);
        // no category choice exists anywhere in the flow.
        expect(find.text('Yaralı veya hasta'), findsNothing);
        expect(find.text('Mama gerekiyor'), findsNothing);
        expect(find.text('Su gerekiyor'), findsNothing);
        expect(find.text('Güvensiz bir yerde'), findsNothing);
        expect(find.text('Mahsur kalmış'), findsNothing);
      },
    );

    testWidgets(
      'selecting yardım reveals the notification banner, the note invitation, and the help submit — no status required',
      (tester) async {
        await _pump(tester, api: _FakeCatDetailApi());
        await _openComposer(tester);

        await tester.tap(find.text('yardım'));
        await tester.pump();

        expect(find.text('takipçilere bildirim gider'), findsOneWidget);
        expect(
          find.text('ne oldu? kısaca yaz — yardıma gelen anlasın'),
          findsOneWidget,
        );
        final submitButton = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'yardım çağrısıyla paylaş'),
        );
        expect(
          submitButton.onPressed,
          isNotNull,
          reason: 'the help mark alone satisfies the create invariant',
        );
      },
    );

    testWidgets(
      'a help-only submit sends the flag without statuses and lands as one timeline event with the active banner',
      (tester) async {
        final api = _FakeCatDetailApi()
          ..nextResult = _helpEntry('upd-1', comment: 'kabı bomboştu');
        await _pump(tester, api: api);
        await _openComposer(tester);

        await tester.tap(find.text('yardım'));
        await tester.pump();
        await tester.enterText(find.byType(TextField).last, 'kabı bomboştu');
        await tester.pump();
        await tester.ensureVisible(
          find.widgetWithText(ElevatedButton, 'yardım çağrısıyla paylaş'),
        );
        await tester.tap(
          find.widgetWithText(ElevatedButton, 'yardım çağrısıyla paylaş'),
        );
        await tester.pumpAndSettle();

        expect(api.createUpdateCalls, 1);
        expect(api.lastNeedsHelp, isTrue);
        expect(api.lastStatuses, isEmpty);
        expect(api.lastComment, 'kabı bomboştu');
        // sheet closed, success feedback shown, one event on the timeline.
        expect(find.byType(CatUpdateSheet), findsNothing);
        expect(find.text('Güncelleme paylaşıldı'), findsOneWidget);
        expect(find.text('yardım gerekiyor'), findsOneWidget);
        // the active state now renders on the profile, note included.
        expect(find.text('Yardıma ihtiyacı var'), findsOneWidget);
        expect(find.text('kabı bomboştu'), findsWidgets);
      },
    );

    testWidgets(
      'a combined su verildi + yardım submit is a single request and a single timeline event',
      (tester) async {
        final api = _FakeCatDetailApi()
          ..nextResult = _helpEntry(
            'upd-1',
            statuses: const ['water_provided'],
          );
        await _pump(tester, api: api);
        await _openComposer(tester);

        await tester.tap(find.text('Su verildi'));
        await tester.tap(find.text('yardım'));
        await tester.pump();
        await tester.ensureVisible(
          find.widgetWithText(ElevatedButton, 'yardım çağrısıyla paylaş'),
        );
        await tester.tap(
          find.widgetWithText(ElevatedButton, 'yardım çağrısıyla paylaş'),
        );
        await tester.pumpAndSettle();

        expect(api.createUpdateCalls, 1);
        expect(api.lastStatuses, ['water_provided']);
        expect(api.lastNeedsHelp, isTrue);
        expect(find.text('yardım gerekiyor'), findsOneWidget);
        expect(find.text('su verildi'), findsOneWidget);
      },
    );

    testWidgets(
      'while a help submission is in flight the button spins and blocks a duplicate',
      (tester) async {
        final gate = Completer<void>();
        final api = _FakeCatDetailApi()
          ..nextResult = _helpEntry('upd-1')
          ..gate = gate;
        await _pump(tester, api: api);
        await _openComposer(tester);

        final sheetSubmitButton = find.descendant(
          of: find.byType(CatUpdateSheet),
          matching: find.byType(ElevatedButton),
        );

        await tester.tap(find.text('yardım'));
        await tester.pump();
        await tester.ensureVisible(sheetSubmitButton);
        await tester.tap(sheetSubmitButton);
        await tester.pump();

        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(
          tester.widget<ElevatedButton>(sheetSubmitButton).onPressed,
          isNull,
        );
        await tester.tap(sheetSubmitButton, warnIfMissed: false);
        await tester.pump();
        expect(api.createUpdateCalls, 1);

        gate.complete();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'a failed help submission keeps the note in the field and offers retry, which succeeds',
      (tester) async {
        final api = _FakeCatDetailApi()
          ..nextError = const UpdateNetworkException();
        await _pump(tester, api: api);
        await _openComposer(tester);

        await tester.tap(find.text('yardım'));
        await tester.pump();
        await tester.enterText(
          find.byType(TextField).last,
          'kabı bomboştu ve halsizdi',
        );
        await tester.pump();
        await tester.ensureVisible(
          find.widgetWithText(ElevatedButton, 'yardım çağrısıyla paylaş'),
        );
        await tester.tap(
          find.widgetWithText(ElevatedButton, 'yardım çağrısıyla paylaş'),
        );
        // the pulsing banner never settles — pump fixed frames instead.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          find.text(updateSubmitErrorMessageTr(UpdateSubmitError.network)),
          findsOneWidget,
        );
        // the typed note is still in the field, ready to retry.
        expect(find.text('kabı bomboştu ve halsizdi'), findsOneWidget);
        final retryButton = find.widgetWithText(ElevatedButton, 'Tekrar dene');
        expect(retryButton, findsOneWidget);

        api
          ..nextError = null
          ..nextResult = _helpEntry(
            'upd-1',
            comment: 'kabı bomboştu ve halsizdi',
          );
        await tester.ensureVisible(retryButton);
        await tester.tap(retryButton);
        await tester.pumpAndSettle();

        expect(api.createUpdateCalls, 2);
        expect(api.lastComment, 'kabı bomboştu ve halsizdi');
        expect(find.text('Güncelleme paylaşıldı'), findsOneWidget);
      },
    );

    testWidgets('the yardım option meets the 44px tap target', (tester) async {
      await _pump(tester, api: _FakeCatDetailApi());
      await _openComposer(tester);

      final inkWell = find
          .ancestor(of: find.text('yardım'), matching: find.byType(InkWell))
          .first;
      expect(tester.getSize(inkWell).height, greaterThanOrEqualTo(kTapMin));
    });

    testWidgets(
      'the sheet with help selected renders without overflow on a small screen with scaled text',
      (tester) async {
        addTearDown(() => tester.view.resetPhysicalSize());
        tester.view.physicalSize = const Size(320, 560);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetDevicePixelRatio());

        final api = _FakeCatDetailApi();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              catDetailApiProvider.overrideWithValue(api),
              deviceIdentityServiceProvider.overrideWithValue(
                DeviceIdentityService(
                  storage: _FakeStorage(),
                  dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080')),
                ),
              ),
              catDetailProvider(_catId).overrideWith(
                () => _FixedCatDetailNotifier(
                  _catId,
                  CatDetailState(detail: _detail, hasLoadedOnce: true),
                ),
              ),
            ],
            child: MaterialApp(
              theme: AppTheme.light,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(1.6)),
                child: child!,
              ),
              home: const Scaffold(body: CatUpdateSheet(catId: _catId)),
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.text('yardım'), warnIfMissed: false);
        await tester.pump();
        await tester.enterText(
          find.byType(TextField).last,
          'uzun bir yardım notu yazıyorum burada, satır sayısı artsın diye',
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'reduced motion: the notification banner renders statically and the sheet settles',
      (tester) async {
        final api = _FakeCatDetailApi();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              catDetailApiProvider.overrideWithValue(api),
              deviceIdentityServiceProvider.overrideWithValue(
                DeviceIdentityService(
                  storage: _FakeStorage(),
                  dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080')),
                ),
              ),
              catDetailProvider(_catId).overrideWith(
                () => _FixedCatDetailNotifier(
                  _catId,
                  CatDetailState(detail: _detail, hasLoadedOnce: true),
                ),
              ),
            ],
            child: MaterialApp(
              theme: AppTheme.light,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!,
              ),
              home: const Scaffold(body: CatUpdateSheet(catId: _catId)),
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.text('yardım'));
        // With animations disabled, the pulsing dot must not keep the
        // frame pipeline busy — settle within a tight budget or fail.
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 5),
        );

        expect(find.text('takipçilere bildirim gider'), findsOneWidget);
      },
    );
  });

  // ── gate-at-intent (issue #65) ─────────────────────────────────────────

  testWidgets(
    'a guest tapping + update sees the auth prompt before the composer '
    'sheet ever opens, and createUpdate is never called',
    (tester) async {
      final api = _FakeCatDetailApi();
      await _pump(
        tester,
        api: api,
        sessionIdentityService: _FakeSessionIdentityService(),
      );

      await tester.tap(find.widgetWithText(ElevatedButton, '+ update'));
      await tester.pumpAndSettle();

      expect(find.text('Güncelleme paylaşmak için giriş yap'), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
      expect(
        find.byType(CatUpdateSheet),
        findsNothing,
        reason: 'the composer must never be visible before auth succeeds',
      );
      expect(api.createUpdateCalls, 0);
    },
  );

  testWidgets(
    'dismissing the guest prompt ("Vazgeç") never opens the composer',
    (tester) async {
      final api = _FakeCatDetailApi()..nextResult = _entry('upd-1');
      await _pump(
        tester,
        api: api,
        sessionIdentityService: _FakeSessionIdentityService(),
      );

      await tester.tap(find.widgetWithText(ElevatedButton, '+ update'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();

      expect(find.byType(CatUpdateSheet), findsNothing);
      expect(api.createUpdateCalls, 0);
    },
  );

  testWidgets(
    'signing in from the guest prompt resumes the original + update intent '
    'exactly once — the composer opens',
    (tester) async {
      final api = _FakeCatDetailApi()..nextResult = _entry('upd-1');
      final authApi = _FakeAuthApi()
        ..nextSession = const AuthSession(
          accessToken: 'at',
          refreshToken: 'rt',
          userId: 'user-1',
          isNewAccount: false,
        );
      await _pump(
        tester,
        api: api,
        sessionIdentityService: _FakeSessionIdentityService(),
        authApi: authApi,
      );

      await tester.tap(find.widgetWithText(ElevatedButton, '+ update'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Giriş yap'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '5321112233');
      await tester.tap(find.text('Kod gönder'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '123456');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Giriş yap'));
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsNothing);
      expect(find.byType(CatUpdateSheet), findsOneWidget);

      await tester.tap(find.text('Görüldü'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Paylaş'));
      await tester.pumpAndSettle();

      expect(api.createUpdateCalls, 1);
      expect(api.lastStatuses, ['seen']);
      // The optimistic row settled into the confirmed timeline entry.
      // "görüldü" appears twice: the three-stat header's own label
      // (issue #121) plus this entry's timeline chip.
      expect(find.text('görüldü'), findsNWidgets(2));
      expect(find.byType(OptimisticInlineRow), findsNothing);
    },
  );
}
