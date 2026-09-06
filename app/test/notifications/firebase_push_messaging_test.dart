import 'package:drover/src/notifications/notification_registration.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_messaging_platform_interface/firebase_messaging_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();

  final platform = _FakeMessagingPlatform();
  FirebaseMessagingPlatform.instance = platform;

  setUpAll(() async {
    await Firebase.initializeApp();
  });

  const expectedAuthorizations = {
    AuthorizationStatus.authorized: NotificationAuthorization.authorized,
    AuthorizationStatus.provisional: NotificationAuthorization.authorized,
    AuthorizationStatus.denied: NotificationAuthorization.denied,
    AuthorizationStatus.notDetermined: NotificationAuthorization.denied,
    AuthorizationStatus.deniedPermanently: NotificationAuthorization.denied,
  };

  test('covers every AuthorizationStatus value', () {
    expect(
      expectedAuthorizations.keys.toSet(),
      AuthorizationStatus.values.toSet(),
    );
  });

  expectedAuthorizations.forEach((status, expected) {
    test('maps $status to $expected', () async {
      platform.status = status;
      final messaging = FirebasePushMessaging(FirebaseMessaging.instance);

      expect(await messaging.requestAuthorization(), expected);
    });
  });
}

// `FirebaseMessaging.instance` caches its delegate on first use, so
// reassigning `FirebaseMessagingPlatform.instance` between tests wouldn't
// swap it back out; mutate this instance's `status` instead.
class _FakeMessagingPlatform extends FirebaseMessagingPlatform {
  AuthorizationStatus status = AuthorizationStatus.notDetermined;

  @override
  FirebaseMessagingPlatform delegateFor({required FirebaseApp app}) => this;

  @override
  FirebaseMessagingPlatform setInitialValues({bool? isAutoInitEnabled}) => this;

  @override
  Future<NotificationSettings> requestPermission({
    bool alert = true,
    bool announcement = false,
    bool badge = true,
    bool carPlay = false,
    bool criticalAlert = false,
    bool provisional = false,
    bool sound = true,
    bool providesAppNotificationSettings = false,
  }) async {
    return NotificationSettings(
      alert: AppleNotificationSetting.disabled,
      announcement: AppleNotificationSetting.disabled,
      authorizationStatus: status,
      badge: AppleNotificationSetting.disabled,
      carPlay: AppleNotificationSetting.disabled,
      lockScreen: AppleNotificationSetting.disabled,
      notificationCenter: AppleNotificationSetting.disabled,
      showPreviews: AppleShowPreviewSetting.never,
      timeSensitive: AppleNotificationSetting.disabled,
      criticalAlert: AppleNotificationSetting.disabled,
      sound: AppleNotificationSetting.disabled,
      providesAppNotificationSettings: AppleNotificationSetting.disabled,
    );
  }
}
