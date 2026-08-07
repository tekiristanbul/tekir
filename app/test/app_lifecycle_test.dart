import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/identity/session_identity.dart';
import 'package:app/features/map/data/location_service.dart';
import 'package:app/features/map/ui/cats_map_notifier.dart';
import 'package:app/main.dart';

// Mirrors session_scoped_reset_test.dart's fake.
class _FakeSessionIdentityService implements SessionIdentityService {
  _FakeSessionIdentityService({SessionIdentity? initial}) : _cached = initial;

  SessionIdentity? _cached;
  int refreshCallCount = 0;

  @override
  SessionIdentity? get cached => _cached;

  @override
  Future<SessionIdentity?> restore() async => _cached;

  @override
  Future<SessionIdentity?> refreshIfExpired() async {
    refreshCallCount++;
    return _cached;
  }

  @override
  Future<void> save(SessionIdentity identity) async => _cached = identity;

  @override
  Future<void> logout({String? deviceToken}) async => _cached = null;
}

class _FixedCatsMapNotifier extends CatsMapNotifier {
  _FixedCatsMapNotifier(this._state);

  final CatsMapState _state;

  @override
  CatsMapState build() => _state;
}

const _session = SessionIdentity(
  accessToken: 'at',
  refreshToken: 'rt',
  userId: 'u',
);

void main() {
  testWidgets('app resume (issue #155) refreshes the session via the lifecycle '
      'observer', (tester) async {
    final session = _FakeSessionIdentityService(initial: _session);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionIdentityServiceProvider.overrideWithValue(session),
          initialLocationProvider.overrideWith(
            (ref) async => const ResolvedLocation(
              center: istanbulFallback,
              isFallback: true,
            ),
          ),
          catsMapProvider.overrideWith(
            () => _FixedCatsMapNotifier(const CatsMapState()),
          ),
        ],
        child: const CatsOfIstanbulApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(session.refreshCallCount, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(session.refreshCallCount, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    expect(
      session.refreshCallCount,
      1,
      reason: 'non-resumed transitions must not trigger a refresh',
    );
  });
}
