/// The navigation target carried in an FCM data payload.
///
/// [hostId] names the stored Herdr host the event came from — drover switches
/// to it when it isn't the active host — and [paneId] identifies the pane on
/// that host.
class NotificationTarget {
  const NotificationTarget({
    required this.paneId,
    required this.hostId,
    this.eventId,
  });

  final String paneId;
  final String hostId;
  final String? eventId;

  static NotificationTarget? fromData(Map<String, dynamic> data) {
    final paneId = _nonEmptyString(data['paneId']);
    final hostId = _nonEmptyString(data['hostId']);
    if (paneId == null || hostId == null) return null;
    return NotificationTarget(
      paneId: paneId,
      hostId: hostId,
      eventId: _nonEmptyString(data['eventId']),
    );
  }

  static String? _nonEmptyString(dynamic value) =>
      value is String && value.isNotEmpty ? value : null;
}
