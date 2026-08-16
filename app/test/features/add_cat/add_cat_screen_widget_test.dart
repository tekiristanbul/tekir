import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:app/core/identity/device_identity.dart';
import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/add_cat/data/add_cat_api.dart';
import 'package:app/features/add_cat/ui/add_cat_screen.dart';
import 'package:app/features/auth/data/auth_api.dart';
import 'package:app/features/auth/ui/login_screen.dart';
import 'package:app/features/cat_detail/data/cat_detail.dart';
import 'package:app/features/map/data/location_service.dart';

class _FakeAddCatApi implements AddCatApi {
  List<DuplicateCandidate> nearbyResult = const [];
  CatDetail? createResult;
  Object? createError;

  /// Caps how many leading [createCat] calls throw [createError] before it
  /// starts succeeding — `null` (the default) throws on every call, exactly
  /// the prior always-throws behavior every other test here relies on. Set
  /// to a finite count to simulate a transient failure that a bounded
  /// automatic retry (issue #256's re-auth-and-resume) then recovers from
  /// without the test manually clearing [createError] between calls.
  int? createErrorLimit;

  /// When set, createCat reports this (sent, total) pair through
  /// onSendProgress and then waits on [createGate] before resolving — so a
  /// test can observe the in-flight upload overlay.
  (int, int)? progressEvent;
  Completer<void>? createGate;

  int createCalls = 0;
  final idempotencyKeys = <String>[];

  @override
  Future<List<DuplicateCandidate>> fetchNearby({
    required double lat,
    required double lng,
  }) async => nearbyResult;

  @override
  Future<CatDetail> createCat({
    required double lat,
    required double lng,
    String? name,
    required bool confirmedNew,
    required Uint8List photoBytes,
    required String photoFilename,
    required String idempotencyKey,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    createCalls++;
    idempotencyKeys.add(idempotencyKey);
    final event = progressEvent;
    if (event != null) onSendProgress?.call(event.$1, event.$2);
    if (createGate != null) await createGate!.future;
    if (createError != null &&
        (createErrorLimit == null || createCalls <= createErrorLimit!)) {
      throw createError!;
    }
    return createResult!;
  }
}

class _FakeImagePickerPlatform extends ImagePickerPlatform {
  XFile? nextFile;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async => nextFile;
}

// A minimal valid 1x1 PNG — the details step's photo-well previews the
// picked bytes via Image.memory, which throws asynchronously on genuinely
// invalid image data (unlike the api/notifier tests, which never decode
// the bytes at all).
final _validPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAAC0lEQVQYV2NgAAIAAAUAAen63NgAAAAASUVORK5CYII=',
);

class _FakeLocationService implements LocationService {
  _FakeLocationService([
    this.result = const ResolvedLocation(
      center: LatLng(41.03, 28.98),
      isFallback: false,
    ),
  ]);

  final ResolvedLocation result;

  @override
  Future<ResolvedLocation> resolveInitialCenter() async => result;

  @override
  Future<void> recoverPermission() async {}
}

