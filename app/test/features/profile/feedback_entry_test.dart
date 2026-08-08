import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/badges/data/badge.dart';
import 'package:app/features/profile/data/profile.dart';
import 'package:app/features/profile/data/profile_api.dart';
import 'package:app/features/profile/ui/feedback_entry.dart';
import 'package:app/features/profile/ui/profile_screen.dart';

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

class _FakeProfileApi implements ProfileApi {
  @override
  Future<Profile> fetch() async => Profile(
    displayName: 'Ada',
    totals: const ContributionTotals(
      updates: 0,
      helps: 0,
      catsAdded: 0,
      distinctCats: 0,
    ),
    badges: [
      BadgeStatus(
        id: 'first_sighting',
        name: 'Badge',
        icon: 'eye',
        condition: 'condition',
        descr: 'descr',
        value: 0,
        target: 1,
        earned: false,
        earnedAt: null,
      ),
    ],
    recentContributions: const [],
  );
}

class _FakeLauncher {
  _FakeLauncher({this.result = true, this.error});

  final bool result;
  final Object? error;
  final launched = <Uri>[];

  Future<bool> call(Uri uri) async {
    launched.add(uri);
    if (error != null) throw error!;
    return result;
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required SessionIdentity? session,
  required _FakeLauncher launcher,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => const ProfileScreen()),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionIdentityServiceProvider.overrideWithValue(
          _FakeSessionIdentityService(cached: session),
        ),
        profileApiProvider.overrideWithValue(_FakeProfileApi()),
        feedbackMailLauncherProvider.overrideWithValue(launcher.call),
        appVersionProvider.overrideWith((ref) async => '0.2'),
      ],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('mailto construction', () {
    test('addresses the 0.1 contact with the approved subject and body', () {
      final uri = buildFeedbackMailtoUri(
        appVersion: '0.2',
        platform: TargetPlatform.android,
        isWeb: false,
      );

      expect(uri.scheme, 'mailto');
      expect(uri.path, 'hello@tekir.istanbul');
      expect(uri.queryParameters['subject'], 'Tekir 0.2 geri bildirimi');
      expect(
        uri.queryParameters['body'],
        'Uygulama sürümü: 0.2\n'
        'Platform: Android\n'
        '\n'
        'Geri bildirimin:\n',
      );
      // Percent-encoded spaces — Uri(queryParameters:) would form-encode
      // them as '+', which mail clients render literally.
      expect(uri.query, isNot(contains('+')));
      // Privacy rule (issue #91): nothing beyond subject and body template.
      expect(uri.queryParameters.keys, unorderedEquals(['subject', 'body']));
    });

    test('platform label covers the 0.1 release matrix only', () {
      expect(feedbackPlatformLabel(isWeb: true), 'Web');
      expect(
        feedbackPlatformLabel(platform: TargetPlatform.iOS, isWeb: false),
        'iOS',
      );
      expect(
        feedbackPlatformLabel(platform: TargetPlatform.android, isWeb: false),
        'Android',
      );
      expect(
        feedbackPlatformLabel(platform: TargetPlatform.macOS, isWeb: false),
        '',
      );
    });
  });

  testWidgets('guests see the entry and tapping launches the draft', (
    tester,
  ) async {
    final launcher = _FakeLauncher();
    await _pump(tester, session: null, launcher: launcher);

    expect(find.text('Giriş yapmadın'), findsOneWidget);
    expect(find.text('Geri bildirim gönder'), findsOneWidget);
    expect(find.text('Hata bildir veya önerini paylaş'), findsOneWidget);

    await tester.tap(find.text('Geri bildirim gönder'));
    await tester.pumpAndSettle();

    expect(launcher.launched, hasLength(1));
    expect(launcher.launched.single.scheme, 'mailto');
    expect(launcher.launched.single.path, 'hello@tekir.istanbul');
  });

  testWidgets('signed-in users see the entry at the bottom of the list', (
    tester,
  ) async {
    final launcher = _FakeLauncher();
    await _pump(tester, session: _session, launcher: launcher);

    expect(find.text('Ada'), findsOneWidget);
    await tester.scrollUntilVisible(find.byType(FeedbackEntry), 100);

    expect(find.text('Geri bildirim gönder'), findsOneWidget);

    await tester.tap(find.text('Geri bildirim gönder'));
    await tester.pumpAndSettle();

    expect(launcher.launched, hasLength(1));
  });

  testWidgets('a device without a mail app gets a recoverable snackbar', (
    tester,
  ) async {
    final launcher = _FakeLauncher(result: false);
    await _pump(tester, session: null, launcher: launcher);

    await tester.tap(find.text('Geri bildirim gönder'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'E-posta uygulaması açılamadı. Bize hello@tekir.istanbul '
        'adresinden ulaşabilirsin.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a throwing launcher is handled like a missing mail app', (
    tester,
  ) async {
    final launcher = _FakeLauncher(error: Exception('no handler'));
    await _pump(tester, session: null, launcher: launcher);

    await tester.tap(find.text('Geri bildirim gönder'));
    await tester.pumpAndSettle();

    expect(find.textContaining('E-posta uygulaması açılamadı'), findsOneWidget);
  });
}
