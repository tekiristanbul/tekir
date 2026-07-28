import 'package:firebase_messaging/firebase_messaging.dart';

/// Outcome vocabulary for a notification-permission request, provider
/// neutral so product code and tests never touch a Firebase type.
enum PushPermissionStatus { granted, denied, notRequested }

/// One received/opened push message, reduced to what the app needs: the
/// provider message id (for duplicate-open protection) and the bounded data
/// payload the backend sender attached (type/cat_id/update_id/category —
/// see the backend's FCMNotificationSender).
class PushMessage {
  const PushMessage({this.messageId, this.data = const {}});

  final String? messageId;
  final Map<String, String> data;
}

/// The provider-side surface [PushNotificationsService] needs, hidden
/// behind an interface (mirroring the backend's NotificationSender split,
/// issue #84) so the service is fully testable with a fake and
/// firebase_messaging types stay confined to [FirebaseMessagingBackend].
abstract class PushMessagingBackend {
  Future<PushPermissionStatus> requestPermission();
  Future<PushPermissionStatus> currentPermission();

  /// The current registration token, or null when unavailable (permission
  /// missing, unsupported platform, web without a vapid key).
  Future<String?> getToken({String? vapidKey});

  Stream<String> get onTokenRefresh;

  /// Messages arriving while the app is in the foreground.
  Stream<PushMessage> get onForegroundMessage;

  /// The user tapped a notification while the app ran in the background.
  Stream<PushMessage> get onMessageOpened;

  /// The notification tap that launched a terminated app, if any. The
  /// underlying firebase api returns it once; subsequent calls are null.
  Future<PushMessage?> takeInitialMessage();
}

/// Real firebase_messaging adapter.
class FirebaseMessagingBackend implements PushMessagingBackend {
  FirebaseMessaging get _messaging => FirebaseMessaging.instance;

  static PushPermissionStatus _map(AuthorizationStatus status) {
    return switch (status) {
      AuthorizationStatus.authorized ||
      AuthorizationStatus.provisional => PushPermissionStatus.granted,
      AuthorizationStatus.denied => PushPermissionStatus.denied,
      AuthorizationStatus.notDetermined => PushPermissionStatus.notRequested,
    };
  }

  static PushMessage _mapMessage(RemoteMessage message) {
    return PushMessage(
      messageId: message.messageId,
      data: message.data.map((k, v) => MapEntry(k, v.toString())),
    );
  }

  @override
  Future<PushPermissionStatus> requestPermission() async {
    final settings = await _messaging.requestPermission();
    return _map(settings.authorizationStatus);
  }

  @override
  Future<PushPermissionStatus> currentPermission() async {
    final settings = await _messaging.getNotificationSettings();
    return _map(settings.authorizationStatus);
  }

  @override
  Future<String?> getToken({String? vapidKey}) =>
      _messaging.getToken(vapidKey: vapidKey);

  @override
  Stream<String> get onTokenRefresh => _messaging.onTokenRefresh;

  @override
  Stream<PushMessage> get onForegroundMessage =>
      FirebaseMessaging.onMessage.map(_mapMessage);

  @override
  Stream<PushMessage> get onMessageOpened =>
      FirebaseMessaging.onMessageOpenedApp.map(_mapMessage);

  @override
  Future<PushMessage?> takeInitialMessage() async {
    final message = await _messaging.getInitialMessage();
    return message == null ? null : _mapMessage(message);
  }
}
