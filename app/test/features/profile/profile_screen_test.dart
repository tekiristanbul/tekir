import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/badges/data/badge.dart';
import 'package:app/features/profile/data/profile.dart';
import 'package:app/features/profile/data/profile_api.dart';
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
  Future<void> save(SessionIdentity identity) async => _cached = identity;

  @override
  Future<void> logout() async => _cached = null;
}

class _FakeProfileApi implements ProfileApi {
  _FakeProfileApi({this.nextProfile, this.nextError});

  Profile? nextProfile;
  Object? nextError;
  int calls = 0;
  Completer<void>? pending;

  @override
  Future<Profile> fetch() async {
    calls++;
    if (pending != null) await pending!.future;
    if (nextError != null) throw nextError!;
    return nextProfile!;
  }
}

BadgeStatus _unearnedBadge(String id) => BadgeStatus(
  id: id,
  name: 'Badge $id',
  icon: 'eye',
  condition: 'condition',
  descr: 'descr',
  value: 0,
  target: 1,
  earned: false,
  earnedAt: null,
);

Future<void> _pump(
  WidgetTester tester, {
  required SessionIdentity? session,
  _FakeProfileApi? profileApi,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => const ProfileScreen()),
      GoRoute(
        path: '/badges',
        builder: (context, state) =>
            const Scaffold(body: Text('badges screen')),
      ),
      GoRoute(
        path: '/account',
        builder: (context, state) =>
            const Scaffold(body: Text('account screen')),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) => const Scaffold(body: Text('login screen')),
      ),
      GoRoute(
        path: '/cats/:id',
        builder: (context, state) =>
            Scaffold(body: Text('cat detail ${state.pathParameters['id']}')),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionIdentityServiceProvider.overrideWithValue(
          _FakeSessionIdentityService(cached: session),
        ),
        if (profileApi != null)
          profileApiProvider.overrideWithValue(profileApi),
      ],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the guest empty-state with a login cta', (tester) async {
    await _pump(tester, session: null);

    expect(find.text('Giriş yapmadın'), findsOneWidget);
    expect(find.text('Giriş yap'), findsOneWidget);
  });

  testWidgets('shows a loading indicator before the profile arrives', (
    tester,
  ) async {
    final api = _FakeProfileApi()..pending = Completer<void>();
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (context, state) => const ProfileScreen()),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionIdentityServiceProvider.overrideWithValue(
            _FakeSessionIdentityService(cached: _session),
          ),
          profileApiProvider.overrideWithValue(api),
        ],
        child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
      ),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    api.pending!.complete();
  });

  testWidgets('shows display name, totals, and no-badges-yet copy', (
    tester,
  ) async {
    final api = _FakeProfileApi(
      nextProfile: Profile(
        displayName: 'Ada',
        totals: const ContributionTotals(
          updates: 3,
          helps: 1,
          catsAdded: 0,
          distinctCats: 2,
        ),
        badges: [_unearnedBadge('first_sighting')],
        recentContributions: const [],
      ),
    );
    await _pump(tester, session: _session, profileApi: api);

    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(
      find.text(
        'Henüz rozet kazanmadın. İlk katkını paylaş, buradan takip et.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Henüz katkın yok. Bir kediyi gördüğünde "Gördüm" ile başla.'),
      findsOneWidget,
    );
  });

  testWidgets('shows a badge strip when at least one badge is earned', (
    tester,
  ) async {
    final api = _FakeProfileApi(
      nextProfile: Profile(
        displayName: 'Ada',
        totals: const ContributionTotals(
          updates: 1,
          helps: 0,
          catsAdded: 0,
          distinctCats: 1,
        ),
        badges: [
          BadgeStatus(
            id: 'first_sighting',
            name: 'İlk Görüş',
            icon: 'eye',
            condition: 'condition',
            descr: 'descr',
            value: 1,
            target: 1,
            earned: true,
            earnedAt: DateTime.utc(2026, 1, 1),
          ),
        ],
        recentContributions: const [],
      ),
    );
    await _pump(tester, session: _session, profileApi: api);

    expect(find.text('İlk Görüş'), findsOneWidget);
    expect(
      find.text(
        'Henüz rozet kazanmadın. İlk katkını paylaş, buradan takip et.',
      ),
      findsNothing,
    );
  });

  testWidgets('lists recent contributions and navigates to the cat on tap', (
    tester,
  ) async {
    final api = _FakeProfileApi(
      nextProfile: Profile(
        displayName: 'Ada',
        totals: const ContributionTotals(
          updates: 1,
          helps: 0,
          catsAdded: 0,
          distinctCats: 1,
        ),
        badges: [_unearnedBadge('first_sighting')],
        recentContributions: [
          RecentContribution(
            type: 'update',
            catId: 'cat-1',
            catName: 'Tekir',
            catPrimaryPhoto: null,
            statuses: const ['seen'],
            needsHelpCategory: null,
            needsHelpCategoryLabel: null,
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        ],
      ),
    );
    await _pump(tester, session: _session, profileApi: api);

    expect(find.textContaining('Tekir'), findsOneWidget);

    await tester.tap(find.textContaining('Tekir'));
    await tester.pumpAndSettle();

    expect(find.text('cat detail cat-1'), findsOneWidget);
  });

  testWidgets('a fetch failure shows a retry state, and retry re-fetches', (
    tester,
  ) async {
    final api = _FakeProfileApi(nextError: Exception('network down'));
    await _pump(tester, session: _session, profileApi: api);

    expect(
      find.text('Bağlantı sorunu oldu. Tekrar dener misin?'),
      findsOneWidget,
    );

    api.nextError = null;
    api.nextProfile = Profile(
      displayName: 'Ada',
      totals: const ContributionTotals(
        updates: 0,
        helps: 0,
        catsAdded: 0,
        distinctCats: 0,
      ),
      badges: [_unearnedBadge('first_sighting')],
      recentContributions: const [],
    );
    await tester.tap(find.text('Tekrar dene'));
    await tester.pumpAndSettle();

    expect(find.text('Ada'), findsOneWidget);
    expect(api.calls, 2);
  });

  testWidgets('the settings button navigates to /account', (tester) async {
    final api = _FakeProfileApi(
      nextProfile: Profile(
        displayName: 'Ada',
        totals: const ContributionTotals(
          updates: 0,
          helps: 0,
          catsAdded: 0,
          distinctCats: 0,
        ),
        badges: [_unearnedBadge('first_sighting')],
        recentContributions: const [],
      ),
    );
    await _pump(tester, session: _session, profileApi: api);

    await tester.tap(find.text('Ayarlar'));
    await tester.pumpAndSettle();

    expect(find.text('account screen'), findsOneWidget);
  });
}
