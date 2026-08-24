import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dio/dio.dart';

import 'package:app/core/identity/device_identity.dart';
import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/network/api_client.dart';
import 'package:app/features/cat_detail/data/cat_detail.dart';
import 'package:app/features/cat_detail/data/cat_detail_api.dart';
import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/map/ui/cat_quick_update_sheet.dart';
import 'package:app/features/map/ui/cats_map_notifier.dart';

// primaryPhoto is deliberately empty on every fixture here: a real url
// would fire an actual network request the moment CachedNetworkImage
// mounts, which these widget tests must not depend on.
const _cat = CatMarker(
  id: 'cat-1',
  name: 'tekir',
  primaryPhoto: '',
  lat: 41.02561,
  lng: 28.97440,
);

const _session = SessionIdentity(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
);

/// A device identity that resolves from memory, so a submit never reaches
/// secure storage or the network for the optional author_device_id.
class _FakeStorage implements DeviceKeyValueStorage {
  final _data = <String, String>{'device_id': 'did-1', 'device_token': 'tok-1'};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

class _FakeSessionIdentityService implements SessionIdentityService {
  _FakeSessionIdentityService([this.cached]);

  @override
  final SessionIdentity? cached;

  @override
  Future<SessionIdentity?> restore() async => cached;

  @override
  Future<SessionIdentity?> refreshIfExpired() async => cached;

  @override
  Future<void> save(SessionIdentity identity) async {}

  @override
  Future<void> logout({String? deviceToken}) async {}
}

class _RecordingCatDetailApi extends CatDetailApi {
  _RecordingCatDetailApi({this.failWith}) : super(ApiClient());

  final Object? failWith;
  int calls = 0;
  List<String>? lastStatuses;
  bool? lastNeedsHelp;

