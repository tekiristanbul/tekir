import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/device_identity.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/cat_detail/data/cat_detail.dart';
import 'package:app/features/cat_detail/data/cat_detail_api.dart';
import 'package:app/features/cat_detail/ui/cat_detail_notifier.dart';
import 'package:app/features/cat_detail/ui/cat_detail_screen.dart';
import 'package:app/features/cat_detail/ui/cat_update_composer_notifier.dart';
import 'package:app/features/cat_detail/ui/cat_update_sheet.dart';

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

CatUpdateEntry _entry(String id, {List<String> statuses = const ['seen']}) =>
    CatUpdateEntry(
      id: id,
      statuses: statuses,
      comment: null,
      createdAt: DateTime.utc(2026, 1, 3),
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

class _FakeCatDetailApi implements CatDetailApi {
  int createUpdateCalls = 0;
  List<String>? lastStatuses;
  String? lastComment;

  Completer<void>? gate;
  Object? nextError;
  CatUpdateEntry? nextResult;

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
  }) async {
    createUpdateCalls++;
    lastStatuses = statuses;
    lastComment = comment;
    if (gate != null) await gate!.future;
    if (nextError != null) throw nextError!;
    return nextResult!;
  }
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

Future<void> _pump(
  WidgetTester tester, {
  required _FakeCatDetailApi api,
  CatDetailState? detailState,
  double textScale = 1.0,
}) async {
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
            detailState ?? CatDetailState(detail: _detail, hasLoadedOnce: true),
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const CatDetailScreen(catId: _catId),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _openComposer(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(OutlinedButton, 'Güncelleme ekle'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('cat detail exposes both the one-tap and composer entry points', (
    tester,
  ) async {
    await _pump(tester, api: _FakeCatDetailApi());

    expect(find.widgetWithText(ElevatedButton, 'Gördüm'), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, 'Güncelleme ekle'),
      findsOneWidget,
    );
  });

  testWidgets(
    'one tap on Gördüm submits seen without opening a form, and shows success feedback',
    (tester) async {
      final api = _FakeCatDetailApi()..nextResult = _entry('upd-1');
      await _pump(tester, api: api);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Gördüm'));
      await tester.pumpAndSettle();

      expect(api.createUpdateCalls, 1);
      expect(api.lastStatuses, ['seen']);
      expect(find.text('Güncelleme paylaşıldı'), findsOneWidget);
      // The new entry lands in the timeline without a page reload.
      expect(find.text('görüldü'), findsOneWidget);
    },
  );

  testWidgets(
    'Güncelleme ekle opens a sheet with every approved status and an optional comment field',
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
      // Sheet closed and the success toast is shown by the parent screen.
      expect(find.text('Paylaş'), findsNothing);
      expect(find.text('Güncelleme paylaşıldı'), findsOneWidget);
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

  testWidgets('submitting shows a spinner and disables the submit button', (
    tester,
  ) async {
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

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final sheetSubmitButton = find.descendant(
      of: find.byType(CatUpdateSheet),
      matching: find.byType(ElevatedButton),
    );
    final submitButton = tester.widget<ElevatedButton>(sheetSubmitButton);
    expect(submitButton.onPressed, isNull);

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a second tap while submitting creates at most one request', (
    tester,
  ) async {
    final gate = Completer<void>();
    final api = _FakeCatDetailApi()
      ..nextResult = _entry('upd-1')
      ..gate = gate;
    await _pump(tester, api: api);
    await _openComposer(tester);

    final sheetSubmitButton = find.descendant(
      of: find.byType(CatUpdateSheet),
      matching: find.byType(ElevatedButton),
    );

    await tester.tap(find.text('Görüldü'));
    await tester.pump();
    await tester.tap(sheetSubmitButton);
    await tester.pump();
    // Button is now disabled; a warnIfMissed tap here would still only
    // resolve to the disabled button, never a second submit.
    await tester.tap(sheetSubmitButton, warnIfMissed: false);
    await tester.pump();

    expect(api.createUpdateCalls, 1);

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('validation failure shows its turkish message inline', (
    tester,
  ) async {
    final api = _FakeCatDetailApi()
      ..nextError = const UpdateValidationException();
    await _pump(tester, api: api);
    await _openComposer(tester);

    await tester.tap(find.text('Görüldü'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Paylaş'));
    await tester.pumpAndSettle();

    expect(
      find.text(updateSubmitErrorMessageTr(UpdateSubmitError.validation)),
      findsOneWidget,
    );
  });

  testWidgets('unauthorized failure shows its turkish message inline', (
    tester,
  ) async {
    final api = _FakeCatDetailApi()
      ..nextError = const UpdateUnauthorizedException();
    await _pump(tester, api: api);
    await _openComposer(tester);

    await tester.tap(find.text('Görüldü'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Paylaş'));
    await tester.pumpAndSettle();

    expect(
      find.text(updateSubmitErrorMessageTr(UpdateSubmitError.unauthorized)),
      findsOneWidget,
    );
  });

  testWidgets('not-found failure shows its turkish message inline', (
    tester,
  ) async {
    final api = _FakeCatDetailApi()..nextError = const CatNotFoundException();
    await _pump(tester, api: api);
    await _openComposer(tester);

    await tester.tap(find.text('Görüldü'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Paylaş'));
    await tester.pumpAndSettle();

    expect(
      find.text(updateSubmitErrorMessageTr(UpdateSubmitError.notFound)),
      findsOneWidget,
    );
  });

  testWidgets('offline/network failure shows its turkish message inline', (
    tester,
  ) async {
    final api = _FakeCatDetailApi()..nextError = const UpdateNetworkException();
    await _pump(tester, api: api);
    await _openComposer(tester);

    await tester.tap(find.text('Görüldü'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Paylaş'));
    await tester.pumpAndSettle();

    expect(
      find.text(updateSubmitErrorMessageTr(UpdateSubmitError.network)),
      findsOneWidget,
    );
  });

  testWidgets('server failure shows its turkish message inline', (
    tester,
  ) async {
    final api = _FakeCatDetailApi()..nextError = const UpdateServerException();
    await _pump(tester, api: api);
    await _openComposer(tester);

    await tester.tap(find.text('Görüldü'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Paylaş'));
    await tester.pumpAndSettle();

    expect(
      find.text(updateSubmitErrorMessageTr(UpdateSubmitError.server)),
      findsOneWidget,
    );
  });

  testWidgets('one-tap seen failure surfaces via a snack bar, not silently', (
    tester,
  ) async {
    final api = _FakeCatDetailApi()..nextError = const UpdateNetworkException();
    await _pump(tester, api: api);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Gördüm'));
    await tester.pumpAndSettle();

    expect(
      find.text(updateSubmitErrorMessageTr(UpdateSubmitError.network)),
      findsOneWidget,
    );
  });

  testWidgets('the quick-seen and composer actions meet the 44px tap target', (
    tester,
  ) async {
    await _pump(tester, api: _FakeCatDetailApi());

    final seenSize = tester.getSize(
      find.widgetWithText(ElevatedButton, 'Gördüm'),
    );
    final composeSize = tester.getSize(
      find.widgetWithText(OutlinedButton, 'Güncelleme ekle'),
    );
    expect(seenSize.height, greaterThanOrEqualTo(kTapMin));
    expect(composeSize.height, greaterThanOrEqualTo(kTapMin));

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
}
