import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/config/env.dart';

void main() {
  group('Env.resolveApiBaseUrl', () {
    test('debug/profile falls back to localhost when unset', () {
      expect(
        Env.resolveApiBaseUrl(raw: null, isRelease: false),
        'http://localhost:8080',
      );
    });

    test('release throws a StateError when unset', () {
      expect(
        () => Env.resolveApiBaseUrl(raw: null, isRelease: true),
        throwsA(isA<StateError>()),
      );
    });

    test('release accepts an explicit localhost value without throwing', () {
      expect(
        Env.resolveApiBaseUrl(raw: 'http://localhost:8080', isRelease: true),
        'http://localhost:8080',
      );
    });

    test('release returns an explicit non-localhost value', () {
      expect(
        Env.resolveApiBaseUrl(
          raw: 'https://app.tekir.istanbul/api',
          isRelease: true,
        ),
        'https://app.tekir.istanbul/api',
      );
    });
  });

  group('Env.unrecognizedProviderWarningsFor', () {
    test('returns nothing for known provider values', () {
      expect(
        Env.unrecognizedProviderWarningsFor(
          analyticsProvider: 'firebase',
          notificationProvider: 'fcm',
        ),
        isEmpty,
      );
      expect(
        Env.unrecognizedProviderWarningsFor(
          analyticsProvider: 'none',
          notificationProvider: 'fake',
        ),
        isEmpty,
      );
    });

    test('warns on an unrecognized ANALYTICS_PROVIDER value', () {
      final warnings = Env.unrecognizedProviderWarningsFor(
        analyticsProvider: 'firebse',
        notificationProvider: 'fake',
      );
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('ANALYTICS_PROVIDER="firebse"'));
    });

    test('warns on an unrecognized NOTIFICATION_PROVIDER value', () {
      final warnings = Env.unrecognizedProviderWarningsFor(
        analyticsProvider: 'none',
        notificationProvider: 'fmc',
      );
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('NOTIFICATION_PROVIDER="fmc"'));
    });

    test('warns on both when both are unrecognized', () {
      expect(
        Env.unrecognizedProviderWarningsFor(
          analyticsProvider: 'nope',
          notificationProvider: 'nope',
        ),
        hasLength(2),
      );
    });
  });
}
