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

  test('sends the current notification preferences', () async {
    final gateway = _RecordingGateway();
    final registration = _preferenceRegistration(gateway)
      ..preferences = () => (onBlocked: false, onDone: true);
    addTearDown(registration.dispose);

    await registration.initialize();

    expect(gateway.registrations, [
      const _DeviceRegistration(
        'device-id',
        'fcm-token',
        'ios',
        notifyOnBlocked: false,
      ),
    ]);
  });

  test(
    'refreshRegistration re-sends the token with the new preferences',
    () async {
      final gateway = _RecordingGateway();
      var preferences = (onBlocked: true, onDone: true);
      final registration = _preferenceRegistration(gateway)
        ..preferences = () => preferences;
      addTearDown(registration.dispose);

      await registration.initialize();
      preferences = (onBlocked: true, onDone: false);
      await registration.refreshRegistration();

      expect(gateway.registrations, [
        const _DeviceRegistration('device-id', 'fcm-token', 'ios'),
        const _DeviceRegistration(
          'device-id',
          'fcm-token',
          'ios',
          notifyOnDone: false,
        ),
      ]);
    },
  );

  test(
    'refreshRegistration retries a first registration that failed',
    () async {
      final gateway = _RecordingGateway(failingCalls: 1);
      final registration = _preferenceRegistration(gateway)
        ..preferences = () => (onBlocked: true, onDone: false);
      addTearDown(registration.dispose);

      await expectLater(registration.initialize(), throwsStateError);
      await registration.refreshRegistration();

      expect(gateway.registrations, [
        const _DeviceRegistration(
          'device-id',
          'fcm-token',
          'ios',
          notifyOnDone: false,
        ),
      ]);
    },
  );

  test('refreshRegistration rethrows so the caller can report it', () async {
    final gateway = _RecordingGateway(failingCalls: 2);
    final registration = _preferenceRegistration(gateway);
    addTearDown(registration.dispose);

    await expectLater(registration.initialize(), throwsStateError);

    await expectLater(registration.refreshRegistration(), throwsStateError);
  });

  test(
    'refreshRegistration is a no-op before the first registration',
    () async {
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

      await registration.refreshRegistration();

      expect(gateway.registrations, isEmpty);
    },
  );
}

NotificationRegistration _preferenceRegistration(_RecordingGateway gateway) =>
    NotificationRegistration(
      messaging: _FakePushMessaging(
        authorization: NotificationAuthorization.authorized,
        apnsToken: 'apns-token',
        fcmToken: 'fcm-token',
      ),
      gateway: gateway,
      deviceIdStore: _FixedDeviceIdStore(),
      platform: TargetPlatform.iOS,
    );

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
  _RecordingGateway({this.failingCalls = 0});

  /// How many leading calls throw before the gateway starts recording, so a
  /// test can put a device in the state a launch without network leaves it.
  int failingCalls;
  final registrations = <_DeviceRegistration>[];

  @override
  Future<void> registerDevice({
    required String deviceId,
    required String fcmToken,
    required String platform,
    required bool notifyOnBlocked,
    required bool notifyOnDone,
  }) async {
    if (failingCalls > 0) {
      failingCalls -= 1;
      throw StateError('registerDevice is unavailable.');
    }
    registrations.add(
      _DeviceRegistration(
        deviceId,
        fcmToken,
        platform,
        notifyOnBlocked: notifyOnBlocked,
        notifyOnDone: notifyOnDone,
      ),
    );
  }
}

class _DeviceRegistration {
  const _DeviceRegistration(
    this.deviceId,
    this.fcmToken,
    this.platform, {
    this.notifyOnBlocked = true,
    this.notifyOnDone = true,
  });

  final String deviceId;
  final String fcmToken;
  final String platform;
  final bool notifyOnBlocked;
  final bool notifyOnDone;

  @override
  bool operator ==(Object other) =>
      other is _DeviceRegistration &&
      deviceId == other.deviceId &&
      fcmToken == other.fcmToken &&
      platform == other.platform &&
      notifyOnBlocked == other.notifyOnBlocked &&
      notifyOnDone == other.notifyOnDone;

  @override
  int get hashCode =>
      Object.hash(deviceId, fcmToken, platform, notifyOnBlocked, notifyOnDone);

  @override
  String toString() =>
      '_DeviceRegistration($deviceId, $fcmToken, $platform, '
      'blocked: $notifyOnBlocked, done: $notifyOnDone)';
}

Future<void> _noDelay(Duration _) async {}