// Pre-populated in-memory storage so AuthNotifier.verifyCode's device
// identity init() resolves instantly with no real platform channel —
// mirrors follow_button_widget_test.dart's identical need for driving the
// real LoginScreen inside a widget test.
class _FakeDeviceStorage implements DeviceKeyValueStorage {
  final _data = <String, String>{'device_id': 'did-1', 'device_token': 'tok-1'};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

// Mirrors follow_button_widget_test.dart's identical fake.
class _FakeSessionIdentityService implements SessionIdentityService {
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

Future<void> _pumpAddCat(
  WidgetTester tester,
  _FakeAddCatApi api, {
  SessionIdentityService? session,
  AuthApi? authApi,
  DeviceIdentityService? deviceIdentityService,
  LocationService? locationService,
}) async {
  final router = GoRouter(
    initialLocation: '/add-cat',
    routes: [
      GoRoute(
        path: '/add-cat',
        builder: (context, state) => const AddCatScreen(),
      ),
      GoRoute(
        path: '/cats/:id',
        builder: (context, state) =>
            Scaffold(body: Text('cat detail ${state.pathParameters['id']}')),
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
        addCatApiProvider.overrideWithValue(api),
        locationServiceProvider.overrideWith(
          (ref) => locationService ?? _FakeLocationService(),
        ),
        if (session != null)
          sessionIdentityServiceProvider.overrideWithValue(session),
        if (authApi != null) authApiProvider.overrideWithValue(authApi),
        if (deviceIdentityService != null)
          deviceIdentityServiceProvider.overrideWithValue(
            deviceIdentityService,
          ),
      ],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ),
  );
  // AddCatScreen mounts a real GoogleMap platform view — pumpAndSettle
  // would hang on its continuous internal animation (same reasoning as
  // add_cat_gate_widget_test.dart / map_marker_navigation_test.dart).
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

// Taps the photo well, then "Galeriden seç" in the resulting camera/gallery
// chooser sheet (the fake ImagePickerPlatform answers with fakePlatform's
// nextFile regardless of which source is actually chosen).
Future<void> _pickPhoto(WidgetTester tester) async {
  await tester.tap(find.text('Fotoğraf ekle'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(find.text('Galeriden seç'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  final fakePlatform = _FakeImagePickerPlatform();
  ImagePickerPlatform.instance = fakePlatform;

  testWidgets(
    'confirming a location with no nearby cats advances straight to the details step',
    (tester) async {
      await _pumpAddCat(tester, _FakeAddCatApi());

      expect(find.text('Konumu seç'), findsOneWidget);
      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Kedi ekle'), findsOneWidget);
      expect(find.text('Fotoğraf (zorunlu)'), findsOneWidget);
    },
  );

  testWidgets(
    // issue #259: when device location can't be resolved (permission
    // denied, service disabled, timeout, or a reading outside istanbul),
    // LocationService.resolveInitialCenter falls back to istanbulFallback
    // rather than leaving lat/lng null — "Bu konumu kullan" must still be
    // enabled and confirmable, not stuck disabled or dead-ended, matching
    // the app-review screenshot's expected location-confirmation step.
    'the istanbul fallback center is confirmable when device location is '
    'unavailable',
    (tester) async {
      await _pumpAddCat(
        tester,
        _FakeAddCatApi(),
        locationService: _FakeLocationService(
          const ResolvedLocation(
            center: istanbulFallback,
            isFallback: true,
            permissionDenied: true,
          ),
        ),
      );

      expect(
        find.text('Konum bulunamadı. Haritadan elle seç.'),
        findsOneWidget,
      );
      final confirmButton = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Bu konumu kullan'),
      );
      expect(confirmButton.onPressed, isNotNull);

      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Kedi ekle'), findsOneWidget);
      expect(find.text('Fotoğraf (zorunlu)'), findsOneWidget);
    },
  );

  testWidgets(
    'a typed name survives leaving and returning to the details step',
    (tester) async {
      // Regression: the name field must read from AddCatState.name on
      // (re)build, not rely on TextField's own internal editing state —
      // _DetailsStep is torn down and rebuilt from scratch when the step
      // switch in AddCatScreen.build moves away from and back to details
      // (e.g. tapping the app bar's back action, then confirming the
      // location again).
      await _pumpAddCat(tester, _FakeAddCatApi());
      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.enterText(find.byType(TextFormField), 'Boncuk');
      await tester.pump();

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Konumu seç'), findsOneWidget);

      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Boncuk'), findsOneWidget);
    },
  );

  testWidgets(
    'confirming a location with nearby cats shows the non-blocking duplicate modal',
    (tester) async {
      final api = _FakeAddCatApi()
        ..nearbyResult = const [
          DuplicateCandidate(id: 'cat-1', name: 'tekir', primaryPhoto: ''),
        ];
      await _pumpAddCat(tester, api);

      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.text(
          'Bu bölgede zaten kayıtlı bir kedi var. Gördüğün kedi bu mu?',
        ),
        findsOneWidget,
      );
      expect(find.text('tekir'), findsOneWidget);
      // still on the location step underneath — the modal is an overlay,
      // never a dead end (docs/product/cats.md/trust.md: advisory only).
      expect(find.text('Fotoğraf (zorunlu)'), findsNothing);
    },
  );

  testWidgets(
    'tapping a duplicate candidate opens that cat, not a broken navigator pop',
    (tester) async {
      // Regression: the modal is a state-driven overlay atop /add-cat, not
      // a pushed route — tapping a candidate must go(/cats/:id) directly,
      // never Navigator.pop() first (which would instead close /add-cat).
      final api = _FakeAddCatApi()
        ..nearbyResult = const [
          DuplicateCandidate(id: 'cat-1', name: 'tekir', primaryPhoto: ''),
        ];
      await _pumpAddCat(tester, api);
      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('tekir'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('cat detail cat-1'), findsOneWidget);
      expect(find.byType(AddCatScreen), findsNothing);
    },
  );

  testWidgets(
    '"yine de ekle" continues past the duplicate modal to the details step',
    (tester) async {
      final api = _FakeAddCatApi()
        ..nearbyResult = const [
          DuplicateCandidate(id: 'cat-1', name: 'tekir', primaryPhoto: ''),
        ];
      await _pumpAddCat(tester, api);
      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Hayır, farklı bir kedi — yine de ekle'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Fotoğraf (zorunlu)'), findsOneWidget);
    },
  );

  testWidgets(
    'saving without a photo shows a validation message and never submits',
    (tester) async {
      final api = _FakeAddCatApi();
      await _pumpAddCat(tester, api);
      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Kaydet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Kaydetmeden önce bir fotoğraf ekle'), findsOneWidget);
    },
  );

  testWidgets(
    'picking a photo and saving successfully navigates to the created cat',
    (tester) async {
      final api = _FakeAddCatApi()
        ..createResult = CatDetail(
          id: 'new-cat-id',
          name: '',
          lat: 41.03,
          lng: 28.98,
          areaLabel: null,
          primaryPhoto: '/v1/media/objects/x.jpg',
          createdAt: DateTime.utc(2026, 1, 1),
          lastUpdateAt: null,
        );
      await _pumpAddCat(tester, api);
      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      fakePlatform.nextFile = XFile.fromData(
        _validPngBytes,
        name: 'photo.jpg',
        path: 'photo.jpg',
      );
      await _pickPhoto(tester);

      await tester.tap(find.text('Kaydet'));
      await tester.pump();
      // the page-transition animation to /cats/:id needs longer than the
      // other pumps in this file to fully remove the old route.
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('cat detail new-cat-id'), findsOneWidget);
      expect(find.byType(AddCatScreen), findsNothing);
    },
  );

  testWidgets('a network failure shows the state-11 sheet, keeps the form, and '
      'retries from the sheet', (tester) async {
    final api = _FakeAddCatApi()..createError = const AddCatNetworkException();
    await _pumpAddCat(tester, api);
    await tester.tap(find.text('Bu konumu kullan'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    fakePlatform.nextFile = XFile.fromData(
      _validPngBytes,
      name: 'photo.jpg',
      path: 'photo.jpg',
    );
    await _pickPhoto(tester);
    await tester.enterText(find.byType(TextFormField), 'Boncuk');
    await tester.pump();

    await tester.tap(find.text('Kaydet'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The sheet uses the typed name; the error never references the
    // transport layer via the old inline banner.
    expect(find.text('Boncuk haritaya eklenemedi'), findsOneWidget);
    expect(
      find.text(
        'fotoğraf yüklenirken bağlantı koptu. '
        'yazdıkların telefonunda duruyor.',
      ),
      findsOneWidget,
    );
    expect(find.text('yüklenemedi'), findsOneWidget);
    expect(find.text('Bağlantı sorunu, tekrar dene.'), findsNothing);

    api.createError = null;
    api.createResult = CatDetail(
      id: 'new-cat-id',
      name: '',
      lat: 41.03,
      lng: 28.98,
      areaLabel: null,
      primaryPhoto: null,
      createdAt: DateTime.utc(2026, 1, 1),
      lastUpdateAt: null,
    );
    await tester.tap(find.text('tekrar dene'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.text('cat detail new-cat-id'), findsOneWidget);
    expect(find.byType(AddCatScreen), findsNothing);
  });

  testWidgets('a nameless failed submission falls back to a generic title', (
    tester,
  ) async {
    final api = _FakeAddCatApi()..createError = const AddCatNetworkException();
    await _pumpAddCat(tester, api);
    await tester.tap(find.text('Bu konumu kullan'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    fakePlatform.nextFile = XFile.fromData(
      _validPngBytes,
      name: 'photo.jpg',
      path: 'photo.jpg',
    );
    await _pickPhoto(tester);

    await tester.tap(find.text('Kaydet'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('kedi haritaya eklenemedi'), findsOneWidget);
  });

  testWidgets(
    'dismissing the sheet leaves the retained form with badge and retry',
    (tester) async {
      final api = _FakeAddCatApi()
        ..createError = const AddCatNetworkException();
      await _pumpAddCat(tester, api);
      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      fakePlatform.nextFile = XFile.fromData(
        _validPngBytes,
        name: 'photo.jpg',
        path: 'photo.jpg',
      );
      await _pickPhoto(tester);
      await tester.enterText(find.byType(TextFormField), 'Boncuk');
      await tester.pump();

      await tester.tap(find.text('Kaydet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Dismiss the sheet by tapping its modal barrier (the barrier's
      // center sits above the bottom-anchored sheet), instead of a
      // hard-coded screen coordinate.
      await tester.tap(find.byType(ModalBarrier).last, warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Boncuk haritaya eklenemedi'), findsNothing);
      // Data is never lost: name, photo (with its badge), and an in-place
      // retry all remain.
      expect(find.text('Boncuk'), findsOneWidget);
      expect(find.text('yüklenemedi'), findsOneWidget);
      expect(find.text('Tekrar dene'), findsOneWidget);
    },
  );

  testWidgets('a server failure keeps the inline banner instead of the sheet', (
    tester,
  ) async {
    final api = _FakeAddCatApi()..createError = const AddCatServerException();
    await _pumpAddCat(tester, api);
    await tester.tap(find.text('Bu konumu kullan'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    fakePlatform.nextFile = XFile.fromData(
      _validPngBytes,
      name: 'photo.jpg',
      path: 'photo.jpg',
    );
    await _pickPhoto(tester);

    await tester.tap(find.text('Kaydet'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text('Sunucuya ulaşılamadı, birazdan tekrar dene.'),
      findsOneWidget,
    );
    expect(find.textContaining('haritaya eklenemedi'), findsNothing);
  });

  testWidgets(
    'an in-flight upload shows the photo percentage and the submitting '
    'button label',
    (tester) async {
      final api = _FakeAddCatApi()
        ..progressEvent = (62, 100)
        ..createGate = Completer<void>()
        ..createResult = CatDetail(
          id: 'new-cat-id',
          name: '',
          lat: 41.03,
          lng: 28.98,
          areaLabel: null,
          primaryPhoto: null,
          createdAt: DateTime.utc(2026, 1, 1),
          lastUpdateAt: null,
        );
      await _pumpAddCat(tester, api);
      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      fakePlatform.nextFile = XFile.fromData(
        _validPngBytes,
        name: 'photo.jpg',
        path: 'photo.jpg',
      );
      await _pickPhoto(tester);

      await tester.tap(find.text('Kaydet'));
      await tester.pump();

      // Same-frame mutation feedback plus the app's only percentage.
      expect(find.text('haritaya ekleniyor'), findsOneWidget);
      expect(find.text('%62'), findsOneWidget);

      api.createGate!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('cat detail new-cat-id'), findsOneWidget);
    },
  );

  testWidgets(
    'once the photo has fully left the device the overlay switches to '
    '"kontrol ediliyor" instead of a stale 100%',
    (tester) async {
      // issue #241: the same request is now waiting on the server's
      // pre-publication content check — no new request, no polling, just a
      // truer label for the tail of this one upload.
      final api = _FakeAddCatApi()
        ..progressEvent = (100, 100)
        ..createGate = Completer<void>()
        ..createResult = CatDetail(
          id: 'new-cat-id',
          name: '',
          lat: 41.03,
          lng: 28.98,
          areaLabel: null,
          primaryPhoto: null,
          createdAt: DateTime.utc(2026, 1, 1),
          lastUpdateAt: null,
        );
      await _pumpAddCat(tester, api);
      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      fakePlatform.nextFile = XFile.fromData(
        _validPngBytes,
        name: 'photo.jpg',
        path: 'photo.jpg',
      );
      await _pickPhoto(tester);

      await tester.tap(find.text('Kaydet'));
      await tester.pump();

      expect(find.text('kontrol ediliyor'), findsOneWidget);
      expect(find.text('%100'), findsNothing);

      api.createGate!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('cat detail new-cat-id'), findsOneWidget);
    },
  );

  testWidgets(
    'a content-rejected (422) failure shows the rejection banner and keeps '
    'the picked photo and typed name',
    (tester) async {
      final api = _FakeAddCatApi()
        ..createError = const AddCatContentRejectedException();
      await _pumpAddCat(tester, api);
      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      fakePlatform.nextFile = XFile.fromData(
        _validPngBytes,
        name: 'photo.jpg',
        path: 'photo.jpg',
      );
      await _pickPhoto(tester);
      await tester.enterText(find.byType(TextFormField), 'Boncuk');
      await tester.pump();

      await tester.tap(find.text('Kaydet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text(
          'Bu içerik yayınlanamadı. Fotoğrafı veya bilgileri değiştirip '
          'tekrar dene.',
        ),
        findsOneWidget,
      );
      // Never the network-failure sheet, and never a hint at *why* the
      // content was rejected (no category/provider wording) — issue #241,
      // docs/product/trust.md.
      expect(find.textContaining('haritaya eklenemedi'), findsNothing);
      // Data is never lost: the photo and typed name stay, ready to retry.
      expect(find.text('Boncuk'), findsOneWidget);
      expect(find.text('Tekrar dene'), findsOneWidget);
    },
  );

  testWidgets(
    // issue #256: a session that died mid-flow must not strand the
    // reviewer (or any user) behind a generic "kimlik doğrulanamadı" dead
    // end — the app pushes straight to the real login screen and, once
    // signed in again, resumes the exact same submission automatically.
    'a stale session (401) pushes to /login and resumes the save on '
    'successful re-authentication, without creating a duplicate cat',
    (tester) async {
      final api = _FakeAddCatApi()
        ..createError = const AddCatUnauthorizedException()
        ..createErrorLimit = 1
        ..createResult = CatDetail(
          id: 'new-cat-id',
          name: '',
          lat: 41.03,
          lng: 28.98,
          areaLabel: null,
          primaryPhoto: null,
          createdAt: DateTime.utc(2026, 1, 1),
          lastUpdateAt: null,
        );
      final authApi = _FakeAuthApi()
        ..nextSession = const AuthSession(
          accessToken: 'at',
          refreshToken: 'rt',
          userId: 'user-1',
          isNewAccount: false,
        );
      await _pumpAddCat(
        tester,
        api,
        session: _FakeSessionIdentityService(),
        authApi: authApi,
        deviceIdentityService: DeviceIdentityService(
          storage: _FakeDeviceStorage(),
          dio: Dio(BaseOptions(baseUrl: 'http://localhost:8080')),
        ),
      );
      await tester.tap(find.text('Bu konumu kullan'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      fakePlatform.nextFile = XFile.fromData(
        _validPngBytes,
        name: 'photo.jpg',
        path: 'photo.jpg',
      );
      await _pickPhoto(tester);

      await tester.tap(find.text('Kaydet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Pushed on top of the still-mounted AddCatScreen (its GoogleMap
      // keeps animating underneath, so pumpAndSettle would hang here too —
      // manual pumps only, as elsewhere in this file). The details step's
      // own name TextFormField is still mounted underneath too, so every
      // finder below is scoped to LoginScreen — an unscoped
      // find.byType(TextField).first would otherwise just as easily match
      // that hidden field first.
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(AddCatScreen), findsOneWidget);
      final loginField = find.descendant(
        of: find.byType(LoginScreen),
        matching: find.byType(TextField),
      );

      await tester.enterText(loginField, '5321112233');
      await tester.tap(
        find.descendant(
          of: find.byType(LoginScreen),
          matching: find.text('Kod gönder'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(loginField, '123456');
      await tester.tap(
        find.descendant(
          of: find.byType(LoginScreen),
          matching: find.widgetWithText(ElevatedButton, 'Giriş yap'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(LoginScreen), findsNothing);
      expect(find.text('cat detail new-cat-id'), findsOneWidget);
      expect(
        api.createCalls,
        2,
        reason: 'the doomed attempt plus the resumed submission',
      );
      expect(
        api.idempotencyKeys[0],
        api.idempotencyKeys[1],
        reason:
            'the resumed submission must reuse the same attempt, never '
            'risk a duplicate cat',
      );
    },
  );
}
