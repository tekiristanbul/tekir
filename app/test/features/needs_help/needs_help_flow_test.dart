import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:app/core/identity/device_identity.dart';
import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/auth/data/auth_api.dart';
import 'package:app/features/auth/ui/login_screen.dart';
import 'package:app/features/cat_detail/data/cat_detail.dart';
import 'package:app/features/cat_detail/data/cat_detail_api.dart';
import 'package:app/features/cat_detail/ui/cat_detail_screen.dart';
import 'package:app/features/follow/data/follows_api.dart';
import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/needs_help/data/needs_help_api.dart';
import 'package:app/features/needs_help/ui/needs_help_notifier.dart';
import 'package:app/features/needs_help/ui/needs_help_sheet.dart';

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

CatUpdateEntry _entry(String id, {String category = 'injured_or_sick'}) =>
    CatUpdateEntry(
      id: id,
      kind: 'needs_help',
      statuses: const [],
      comment: null,
      createdAt: DateTime.utc(2026, 3, 1),
      needsHelpCategory: category,
      needsHelpCategoryLabel: 'yaralı / hasta',
      needsHelpExpiresAt: DateTime.utc(2026, 3, 4),
      needsHelpActive: true,
    );

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

class _FakeNeedsHelpApi implements NeedsHelpApi {
  int createCalls = 0;
  String? lastCategory;
  String? lastComment;

  Completer<void>? gate;
  Object? nextError;
  CatUpdateEntry? nextResult;

  @override
  Future<CatUpdateEntry> create(
    String catId, {
    required String category,
    String? comment,
  }) async {
    createCalls++;
    lastCategory = category;
    lastComment = comment;
    if (gate != null) await gate!.future;
    if (nextError != null) throw nextError!;
    return nextResult!;
  }
}

class _FakeCatDetailApi implements CatDetailApi {
  @override
  Future<CatDetail> fetchDetail(String catId) async => _detail;

  @override
  Future<UpdatesPage> fetchUpdates(String catId, {String? cursor}) async =>
      const UpdatesPage(items: [], nextCursor: null);

  @override
  Future<CatUpdateEntry> createUpdate(
    String catId, {
    required List<String> statuses,
    String? comment,
  }) async => _entry('unused');

  @override
  Future<CatUpdateEntry> correctUpdate(
    String catId,
    String updateId, {
    required List<String> statuses,
    String? comment,
  }) => throw UnimplementedError();

  @override
  Future<void> deleteUpdate(String catId, String updateId) =>
      throw UnimplementedError();
}

// Real (not fixed) CatDetailNotifier so applyNeedsHelpUpdate's active-alert
// mutation is exercised end to end, mirroring cat_update_flow_test.dart's
// note that prependUpdate is inherited, not overridden, on its own fixed
// notifier — here the whole notifier is real since load() must not fire a
// network call either, and _FakeCatDetailApi.fetchDetail already returns a
// fixed detail synchronously.

class _FakeSessionIdentityService implements SessionIdentityService {
  _FakeSessionIdentityService({SessionIdentity? initial}) : _cached = initial;

  SessionIdentity? _cached;

  @override
  SessionIdentity? get cached => _cached;

  @override
  Future<SessionIdentity?> restore() async => _cached;

  @override
  Future<void> save(SessionIdentity identity) async => _cached = identity;

  @override
  Future<void> logout() async => _cached = null;
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

const _authenticatedSession = SessionIdentity(
  accessToken: 'at',
  refreshToken: 'rt',
  userId: 'u1',
);

class _FakeFollowsApi implements FollowsApi {
  @override
  Future<void> follow(String catId) async {}

  @override
  Future<void> unfollow(String catId) async {}

