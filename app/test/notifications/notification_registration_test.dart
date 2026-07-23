import 'dart:async';

import 'package:drover/src/notifications/notification_registration.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registers an authorized iOS device', () async {
    final messaging = _FakePushMessaging(
      authorization: NotificationAuthorization.authorized,
      apnsToken: 'apns-token',
      fcmToken: 'fcm-token',
    );
    final gateway = _RecordingGateway();
    final registration = NotificationRegistration(
      messaging: messaging,
      gateway: gateway,
      deviceIdStore: _FixedDeviceIdStore(),
      platform: TargetPlatform.iOS,
    );
    addTearDown(registration.dispose);

    await registration.initialize();

    expect(gateway.registrations, [
      const _DeviceRegistration('device-id', 'fcm-token', 'ios'),
    ]);
  });

  test('does not register a device when permission is denied', () async {
    final gateway = _RecordingGateway();
    final registration = NotificationRegistration(
      messaging: _FakePushMessaging(
        authorization: NotificationAuthorization.denied,
      ),
      gateway: gateway,
      deviceIdStore: _FixedDeviceIdStore(),
      platform: TargetPlatform.iOS,
    );
    addTearDown(registration.dispose);

    await registration.initialize();

    expect(gateway.registrations, isEmpty);
  });

  test('reports an unavailable APNs token', () async {
    final registration = NotificationRegistration(
      messaging: _FakePushMessaging(
        authorization: NotificationAuthorization.authorized,
        fcmToken: 'fcm-token',
      ),
      gateway: _RecordingGateway(),
      deviceIdStore: _FixedDeviceIdStore(),
      platform: TargetPlatform.iOS,
      delay: _noDelay,
    );
    addTearDown(registration.dispose);

    await expectLater(registration.initialize(), throwsStateError);
  });

  test('waits for the APNs token before registering', () async {
    final gateway = _RecordingGateway();
    final registration = NotificationRegistration(
      messaging: _FakePushMessaging(
        authorization: NotificationAuthorization.authorized,
        apnsTokens: [null, 'apns-token'],
        fcmToken: 'fcm-token',
      ),
      gateway: gateway,
      deviceIdStore: _FixedDeviceIdStore(),
      platform: TargetPlatform.iOS,
      delay: _noDelay,
    );
    addTearDown(registration.dispose);

    await registration.initialize();

    expect(gateway.registrations, [
      const _DeviceRegistration('device-id', 'fcm-token', 'ios'),
    ]);
  });

  test('re-registers when FCM refreshes the token', () async {
    final messaging = _FakePushMessaging(
      authorization: NotificationAuthorization.authorized,
      apnsToken: 'apns-token',
      fcmToken: 'initial-token',
    );
    final gateway = _RecordingGateway();
    final registration = NotificationRegistration(
      messaging: messaging,
      gateway: gateway,
      deviceIdStore: _FixedDeviceIdStore(),
      platform: TargetPlatform.macOS,
    );
    addTearDown(registration.dispose);

    await registration.initialize();
    messaging.addRefreshedToken('refreshed-token');
    await Future<void>.delayed(Duration.zero);

    expect(gateway.registrations, [
      const _DeviceRegistration('device-id', 'initial-token', 'macos'),
      const _DeviceRegistration('device-id', 'refreshed-token', 'macos'),
    ]);
  });
}

class _FakePushMessaging implements PushMessaging {
  _FakePushMessaging({
    required this.authorization,
    this.apnsToken,
    List<String?>? apnsTokens,
    this.fcmToken,
  }) : _apnsTokens = apnsTokens ?? [];

  final NotificationAuthorization authorization;
  final String? apnsToken;
  final String? fcmToken;
  final List<String?> _apnsTokens;
  final _refreshedTokens = StreamController<String>();

  @override
  Stream<String> get onTokenRefresh => _refreshedTokens.stream;

  @override
  Future<String?> getApnsToken() async =>
      _apnsTokens.isNotEmpty ? _apnsTokens.removeAt(0) : apnsToken;

  @override
  Future<String?> getFcmToken() async => fcmToken;

  @override
  Future<NotificationAuthorization> requestAuthorization() async =>
      authorization;

  void addRefreshedToken(String token) => _refreshedTokens.add(token);
}

class _FixedDeviceIdStore implements DeviceIdStore {
  @override
  Future<String> readOrCreate() async => 'device-id';
}

class _RecordingGateway implements DeviceRegistrationGateway {
  final registrations = <_DeviceRegistration>[];

  @override
  Future<void> registerDevice({
    required String deviceId,
    required String fcmToken,
    required String platform,
  }) async {
    registrations.add(_DeviceRegistration(deviceId, fcmToken, platform));
  }
}

class _DeviceRegistration {
  const _DeviceRegistration(this.deviceId, this.fcmToken, this.platform);

  final String deviceId;
  final String fcmToken;
  final String platform;

  @override
  bool operator ==(Object other) =>
      other is _DeviceRegistration &&
      deviceId == other.deviceId &&
      fcmToken == other.fcmToken &&
      platform == other.platform;

  @override
  int get hashCode => Object.hash(deviceId, fcmToken, platform);
}

Future<void> _noDelay(Duration _) async {}
