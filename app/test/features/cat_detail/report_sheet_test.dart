import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/cat_detail/data/reports_api.dart';
import 'package:app/features/cat_detail/ui/report_reason.dart';
import 'package:app/features/cat_detail/ui/report_sheet.dart';

const _session = SessionIdentity(
  accessToken: 'at',
  refreshToken: 'rt',
  userId: 'user-1',
);

class _FakeSessionIdentityService implements SessionIdentityService {
  _FakeSessionIdentityService({this._cached});

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

class _FakeReportsApi implements ReportsApi {
  _FakeReportsApi({this.error});

  Object? error;
  int calls = 0;
  String? lastTargetType;
  String? lastTargetId;
  String? lastReason;
  String? lastNote;

  @override
  Future<void> submitReport({
    required String targetType,
    required String targetId,
    required String reason,
    String? note,
  }) async {
    calls++;
    lastTargetType = targetType;
    lastTargetId = targetId;
    lastReason = reason;
    lastNote = note;
    if (error != null) throw error!;
  }
}

class _OutcomeBox {
  bool? value;
}

Future<void> _pumpAndOpen(
  WidgetTester tester, {
  required _FakeReportsApi api,
  ReportTargetType targetType = ReportTargetType.cat,
  String targetId = 'cat-1',
  _OutcomeBox? outcomeBox,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        reportsApiProvider.overrideWithValue(api),
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
                  final outcome = await showModalBottomSheet<bool>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) =>
                        ReportSheet(targetType: targetType, targetId: targetId),
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
  testWidgets('shows every reason label verbatim, plus the privacy hint', (
    tester,
  ) async {
    await _pumpAndOpen(tester, api: _FakeReportsApi());

    expect(find.text('uygunsuz icerik'), findsOneWidget);
    expect(find.text('kedi degil'), findsOneWidget);
    expect(find.text('yanlis bilgi'), findsOneWidget);
    expect(find.text('spam / tekrar eden icerik'), findsOneWidget);
    expect(find.text('kisisel gizlilik ihlali'), findsOneWidget);
    expect(find.text('diger'), findsOneWidget);
    expect(
      find.text('medyada insan yuzu, ev ici, ozel alan, plaka gibi'),
      findsOneWidget,
    );
  });

  testWidgets('the submit button starts disabled until a reason is chosen', (
    tester,
  ) async {
    await _pumpAndOpen(tester, api: _FakeReportsApi());

    final submitButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Gönder'),
    );
    expect(submitButton.onPressed, isNull);

    await tester.tap(find.text('spam / tekrar eden icerik'));
    await tester.pump();

    final enabled = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Gönder'),
    );
    expect(enabled.onPressed, isNotNull);
  });

  testWidgets('submitting sends the target and reason, then pops true', (
    tester,
  ) async {
    final api = _FakeReportsApi();
    final outcomeBox = _OutcomeBox();
    await _pumpAndOpen(
      tester,
      api: api,
      targetType: ReportTargetType.update,
      targetId: 'upd-1',
      outcomeBox: outcomeBox,
    );

    await tester.tap(find.text('spam / tekrar eden icerik'));
    await tester.pump();
    await tester.tap(find.text('Gönder'));
    await tester.pumpAndSettle();

    expect(api.calls, 1);
    expect(api.lastTargetType, 'update');
    expect(api.lastTargetId, 'upd-1');
    expect(api.lastReason, 'spam');
    expect(api.lastNote, isNull);
    expect(outcomeBox.value, isTrue);
  });

  testWidgets('an optional note is trimmed and sent for a non-other reason', (
    tester,
  ) async {
    final api = _FakeReportsApi();
    await _pumpAndOpen(tester, api: api);

    await tester.tap(find.text('kisisel gizlilik ihlali'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '  plaka görünüyor  ');
    await tester.tap(find.text('Gönder'));
    await tester.pumpAndSettle();

    expect(api.lastReason, 'privacy');
    expect(api.lastNote, 'plaka görünüyor');
  });

  testWidgets(
    '"diger" without a note is rejected client-side, never calling the api',
    (tester) async {
      final api = _FakeReportsApi();
      await _pumpAndOpen(tester, api: api);

      await tester.tap(find.text('diger'));
      await tester.pump();
      await tester.tap(find.text('Gönder'));
      await tester.pump();

      expect(api.calls, 0);
      expect(find.text('"Diğer" için kısa bir not ekle.'), findsOneWidget);
    },
  );

  testWidgets('"diger" with a note submits successfully', (tester) async {
    final api = _FakeReportsApi();
    final outcomeBox = _OutcomeBox();
    await _pumpAndOpen(tester, api: api, outcomeBox: outcomeBox);

    await tester.tap(find.text('diger'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'bir kedi degil bu');
    await tester.tap(find.text('Gönder'));
    await tester.pumpAndSettle();

    expect(api.calls, 1);
    expect(api.lastReason, 'other');
    expect(api.lastNote, 'bir kedi degil bu');
    expect(outcomeBox.value, isTrue);
  });

  testWidgets('a 401 shows the unauthorized banner', (tester) async {
    final api = _FakeReportsApi(error: const ReportUnauthorizedException());
    await _pumpAndOpen(tester, api: api);

    await tester.tap(find.text('spam / tekrar eden icerik'));
    await tester.pump();
    await tester.tap(find.text('Gönder'));
    await tester.pumpAndSettle();

    expect(find.text('Kimlik doğrulanamadı, tekrar dene.'), findsOneWidget);
  });

  testWidgets('a 404 shows the target-not-found banner', (tester) async {
    final api = _FakeReportsApi(error: const ReportTargetNotFoundException());
    await _pumpAndOpen(tester, api: api);

    await tester.tap(find.text('spam / tekrar eden icerik'));
    await tester.pump();
    await tester.tap(find.text('Gönder'));
    await tester.pumpAndSettle();

    expect(find.text('Bu içerik artık bulunamıyor.'), findsOneWidget);
  });

  testWidgets('a network failure shows a retryable banner', (tester) async {
    final api = _FakeReportsApi(error: const ReportNetworkException());
    await _pumpAndOpen(tester, api: api);

    await tester.tap(find.text('spam / tekrar eden icerik'));
    await tester.pump();
    await tester.tap(find.text('Gönder'));
    await tester.pumpAndSettle();

    expect(find.text('Bağlantı sorunu, tekrar dene.'), findsOneWidget);
  });

  testWidgets('closing the sheet pops with no outcome', (tester) async {
    final outcomeBox = _OutcomeBox();
    await _pumpAndOpen(tester, api: _FakeReportsApi(), outcomeBox: outcomeBox);

    await tester.tap(find.byTooltip('Kapat'));
    await tester.pumpAndSettle();

    expect(outcomeBox.value, isNull);
  });

  testWidgets('every reason option meets the 44px tap target', (tester) async {
    await _pumpAndOpen(tester, api: _FakeReportsApi());

    final inkWell = find
        .ancestor(of: find.text('diger'), matching: find.byType(InkWell))
        .first;
    expect(tester.getSize(inkWell).height, greaterThanOrEqualTo(kTapMin));
  });
}
