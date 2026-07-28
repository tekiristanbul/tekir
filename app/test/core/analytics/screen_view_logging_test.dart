import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/analytics/analytics.dart';
import 'package:app/core/analytics/screen_view_logging.dart';

void main() {
  test('route paths map onto the approved screen vocabulary', () {
    expect(analyticsScreenForPath('/'), AnalyticsScreen.map);
    expect(analyticsScreenForPath('/discover'), AnalyticsScreen.discover);
    expect(analyticsScreenForPath('/profile'), AnalyticsScreen.profile);
    expect(analyticsScreenForPath('/login'), AnalyticsScreen.login);
    expect(analyticsScreenForPath('/account'), AnalyticsScreen.account);
    expect(analyticsScreenForPath('/add-cat'), AnalyticsScreen.addCat);
    expect(
      analyticsScreenForPath('/notifications'),
      AnalyticsScreen.notifications,
    );
    expect(analyticsScreenForPath('/badges'), AnalyticsScreen.badges);
    expect(
      analyticsScreenForPath('/badges/first_report'),
      AnalyticsScreen.badgeDetail,
    );
    expect(
      analyticsScreenForPath('/cats/5e0ee46e-9f0a-4b2f-9e56-0aa9d0a4f3a2'),
      AnalyticsScreen.catDetail,
    );
  });

  test('unrecognized paths produce no screen view at all', () {
    expect(analyticsScreenForPath('/totally-unknown'), isNull);
    expect(analyticsScreenForPath(''), isNull);
  });

  test('the mapped value never contains the path parameter', () {
    // issue #84: raw cat/badge ids stay out of analytics — the event only
    // ever carries the vocabulary value, not the concrete path.
    final screen = analyticsScreenForPath('/cats/some-raw-id')!;
    expect(screen.wire, 'cat_detail');
    expect(screen.wire.contains('some-raw-id'), isFalse);
  });
}
