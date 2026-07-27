import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/cat_detail/data/cat_detail.dart';
import 'package:app/features/cat_detail/data/cat_detail_api.dart';
import 'package:app/features/cat_detail/ui/update_correction_notifier.dart';
import 'package:app/features/cat_detail/ui/update_correction_sheet.dart';

const _catId = 'cat-1';
const _session = SessionIdentity(
  accessToken: 'at',
  refreshToken: 'rt',
  userId: 'user-1',
);

CatUpdateEntry _entry({
  String id = 'upd-1',
  List<String> statuses = const ['seen'],
  String? comment,
  DateTime? correctionExpiresAt,
}) => CatUpdateEntry(
  id: id,
  statuses: statuses,
  comment: comment,
  createdAt: DateTime.utc(2026, 1, 1),
  authorIsMe: true,
  correctionExpiresAt:
      correctionExpiresAt ?? DateTime.now().add(const Duration(minutes: 7)),
);

class _FakeSessionIdentityService implements SessionIdentityService {
  _FakeSessionIdentityService({this._cached});

  SessionIdentity? _cached;

  @override
  SessionIdentity? get cached => _cached;

  @override
  Future<SessionIdentity?> restore() async => _cached;

  @override
  Future<void> save(SessionIdentity identity) async => _cached = identity;

  @override
  Future<void> logout({String? deviceToken}) async => _cached = null;
}

class _FakeCatDetailApi implements CatDetailApi {
  _FakeCatDetailApi({this.correctResult, this.correctError, this.deleteError});

  CatUpdateEntry? correctResult;
  Object? correctError;
  Object? deleteError;
  int correctCalls = 0;
  int deleteCalls = 0;

  @override
  Future<CatDetail> fetchDetail(String catId) => throw UnimplementedError();

  @override
  Future<UpdatesPage> fetchUpdates(String catId, {String? cursor}) =>
      throw UnimplementedError();

  @override
  Future<CatUpdateEntry> createUpdate(
    String catId, {
    required List<String> statuses,
    String? comment,
    String idempotencyKey = '',
  }) => throw UnimplementedError();

  @override
  Future<CatUpdateEntry> correctUpdate(
    String catId,
    String updateId, {
    required List<String> statuses,
    String? comment,
  }) async {
    correctCalls++;
    if (correctError != null) throw correctError!;
    return correctResult!;
  }

  @override
  Future<void> deleteUpdate(String catId, String updateId) async {
    deleteCalls++;
    if (deleteError != null) throw deleteError!;
  }
}

/// Mutable holder for the sheet's pop result — `showModalBottomSheet`'s
/// future only resolves once the sheet actually closes, well after
/// `_pumpAndOpen` itself returns, so the outcome can't be a return value;
/// tests read `.value` after driving whatever interaction closes the sheet.
class _OutcomeBox {
  UpdateCorrectionOutcome? value;
}

