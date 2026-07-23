/// The navigation target carried in an FCM data payload.
///
/// Drover currently stores one Herdr host, so [hostId] is retained for the
/// future host-pairing lookup while [paneId] identifies the current target.
class NotificationTarget {
  const NotificationTarget({required this.paneId, this.hostId, this.eventId});

  final String paneId;
  final String? hostId;
  final String? eventId;

  static NotificationTarget? fromData(Map<String, dynamic> data) {
    final paneId = _nonEmptyString(data['paneId']);
    if (paneId == null) return null;
    return NotificationTarget(
      paneId: paneId,
      hostId: _nonEmptyString(data['hostId']),
      eventId: _nonEmptyString(data['eventId']),
    );
  }

  static String? _nonEmptyString(dynamic value) =>
      value is String && value.isNotEmpty ? value : null;
}
