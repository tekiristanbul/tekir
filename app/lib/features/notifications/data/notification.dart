/// Wire shape from `GET /v1/me/notifications` (docs/architecture/api.md,
/// issue #78): one in-app notification record — the authenticated
/// account's own view of "a followed cat's needs-help update", since this
/// mvp slice has no real push transport (see the backend's
/// NotificationSender doc comment). `read` is server-decided from
/// `notifications.read_at`, never tracked client-side.
class AppNotification {
  const AppNotification({
    required this.id,
    required this.catId,
    required this.updateId,
    required this.read,
    required this.createdAt,
  });

  final String id;
  final String catId;
  final String updateId;
  final bool read;
  final DateTime createdAt;

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    return AppNotification(
      id: json['id'] as String,
      catId: json['cat_id'] as String,
      updateId: json['update_id'] as String,
      read: json['read'] as bool,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

/// One newest-first page of the account's notifications. nextCursor is the
/// opaque token to pass back verbatim for the next page; null once there is
/// no further page.
class NotificationsPage {
  const NotificationsPage({required this.items, required this.nextCursor});

  final List<AppNotification> items;
  final String? nextCursor;

  factory NotificationsPage.fromJson(Map<String, dynamic> json) {
    return NotificationsPage(
      items: (json['items'] as List<dynamic>)
          .map((e) => AppNotification.fromJson(e as Map<String, dynamic>))
          .toList(),
      nextCursor: json['next_cursor'] as String?,
    );
  }
}
