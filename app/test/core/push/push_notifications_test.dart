import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/analytics/analytics.dart';
import 'package:app/core/push/push_messaging_backend.dart';
import 'package:app/core/push/push_notifications.dart';

// ── fakes ────────────────────────────────────────────────────────────────────

class _RecordingAnalytics implements AnalyticsService {
  final events = <AnalyticsEvent>[];

  @override
  void log(AnalyticsEvent event) => events.add(event);

  List<String> names() => events.map((e) => e.name).toList();
}

class _FakeBackend implements PushMessagingBackend {
  PushPermissionStatus permission = PushPermissionStatus.notRequested;
  PushPermissionStatus requestOutcome = PushPermissionStatus.granted;
  String? token = 'fcm-token-1';
  PushMessage? initialMessage;
  int requestPermissionCalls = 0;

  final tokenRefreshController = StreamController<String>.broadcast();
  final foregroundController = StreamController<PushMessage>.broadcast();
  final openedController = StreamController<PushMessage>.broadcast();

  @override
  Future<PushPermissionStatus> requestPermission() async {
    requestPermissionCalls++;
    permission = requestOutcome;
    return requestOutcome;
  }

  @override
  Future<PushPermissionStatus> currentPermission() async => permission;

  @override
  Future<String?> getToken({String? vapidKey}) async => token;

  @override
  Stream<String> get onTokenRefresh => tokenRefreshController.stream;

  @override
  Stream<PushMessage> get onForegroundMessage => foregroundController.stream;

  @override
  Stream<PushMessage> get onMessageOpened => openedController.stream;

  @override
  Future<PushMessage?> takeInitialMessage() async {
    final m = initialMessage;
    initialMessage = null;
    return m;
  }
}

/// Records PUT /v1/devices/me calls; can fail on demand.
class _RecordingAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  bool fail = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (fail) return ResponseBody.fromString('', 500);
    return ResponseBody.fromString('', 204);
  }

  @override
  void close({bool force = false}) {}
}

const _catId = '5e0ee46e-9f0a-4b2f-9e56-0aa9d0a4f3a2';

({
  PushNotificationsService service,
  _FakeBackend backend,
  _RecordingAnalytics analytics,
  _RecordingAdapter adapter,
  List<String> openedCats,
})
_build() {
  final backend = _FakeBackend();
  final analytics = _RecordingAnalytics();
  final adapter = _RecordingAdapter();
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080'));
  dio.httpClientAdapter = adapter;
  final openedCats = <String>[];
  final service = PushNotificationsService(
    backend: backend,
    analytics: analytics,
    dio: dio,
    openCatDetail: openedCats.add,
  );
  return (
    service: service,
    backend: backend,
    analytics: analytics,
    adapter: adapter,
    openedCats: openedCats,
  );
}