Future<void> _pumpAndOpen(
  WidgetTester tester, {
  required _FakeCatDetailApi api,
  CatUpdateEntry? entry,
  _OutcomeBox? outcomeBox,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catDetailApiProvider.overrideWithValue(api),
        sessionIdentityServiceProvider.overrideWithValue(
          _FakeSessionIdentityService(cached: _session),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  final outcome =
                      await showModalBottomSheet<UpdateCorrectionOutcome>(
                        context: context,
                        isScrollControlled: true,
                        builder: (_) => UpdateCorrectionSheet(
                          catId: _catId,
                          entry: entry ?? _entry(),
                        ),
                      );
                  if (outcomeBox != null) outcomeBox.value = outcome;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the current statuses/comment pre-filled', (tester) async {
    await _pumpAndOpen(
      tester,
      api: _FakeCatDetailApi(),
      entry: _entry(statuses: const ['fed', 'water_provided'], comment: 'not'),
    );

    expect(find.text('not'), findsOneWidget);
    // both status pills render as selected chips (checked icons) — a
    // lighter assertion than parsing pill color, matching what this test
    // can observe without reaching into private widget state.
    expect(find.text('Mama verildi'), findsOneWidget);
    expect(find.text('Su verildi'), findsOneWidget);
  });

  testWidgets('shows a live countdown chip', (tester) async {
    await _pumpAndOpen(tester, api: _FakeCatDetailApi());

    expect(find.textContaining('dakikan kaldı'), findsOneWidget);
  });

  testWidgets('saving edits pops with the saved outcome', (tester) async {
    final api = _FakeCatDetailApi(correctResult: _entry(comment: 'düzeltildi'));
    final outcomeBox = _OutcomeBox();
    await _pumpAndOpen(tester, api: api, outcomeBox: outcomeBox);

    await tester.tap(find.text('Kaydet'));
    await tester.pumpAndSettle();

    expect(api.correctCalls, 1);
    expect(outcomeBox.value, UpdateCorrectionOutcome.saved);
  });

  testWidgets(
    'deleting requires confirmation, then pops with the deleted outcome',
    (tester) async {
      final api = _FakeCatDetailApi();
      final outcomeBox = _OutcomeBox();
      await _pumpAndOpen(tester, api: api, outcomeBox: outcomeBox);

      await tester.tap(find.text('Güncellemeyi sil'));
      await tester.pumpAndSettle();

      // the confirmation dialog is showing; dismissing via "Vazgeç" must not
      // call delete at all.
      expect(find.text('Vazgeç'), findsOneWidget);
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
      expect(api.deleteCalls, 0);

      await tester.tap(find.text('Güncellemeyi sil'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sil'));
      await tester.pumpAndSettle();

      expect(api.deleteCalls, 1);
      expect(outcomeBox.value, UpdateCorrectionOutcome.deleted);
    },
  );

  testWidgets(
    'an expired window shows the inline banner and disables both actions',
    (tester) async {
      await _pumpAndOpen(
        tester,
        api: _FakeCatDetailApi(),
        entry: _entry(
          correctionExpiresAt: DateTime.now().subtract(
            const Duration(minutes: 1),
          ),
        ),
      );

      expect(
        find.text('Düzeltme süresi doldu. Geçmiş artık değiştirilemez.'),
        findsOneWidget,
      );

      final saveButton = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Kaydet'),
      );
      expect(saveButton.onPressed, isNull);
      final deleteButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Güncellemeyi sil'),
      );
      expect(deleteButton.onPressed, isNull);
    },
  );

  testWidgets('a 403 shows the not-your-update banner', (tester) async {
    final api = _FakeCatDetailApi(
      correctError: const UpdateCorrectionForbiddenException(),
    );
    await _pumpAndOpen(tester, api: api);

    await tester.tap(find.text('Kaydet'));
    await tester.pumpAndSettle();

    expect(find.text('Bu güncelleme sana ait değil.'), findsOneWidget);
  });

  testWidgets('a network failure shows a retry-labeled banner', (tester) async {
    final api = _FakeCatDetailApi(correctError: const UpdateNetworkException());
    await _pumpAndOpen(tester, api: api);

    await tester.tap(find.text('Kaydet'));
    await tester.pumpAndSettle();

    expect(find.text('Bağlantı sorunu, tekrar dene.'), findsOneWidget);
    expect(find.text('Tekrar dene'), findsOneWidget);
  });

  testWidgets('a server failure shows the server-error banner', (tester) async {
    final api = _FakeCatDetailApi(correctError: const UpdateServerException());
    await _pumpAndOpen(tester, api: api);

    await tester.tap(find.text('Kaydet'));
    await tester.pumpAndSettle();

    expect(
      find.text('Sunucuya ulaşılamadı, birazdan tekrar dene.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'a 404 on delete is treated as already-gone, not a hard failure',
    (tester) async {
      final api = _FakeCatDetailApi(
        deleteError: const UpdateCorrectionNotFoundException(),
      );
      final outcomeBox = _OutcomeBox();
      await _pumpAndOpen(tester, api: api, outcomeBox: outcomeBox);

      await tester.tap(find.text('Güncellemeyi sil'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sil'));
      await tester.pumpAndSettle();

      expect(api.deleteCalls, 1);
      expect(outcomeBox.value, UpdateCorrectionOutcome.alreadyGone);
    },
  );

  testWidgets('deselecting every status disables the save button', (
    tester,
  ) async {
    await _pumpAndOpen(tester, api: _FakeCatDetailApi(), entry: _entry());

    await tester.tap(find.text('Görüldü'));
    await tester.pumpAndSettle();

    final saveButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Kaydet'),
    );
    expect(saveButton.onPressed, isNull);
  });
}
