import 'package:drover/main.dart';
import 'package:drover/src/demo/demo_backend.dart';
import 'package:drover/src/infra/host_store.dart';
import 'package:drover/src/infra/settings_store.dart';
import 'package:drover/src/notifications/host_pairing.dart';
import 'package:drover/src/notifications/notification_registration.dart';
import 'package:drover/src/screens/host_setup_screen.dart';
import 'package:drover/src/speech/speech_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records [saveHosts] calls instead of touching real secure storage, so a
/// test can assert drover never persists the demo as a stored host.
class _SpyHostStore extends HostStore {
  int saveCalls = 0;

  @override
  Future<HostsState> loadHosts() async => const HostsState(hosts: []);

  @override
  Future<void> saveHosts(HostsState state) async {
    saveCalls++;
  }
}

class _FakePushMessaging implements PushMessaging {
  @override
  Future<NotificationAuthorization> requestAuthorization() async =>
      NotificationAuthorization.denied;

  @override
  Future<String?> getApnsToken() async => null;

  @override
  Future<String?> getFcmToken() async => null;

  @override
  Stream<String> get onTokenRefresh => const Stream.empty();
}

class _FakeDeviceRegistrationGateway implements DeviceRegistrationGateway {
  @override
  Future<void> registerDevice({
    required String deviceId,
    required String fcmToken,
    required String platform,
  }) async {}
}

class _FakeDeviceIdStore implements DeviceIdStore {
  @override
  Future<String> readOrCreate() async => 'device-id';
}

class _NoopHostPairingGateway implements HostPairingGateway {
  @override
  Future<PairingCode> createPairingCode(String hostId) async =>
      throw UnimplementedError('not used by this test');

  @override
  Future<void> revokeHost(String hostId) async {}
}

class _NoopSpeechInput implements SpeechInput {
  @override
  Future<SpeechInputStartResult> start({
    required SpeechInputResultListener onResult,
    required SpeechInputStatusListener onStatus,
    required SpeechInputErrorListener onError,
  }) async => const SpeechInputStartResult.failed('unavailable in tests');

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {}
}

/// Builds a [DroverApp] with every Firebase-backed collaborator replaced by a
/// fake, so it can run under `flutter test` without `Firebase.initializeApp`.
Widget _app({required HostStore hostStore}) => DroverApp(
  hostStore: hostStore,
  settingsStore: SettingsStore(),
  notificationRegistration: NotificationRegistration(
    messaging: _FakePushMessaging(),
    gateway: _FakeDeviceRegistrationGateway(),
    deviceIdStore: _FakeDeviceIdStore(),
    platform: TargetPlatform.iOS,
  ),
  hostPairingGateway: _NoopHostPairingGateway(),
  speechInput: _NoopSpeechInput(),
);

void main() {
  testWidgets(
    'entering and exiting the demo leaves hosts empty and never writes to '
    'HostStore',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final hostStore = _SpyHostStore();
      await tester.pumpWidget(_app(hostStore: hostStore));
      await tester.pump();
      await tester.pump();

      // First run, no hosts: the setup screen offers the demo entry.
      expect(find.byType(HostSetupScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('enter_demo_button')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('enter_demo_button')));
      await tester.pump();
      await tester.pump();

      // The demo replaced the setup screen; its exit affordance is showing,
      // and nothing was persisted to open it.
      expect(find.byType(HostSetupScreen), findsNothing);
      expect(find.byKey(const ValueKey('demo_exit_button')), findsOneWidget);
      expect(hostStore.saveCalls, 0);

      await tester.tap(find.byKey(const ValueKey('demo_exit_button')));
      await tester.pump();
      await tester.pump();

      // Exiting returns to first-run setup — hosts are still empty, so
      // nothing was ever written to HostStore.
      expect(find.byType(HostSetupScreen), findsOneWidget);
      expect(hostStore.saveCalls, 0);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the exit affordance stays visible after navigating into the demo agent',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_app(hostStore: _SpyHostStore()));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('enter_demo_button')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('demo_exit_button')), findsOneWidget);

      // Open the single demo agent from the herd list.
      await tester.tap(find.byKey(ValueKey('agent-$demoHostId-$demoPaneId')));
      await tester.pump();
      await tester.pump();

      // The nested Navigator pushed AgentScreen, but the banner (owned by
      // DemoScreen, outside that Navigator) is still on screen.
      expect(find.byKey(const ValueKey('demo_exit_button')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );
}
