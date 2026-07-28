import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/utils/distance_format.dart';

void main() {
  group('formatDistanceTr', () {
    test('rounds sub-km distances to the nearest 10m', () {
      expect(formatDistanceTr(42), '40 m');
      expect(formatDistanceTr(125), '130 m');
    });

    test('never reports below 10m even for an exact-position match', () {
      expect(formatDistanceTr(0), '10 m');
      expect(formatDistanceTr(4), '10 m');
    });

    test('switches to km with a turkish comma at 1000m and above', () {
      expect(formatDistanceTr(1000), '1,0 km');
      expect(formatDistanceTr(1234), '1,2 km');
      expect(formatDistanceTr(15600), '15,6 km');
    });
  });
}