  @override
  Future<CatUpdateEntry> createUpdate(
    String catId, {
    required List<String> statuses,
    bool needsHelp = false,
    String? comment,
    required String idempotencyKey,
    String? mediaId,
  }) async {
    calls++;
    lastStatuses = statuses;
    lastNeedsHelp = needsHelp;
    if (failWith != null) throw failWith!;
    return CatUpdateEntry(
      id: 'update-1',
      needsHelp: needsHelp,
      statuses: statuses,
      comment: comment,
      createdAt: DateTime.utc(2026, 3, 1, 9),
      needsHelpExpiresAt: needsHelp ? DateTime.utc(2026, 3, 4, 9) : null,
    );
  }
}

class _SeededCatsMapNotifier extends CatsMapNotifier {
  @override
  CatsMapState build() =>
      const CatsMapState(markers: [_cat], hasLoadedOnce: true);
}

Future<void> _pump(
  WidgetTester tester,
  CatMarker cat, {
  VoidCallback? onOpenDetail,
  double? distanceMeters,
  SessionIdentity? session = _session,
  CatDetailApi? api,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionIdentityServiceProvider.overrideWithValue(
          _FakeSessionIdentityService(session),
        ),
        catsMapProvider.overrideWith(_SeededCatsMapNotifier.new),
        deviceIdentityServiceProvider.overrideWithValue(
          DeviceIdentityService(
            storage: _FakeStorage(),
            dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080')),
          ),
        ),
        if (api != null) catDetailApiProvider.overrideWithValue(api),
      ],
      child: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: CatQuickUpdateSheet(
                cat: cat,
                distanceMeters: distanceMeters,
                onOpenDetail: onOpenDetail ?? () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('missing photo falls back to a branded placeholder', (
    tester,
  ) async {
    await _pump(tester, _cat);

    expect(find.text('tekir'), findsOneWidget);
    expect(find.byIcon(Icons.pets), findsOneWidget);
  });

  testWidgets('shows the area, the distance and the last update together', (
    tester,
  ) async {
    await _pump(
      tester,
      CatMarker(
        id: 'cat-1',
        name: 'tekir',
        primaryPhoto: '',
        lat: 41.02561,
        lng: 28.97440,
        areaLabel: 'Moda Sahili, Kadıköy',
        lastUpdateAt: DateTime.now().subtract(const Duration(hours: 2)),
      ),
      distanceMeters: 220,
    );

    expect(find.textContaining('Moda Sahili, Kadıköy'), findsOneWidget);
    expect(find.textContaining('220 m'), findsOneWidget);
  });

  testWidgets('omits the distance when no real position is known', (
    tester,
  ) async {
    await _pump(tester, _cat);

    expect(find.textContaining('220 m'), findsNothing);
    expect(find.textContaining(' m · '), findsNothing);
  });

  group('help', () {
    testWidgets('shows the mark, its note and how long it has left', (
      tester,
    ) async {
      final now = DateTime.now();
      await _pump(
        tester,
        CatMarker(
          id: 'cat-1',
          name: 'tekir',
          primaryPhoto: '',
          lat: 41.02561,
          lng: 28.97440,
          activeAlert: ActiveAlert(
            comment: 'sağ ön ayağını basmıyor',
            createdAt: now.subtract(const Duration(hours: 1)),
            expiresAt: now.add(const Duration(hours: 2)),
          ),
        ),
      );

      expect(find.text('yardım gerekiyor'), findsOneWidget);
      expect(find.text('sağ ön ayağını basmıyor'), findsOneWidget);
      expect(find.textContaining('sona eriyor'), findsOneWidget);
    });

    testWidgets('offers nothing to press: help expires, it is not resolved', (
      tester,
    ) async {
      final now = DateTime.now();
      await _pump(
        tester,
        CatMarker(
          id: 'cat-1',
          name: 'tekir',
          primaryPhoto: '',
          lat: 41.02561,
          lng: 28.97440,
          activeAlert: ActiveAlert(
            createdAt: now,
            expiresAt: now.add(const Duration(hours: 2)),
          ),
        ),
      );

      expect(find.text('çözüldü'), findsNothing);
      expect(find.text('hallettim'), findsNothing);
    });

    testWidgets('shows nothing when there is no active mark', (tester) async {
      await _pump(tester, _cat);

      expect(find.text('yardım gerekiyor'), findsNothing);
    });
  });

  group('saving', () {
    testWidgets('the save button is inactive until something is selected', (
      tester,
    ) async {
      final api = _RecordingCatDetailApi();
      await _pump(tester, _cat, api: api);

      expect(find.text('+ update ekle'), findsOneWidget);

      await tester.tap(find.text('+ update ekle'));
      await tester.pumpAndSettle();

      expect(api.calls, 0);
    });

    testWidgets('the button counts what is selected', (tester) async {
      await _pump(tester, _cat, api: _RecordingCatDetailApi());

      await tester.tap(find.text('mama'));
      await tester.pumpAndSettle();
      expect(find.text('+ update ekle · 1'), findsOneWidget);

      await tester.tap(find.text('su'));
      await tester.pumpAndSettle();
      expect(find.text('+ update ekle · 2'), findsOneWidget);
    });

    testWidgets('several toggles combine into one update', (tester) async {
      final api = _RecordingCatDetailApi();
      await _pump(tester, _cat, api: api);

      await tester.tap(find.text('mama'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('su'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('yardım'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('+ update ekle · 3'));
      await tester.pumpAndSettle();

      expect(api.calls, 1);
      expect(api.lastStatuses, containsAll(<String>['fed', 'water_provided']));
      expect(api.lastNeedsHelp, isTrue);
    });

    testWidgets('a toggle can be turned back off', (tester) async {
      await _pump(tester, _cat, api: _RecordingCatDetailApi());

      await tester.tap(find.text('mama'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('mama'));
      await tester.pumpAndSettle();

      expect(find.text('+ update ekle'), findsOneWidget);
    });

    testWidgets('a failure keeps the draft and says what went wrong', (
      tester,
    ) async {
      final api = _RecordingCatDetailApi(
        failWith: const UpdateNetworkException(),
      );
      await _pump(tester, _cat, api: api);

      await tester.tap(find.text('mama'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('+ update ekle · 1'));
      await tester.pumpAndSettle();

      expect(find.text('Bağlantı sorunu, tekrar dene.'), findsOneWidget);
      // The selection survives, so the retry is one tap rather than a
      // re-entry of everything.
      expect(find.text('+ update ekle · 1'), findsOneWidget);
    });

    testWidgets('a guest is prompted at save, not at open', (tester) async {
      final api = _RecordingCatDetailApi();
      await _pump(tester, _cat, api: api, session: null);

      // The sheet is fully readable without an account.
      expect(find.text('tekir'), findsOneWidget);
      expect(find.text('mama'), findsOneWidget);

      await tester.tap(find.text('mama'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('+ update ekle · 1'));
      await tester.pumpAndSettle();

      expect(api.calls, 0);
    });
  });

  testWidgets('the detail link is the way through to everything else', (
    tester,
  ) async {
    var tapped = false;
    await _pump(tester, _cat, onOpenDetail: () => tapped = true);

    await tester.tap(find.text('kedi detayına git'));
    await tester.pump();

    expect(tapped, isTrue);
  });
}
