import 'dart:async';

import 'package:drover/main.dart';
import 'package:drover/src/demo/demo_backend.dart';
import 'package:drover/src/demo/demo_content_en.dart';
import 'package:drover/src/demo/demo_content_ja.dart';
import 'package:drover/src/infra/host_connections.dart';
import 'package:drover/src/infra/host_store.dart';
import 'package:drover/src/infra/network_change_signal.dart';
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

/// A controllable [NetworkChangeSignal] so a test can fire `changes` events
/// directly, without a real platform channel.
class _FakeNetworkChangeSignal implements NetworkChangeSignal {
  final _controller = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => _controller.stream;

  void emit() => _controller.add(null);

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}

/// Counts [invalidateAll] calls instead of touching real SSH connections, so
/// a test can prove `_DroverAppState`'s
/// `_networkChangeSignal.changes.listen(...)` subscription in `initState`
/// actually reaches the registry. The build function is never invoked (this
/// test never obtains a host connection).
class _CountingRegistry extends HostConnectionRegistry {
  _CountingRegistry() : super((_) => throw UnimplementedError('not used'));

  int invalidateAllCalls = 0;

  @override
  Future<void> invalidateAll() async {
    invalidateAllCalls++;
  }
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
Widget _app({
  required HostStore hostStore,
  AppSettings settings = const AppSettings(),
  String? appVersion,
  NetworkChangeSignal? networkChangeSignal,
  HostConnectionRegistry? hostConnectionRegistry,
}) => DroverApp(
  hostStore: hostStore,
  settingsStore: SettingsStore(),
  initialSettings: settings,
  appVersion: appVersion,
  notificationRegistration: NotificationRegistration(
    messaging: _FakePushMessaging(),
    gateway: _FakeDeviceRegistrationGateway(),
    deviceIdStore: _FakeDeviceIdStore(),
    platform: TargetPlatform.iOS,
  ),
  hostPairingGateway: _NoopHostPairingGateway(),
  speechInput: _NoopSpeechInput(),
  networkChangeSignal: networkChangeSignal,
  hostConnectionRegistry: hostConnectionRegistry,
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
      // Underlined, because the ink accent is body-text colour and hue cannot
      // mark this as an action. Pinned because the claim once lived only in a
      // comment: the decoration was dropped in review and shipped without it.
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(const ValueKey('demo_exit_button')),
                matching: find.byType(Text),
              ),
            )
            .style
            ?.decoration,
        TextDecoration.underline,
      );
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

  testWidgets('the settings control inside the demo opens the real settings '
      'screen', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(hostStore: _SpyHostStore(), appVersion: '9.9.9 (42)'),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('enter_demo_button')));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    // Theme and language are host-independent, so they work in the demo just
    // as they do outside it. Regression guard for the gear being a visible
    // control that did nothing (App Store guideline 2.1).
    expect(find.text('Settings'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings_theme_tile')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings_language_tile')),
      findsOneWidget,
    );
    // ...but the demo is already showing, so it is not offered again.
    expect(find.byKey(const ValueKey('settings_demo_tile')), findsNothing);
    // The version read in main() has to actually reach the pushed route.
    // Asserting the text, not just the key, so a dropped pass-through
    // (which renders no row at all) can't satisfy this.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings_version_tile')),
        matching: find.text('9.9.9 (42)'),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a ja app enters the demo in Japanese, with the CLI output left '
      'in English', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(
        hostStore: _SpyHostStore(),
        settings: const AppSettings(locale: Locale('ja')),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('enter_demo_button')));
    await tester.pump();
    await tester.pump();

    // Covers the wiring main.dart owns: resolving the effective locale (which
    // may come from the device, not from a stored setting) into the demo's
    // content. `demo_screen_test.dart` covers the rendering in depth.
    expect(find.text(demoContentJa.scriptedTitle), findsOneWidget);
    expect(find.text(demoContentEn.scriptedTitle), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    "a network-change event reaches the injected registry's invalidateAll()",
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final registry = _CountingRegistry();
      final signal = _FakeNetworkChangeSignal();

      await tester.pumpWidget(
        _app(
          hostStore: _SpyHostStore(),
          networkChangeSignal: signal,
          hostConnectionRegistry: registry,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(registry.invalidateAllCalls, 0);

      signal.emit();
      // Proves initState's `_networkChangeSignal.changes.listen(...
      // _registry.invalidateAll ...)` subscription actually reached the
      // injected registry, not just that the signal itself fired.
      await tester.pump();

      expect(registry.invalidateAllCalls, 1);

      await tester.pumpWidget(const SizedBox());
    },
  );
}
