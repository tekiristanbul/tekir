import 'package:app/features/map/data/cat_marker.dart';
import 'package:app/features/notifications/ui/quiet_day_notifier.dart';
import 'package:flutter_test/flutter_test.dart';

CatMarker _cat(String id, {DateTime? seenAt}) => CatMarker(
  id: id,
  primaryPhoto: '',
  lat: 41.0,
  lng: 29.0,
  lastUpdateAt: seenAt,
);

void main() {
  final now = DateTime(2026, 8, 4, 10, 30);

  group('quietDayFreshnessTr', () {
    test('uses day-level copy from the contract', () {
      expect(
        quietDayFreshnessTr(DateTime(2026, 8, 4, 1), now),
        'bugün görüldü',
      );
      expect(quietDayFreshnessTr(DateTime(2026, 8, 3, 23), now), 'dün görüldü');
      expect(quietDayFreshnessTr(DateTime(2026, 8, 2), now), '2 gün önce');
      expect(quietDayFreshnessTr(DateTime(2026, 7, 28), now), '7 gün önce');
    });

    test('clamps a future timestamp to today', () {
      expect(
        quietDayFreshnessTr(now.add(const Duration(hours: 20)), now),
        'bugün görüldü',
      );
    });
  });

  group('quietDayWindowDays', () {
    test('covers the oldest sighting', () {
      final cats = [
        _cat('1', seenAt: DateTime(2026, 8, 4)),
        _cat('2', seenAt: DateTime(2026, 8, 3)),
        _cat('3', seenAt: DateTime(2026, 8, 2)),
      ];
      expect(quietDayWindowDays(cats, now), 3);
    });

    test('is 1 when everyone was seen today', () {
      expect(quietDayWindowDays([_cat('1', seenAt: now)], now), 1);
    });

    test('drops (null) without follows or without a real timestamp', () {
      expect(quietDayWindowDays(const [], now), isNull);
      expect(
        quietDayWindowDays([_cat('1', seenAt: now), _cat('2')], now),
        isNull,
      );
    });
  });
}