  @override
  Future<List<CatMarker>> fetchFollows() async => const [];
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeNeedsHelpApi needsHelpApi,
  SessionIdentityService? sessionIdentityService,
  AuthApi? authApi,
}) async {
  // The needs-help sheet (cat header row, body copy, 5-option category
  // grid, comment field, submit) is taller than the default 800x600 test
  // surface once opened over CatDetailScreen — enlarge it so the submit
  // button always stays within the hit-testable viewport.
  addTearDown(() => tester.view.resetPhysicalSize());
  tester.view.physicalSize = const Size(800, 1400);
  addTearDown(() => tester.view.resetDevicePixelRatio());
  tester.view.devicePixelRatio = 1.0;

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
        catDetailApiProvider.overrideWithValue(_FakeCatDetailApi()),
        needsHelpApiProvider.overrideWithValue(needsHelpApi),
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
      ],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ),
  );
  await tester.pump();
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(ElevatedButton, 'Yardıma ihtiyacı var'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('cat detail exposes the needs-help entry point', (tester) async {
    await _pump(tester, needsHelpApi: _FakeNeedsHelpApi());

    expect(
      find.widgetWithText(ElevatedButton, 'Yardıma ihtiyacı var'),
      findsOneWidget,
    );
  });

  testWidgets(
    'the sheet renders the fixed category vocabulary and an optional comment field, submit disabled until a category is picked',
    (tester) async {
      await _pump(tester, needsHelpApi: _FakeNeedsHelpApi());
      await _openSheet(tester);

      for (final option in needsHelpCategoryOptions) {
        expect(find.text(option.label), findsOneWidget);
      }
      expect(find.text('Yorum (opsiyonel)'), findsOneWidget);

      final submitButton = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Yardım bildirimini gönder'),
      );
      expect(submitButton.onPressed, isNull);
    },
  );

  testWidgets(
    'selecting a category submits it, closes the sheet, shows the toast, and the active alert appears on cat detail',
    (tester) async {
      final api = _FakeNeedsHelpApi()..nextResult = _entry('nh-1');
      await _pump(tester, needsHelpApi: api);
      await _openSheet(tester);

      await tester.tap(find.text('Yaralı veya hasta'));
      await tester.pump();
      await tester.tap(
        find.widgetWithText(ElevatedButton, 'Yardım bildirimini gönder'),
      );
      await tester.pumpAndSettle();

      expect(api.createCalls, 1);
      expect(api.lastCategory, 'injured_or_sick');
      expect(api.lastComment, isNull);
      expect(find.byType(NeedsHelpSheet), findsNothing);
      expect(find.text('Yardım bildirimi paylaşıldı'), findsOneWidget);
      // the newly-active alert banner is now visible without a page reload.
      expect(find.text('yaralı / hasta'), findsWidgets);
    },
  );

  testWidgets(
    'an optional comment is trimmed and sent alongside the category',
    (tester) async {
      final api = _FakeNeedsHelpApi()..nextResult = _entry('nh-1');
      await _pump(tester, needsHelpApi: api);
      await _openSheet(tester);

      await tester.tap(find.text('Mahsur kalmış'));
      await tester.enterText(
        find.byType(TextField),
        '  sağ arka ayağını basamıyor  ',
      );
      await tester.pump();
      await tester.tap(
        find.widgetWithText(ElevatedButton, 'Yardım bildirimini gönder'),
      );
      await tester.pumpAndSettle();

      expect(api.lastCategory, 'trapped');
      expect(api.lastComment, 'sağ arka ayağını basamıyor');
    },
  );

  testWidgets('submitting shows a spinner and disables the submit button', (
    tester,
  ) async {
    final gate = Completer<void>();
    final api = _FakeNeedsHelpApi()
      ..nextResult = _entry('nh-1')
      ..gate = gate;
    await _pump(tester, needsHelpApi: api);
    await _openSheet(tester);

    await tester.tap(find.text('Su gerekiyor'));
    await tester.pump();
    await tester.tap(
      find.widgetWithText(ElevatedButton, 'Yardım bildirimini gönder'),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final submitButton = tester.widget<ElevatedButton>(
      find.descendant(
        of: find.byType(NeedsHelpSheet),
        matching: find.byType(ElevatedButton),
      ),
    );
    expect(submitButton.onPressed, isNull);

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a second tap while submitting creates at most one request', (
    tester,
  ) async {
    final gate = Completer<void>();
    final api = _FakeNeedsHelpApi()
      ..nextResult = _entry('nh-1')
      ..gate = gate;
    await _pump(tester, needsHelpApi: api);
    await _openSheet(tester);

    final submitButton = find.descendant(
      of: find.byType(NeedsHelpSheet),
      matching: find.byType(ElevatedButton),
    );

    await tester.tap(find.text('Mama gerekiyor'));
    await tester.pump();
    await tester.tap(submitButton);
    await tester.pump();
    await tester.tap(submitButton, warnIfMissed: false);
    await tester.pump();

    expect(api.createCalls, 1);

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'validation failure shows its turkish message inline and offers retry',
    (tester) async {
      final api = _FakeNeedsHelpApi()
        ..nextError = const NeedsHelpValidationException();
      await _pump(tester, needsHelpApi: api);
      await _openSheet(tester);

      await tester.tap(find.text('Güvensiz bir yerde'));
      await tester.pump();
      await tester.tap(
        find.widgetWithText(ElevatedButton, 'Yardım bildirimini gönder'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          needsHelpSubmitErrorMessageTr(NeedsHelpSubmitError.validation),
        ),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(ElevatedButton, 'Tekrar dene'),
        findsOneWidget,
      );
    },
  );

  testWidgets('unauthorized failure shows its turkish message inline', (
    tester,
  ) async {
    final api = _FakeNeedsHelpApi()
      ..nextError = const NeedsHelpUnauthorizedException();
    await _pump(tester, needsHelpApi: api);
    await _openSheet(tester);

    await tester.tap(find.text('Yaralı veya hasta'));
    await tester.pump();
    await tester.tap(
      find.widgetWithText(ElevatedButton, 'Yardım bildirimini gönder'),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        needsHelpSubmitErrorMessageTr(NeedsHelpSubmitError.unauthorized),
      ),
      findsOneWidget,
    );
  });

  testWidgets('not-found failure shows its turkish message inline', (
    tester,
  ) async {
    final api = _FakeNeedsHelpApi()..nextError = const CatNotFoundException();
    await _pump(tester, needsHelpApi: api);
    await _openSheet(tester);

    await tester.tap(find.text('Yaralı veya hasta'));
    await tester.pump();
    await tester.tap(
      find.widgetWithText(ElevatedButton, 'Yardım bildirimini gönder'),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(needsHelpSubmitErrorMessageTr(NeedsHelpSubmitError.notFound)),
      findsOneWidget,
    );
  });

  testWidgets(
    'offline/network failure shows its turkish message inline (fails safely without losing the report)',
    (tester) async {
      final api = _FakeNeedsHelpApi()
        ..nextError = const NeedsHelpNetworkException();
      await _pump(tester, needsHelpApi: api);
      await _openSheet(tester);

      await tester.tap(find.text('Yaralı veya hasta'));
      await tester.pump();
      await tester.tap(
        find.widgetWithText(ElevatedButton, 'Yardım bildirimini gönder'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(needsHelpSubmitErrorMessageTr(NeedsHelpSubmitError.network)),
        findsOneWidget,
      );
      // the sheet stays open with the selection intact — nothing was lost,
      // and the same tap can simply retry.
      expect(find.byType(NeedsHelpSheet), findsOneWidget);
    },
  );

  testWidgets('server failure shows its turkish message inline', (
    tester,
  ) async {
    final api = _FakeNeedsHelpApi()
      ..nextError = const NeedsHelpServerException();
    await _pump(tester, needsHelpApi: api);
    await _openSheet(tester);

    await tester.tap(find.text('Yaralı veya hasta'));
    await tester.pump();
    await tester.tap(
      find.widgetWithText(ElevatedButton, 'Yardım bildirimini gönder'),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(needsHelpSubmitErrorMessageTr(NeedsHelpSubmitError.server)),
      findsOneWidget,
    );
  });

  // ── gate-at-intent (issue #78) ─────────────────────────────────────────

  testWidgets(
    'a guest tapping the needs-help callout sees the auth prompt and the sheet/api are never reached',
    (tester) async {
      final api = _FakeNeedsHelpApi()..nextResult = _entry('nh-1');
      await _pump(
        tester,
        needsHelpApi: api,
        sessionIdentityService: _FakeSessionIdentityService(),
      );

      await tester.tap(
        find.widgetWithText(ElevatedButton, 'Yardıma ihtiyacı var'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Yardım bildirimi oluşturmak için giriş yap'),
        findsOneWidget,
      );
      expect(find.byType(LoginScreen), findsNothing);
      expect(find.byType(NeedsHelpSheet), findsNothing);
      expect(api.createCalls, 0);
    },
  );

  testWidgets('dismissing the guest prompt ("Vazgeç") never opens the sheet', (
    tester,
  ) async {
    final api = _FakeNeedsHelpApi();
    await _pump(
      tester,
      needsHelpApi: api,
      sessionIdentityService: _FakeSessionIdentityService(),
    );

    await tester.tap(
      find.widgetWithText(ElevatedButton, 'Yardıma ihtiyacı var'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();

    expect(find.byType(NeedsHelpSheet), findsNothing);
    expect(api.createCalls, 0);
  });

  testWidgets(
    'signing in from the guest prompt resumes the original needs-help intent — the sheet opens, not an immediate submit',
    (tester) async {
      final api = _FakeNeedsHelpApi()..nextResult = _entry('nh-1');
      final authApi = _FakeAuthApi()
        ..nextSession = const AuthSession(
          accessToken: 'at',
          refreshToken: 'rt',
          userId: 'user-1',
          isNewAccount: false,
        );
      await _pump(
        tester,
        needsHelpApi: api,
        sessionIdentityService: _FakeSessionIdentityService(),
        authApi: authApi,
      );

      await tester.tap(
        find.widgetWithText(ElevatedButton, 'Yardıma ihtiyacı var'),
      );
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
      expect(find.byType(NeedsHelpSheet), findsOneWidget);
      expect(
        api.createCalls,
        0,
        reason: 'report content is never collected before auth succeeds',
      );

      await tester.tap(find.text('Yaralı veya hasta'));
      await tester.pump();
      await tester.tap(
        find.widgetWithText(ElevatedButton, 'Yardım bildirimini gönder'),
      );
      await tester.pumpAndSettle();

      expect(api.createCalls, 1);
      expect(find.text('Yardım bildirimi paylaşıldı'), findsOneWidget);
    },
  );
}
