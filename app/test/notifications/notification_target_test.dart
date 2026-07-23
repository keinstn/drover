import 'package:drover/src/notifications/notification_target.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a notification agent target', () {
    final target = NotificationTarget.fromData({
      'hostId': 'host-123',
      'paneId': 'workspace:pane',
      'eventId': 'event-123',
    });

    expect(target, isNotNull);
    expect(target!.hostId, 'host-123');
    expect(target.paneId, 'workspace:pane');
    expect(target.eventId, 'event-123');
  });

  test('rejects notification data without a pane target', () {
    expect(NotificationTarget.fromData({'hostId': 'host-123'}), isNull);
    expect(NotificationTarget.fromData({'paneId': ''}), isNull);
  });
}