void main() {
  test('disabled service is fully inert', () async {
    final service = PushNotificationsService.disabled();
    expect(service.isEnabled, isFalse);
    await service.start();
    expect(await service.requestPermissionAndRegister(), isFalse);
  });

  test('granted permission logs the result and registers the token', () async {
    final t = _build();
    final granted = await t.service.requestPermissionAndRegister();

    expect(granted, isTrue);
    expect(t.backend.requestPermissionCalls, 1);
    expect(t.analytics.names(), ['notification_permission_result']);
    expect(t.analytics.events.single.params, {'result': 'success'});

    expect(t.adapter.requests, hasLength(1));
    final req = t.adapter.requests.single;
    expect(req.method, 'PUT');
    expect(req.path, '/v1/devices/me');
    expect(req.data, {'push_token': 'fcm-token-1'});
  });

  test('denied permission logs the result and never registers', () async {
    final t = _build();
    t.backend.requestOutcome = PushPermissionStatus.denied;

    expect(await t.service.requestPermissionAndRegister(), isFalse);
    expect(t.analytics.events.single.params, {'result': 'permission_denied'});
    expect(t.adapter.requests, isEmpty);
  });

  test('start syncs the token only when permission was already granted', () async {
    final t = _build();
    t.backend.permission = PushPermissionStatus.granted;
    await t.service.start();
    expect(t.adapter.requests, hasLength(1));

    final u = _build();
    u.backend.permission = PushPermissionStatus.notRequested;
    await u.service.start();
    expect(u.adapter.requests, isEmpty);
  });

  test('a token refresh re-registers without duplicate device rows client-side', () async {
    final t = _build();
    await t.service.start();
    t.backend.tokenRefreshController.add('fcm-token-rotated');
    // dio's request pipeline spans several event-loop turns — a single
    // zero-delay flush isn't enough for the PUT to reach the adapter.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(t.adapter.requests, hasLength(1));
    expect(t.adapter.requests.single.data, {'push_token': 'fcm-token-rotated'});
  });

  test('a failed registration is swallowed, never thrown', () async {
    final t = _build();
    t.adapter.fail = true;
    expect(await t.service.requestPermissionAndRegister(), isTrue);
  });

  test('a foreground message logs notification_received and nothing else', () async {
    final t = _build();
    await t.service.start();
    t.backend.foregroundController.add(
      const PushMessage(messageId: 'm1', data: {'cat_id': _catId}),
    );
    await Future<void>.delayed(Duration.zero);

    expect(t.analytics.names(), ['notification_received']);
    expect(t.analytics.events.single.params, {
      'notification_state': 'foreground',
    });
    expect(t.openedCats, isEmpty);
  });

  test('a background open navigates to the cat and logs the open', () async {
    final t = _build();
    await t.service.start();
    t.backend.openedController.add(
      const PushMessage(messageId: 'm1', data: {'cat_id': _catId}),
    );
    await Future<void>.delayed(Duration.zero);

    expect(t.openedCats, [_catId]);
    expect(t.analytics.names(), ['notification_opened']);
    expect(t.analytics.events.single.params, {
      'notification_state': 'background',
    });
  });

  test('a terminated-app launch handles the initial message once', () async {
    final t = _build();
    t.backend.initialMessage = const PushMessage(
      messageId: 'm1',
      data: {'cat_id': _catId},
    );
    await t.service.start();

    expect(t.openedCats, [_catId]);
    expect(t.analytics.events.single.params, {
      'notification_state': 'terminated',
    });
  });

  test('the same message delivered through two callbacks opens once', () async {
    // the duplicate-callback protection issue #84 requires: an initial
    // message and an opened-app callback for the same message id must not
    // navigate twice.
    final t = _build();
    t.backend.initialMessage = const PushMessage(
      messageId: 'm1',
      data: {'cat_id': _catId},
    );
    await t.service.start();
    t.backend.openedController.add(
      const PushMessage(messageId: 'm1', data: {'cat_id': _catId}),
    );
    await Future<void>.delayed(Duration.zero);

    expect(t.openedCats, [_catId]);
  });

  test('distinct messages each navigate', () async {
    final t = _build();
    await t.service.start();
    t.backend.openedController.add(
      const PushMessage(messageId: 'm1', data: {'cat_id': _catId}),
    );
    await Future<void>.delayed(Duration.zero);
    t.backend.openedController.add(
      const PushMessage(messageId: 'm2', data: {'cat_id': _catId}),
    );
    await Future<void>.delayed(Duration.zero);

    expect(t.openedCats, [_catId, _catId]);
  });

  test('a malformed or missing cat id never reaches the router', () async {
    final t = _build();
    await t.service.start();
    t.backend.openedController.add(
      const PushMessage(
        messageId: 'm1',
        data: {'cat_id': '../../../evil<script>'},
      ),
    );
    t.backend.openedController.add(const PushMessage(messageId: 'm2'));
    await Future<void>.delayed(Duration.zero);

    expect(t.openedCats, isEmpty);
    // the opens themselves are still counted.
    expect(t.analytics.names(), [
      'notification_opened',
      'notification_opened',
    ]);
  });
}
