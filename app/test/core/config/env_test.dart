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
}
