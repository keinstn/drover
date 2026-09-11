import 'dart:async';

import 'package:drover/main.dart';
import 'package:drover/src/demo/demo_backend.dart';
import 'package:drover/src/demo/demo_content_en.dart';
import 'package:drover/src/demo/demo_content_ja.dart';
import 'package:drover/src/infra/host_connections.dart';
import 'package:drover/src/infra/host_store.dart';
import 'package:drover/src/infra/network_change_signal.dart';
import 'package:drover/src/infra/settings_store.dart';
import 'package:drover/src/infra/stale_transport_signal.dart';
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

/// Never emits — used where a [NetworkChangeSignal] is required by the
/// constructor but the test drives staleness through [markStale] instead, so
/// no platform channel is exercised.
class _NeverNetworkChangeSignal implements NetworkChangeSignal {
  @override
  Stream<void> get changes => const Stream.empty();

  @override
  Future<void> dispose() async {}
}

/// Counts [markStale] calls, on top of the real [StaleTransportSignal]
/// coalescing/emission behavior — so a test can assert both that the
/// lifecycle callback actually invoked it, and that doing so genuinely
/// produces an event on [changes].
class _SpyStaleTransportSignal extends StaleTransportSignal {
  _SpyStaleTransportSignal()
    : super(
        _NeverNetworkChangeSignal(),
        debounce: const Duration(milliseconds: 10),
      );

  int markStaleCalls = 0;

  @override
  void markStale() {
    markStaleCalls++;
    super.markStale();
  }
}

/// Counts [invalidateAll] calls instead of touching real SSH connections, so
/// a test can prove `_DroverAppState`'s
/// `_staleTransportSignal.changes.listen(...)` subscription in `initState`
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
  StaleTransportSignal? staleTransportSignal,
  HostConnectionRegistry? hostConnectionRegistry,
  DateTime Function()? clock,
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
  staleTransportSignal: staleTransportSignal,
  hostConnectionRegistry: hostConnectionRegistry,
  clock: clock,
);

/// A mutable fake wall clock: tests advance [now] directly between lifecycle
/// transitions instead of sleeping the real background-stale threshold out.
class _FakeClock {
  DateTime now = DateTime(2026);
  DateTime call() => now;
}

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
    "a stale-transport event reaches the injected registry's invalidateAll()",
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final registry = _CountingRegistry();
      final signal = StaleTransportSignal(
        _NeverNetworkChangeSignal(),
        debounce: const Duration(milliseconds: 10),
      );

      await tester.pumpWidget(
        _app(
          hostStore: _SpyHostStore(),
          staleTransportSignal: signal,
          hostConnectionRegistry: registry,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(registry.invalidateAllCalls, 0);

      signal.markStale();
      // Past the signal's debounce, so `_staleTransportSignal.changes` has
      // emitted — proving initState's `_staleTransportSignal.changes.listen(
      // ... _registry.invalidateAll ...)` subscription actually reached the
      // injected registry, not just that the signal itself fired.
      await tester.pump(const Duration(milliseconds: 30));

      expect(registry.invalidateAllCalls, 1);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'resuming the app after a long background reaches the stale-transport '
    'signal, which then emits',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final signal = _SpyStaleTransportSignal();
      final events = <void>[];
      signal.changes.listen(events.add);
      final clock = _FakeClock();

      await tester.pumpWidget(
        _app(
          hostStore: _SpyHostStore(),
          staleTransportSignal: signal,
          clock: clock.call,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(signal.markStaleCalls, 0);
      expect(events, isEmpty);

      // Transitions other than "resumed" must not mark the transport stale
      // (closing a live socket on background buys nothing — herdr runs a
      // persistent server). Drives the real state machine end to end
      // (resumed -> inactive -> hidden -> paused, then back) rather than an
      // arbitrary pair, since `AppLifecycleListener` asserts on invalid
      // transitions.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(signal.markStaleCalls, 0);

      // The background outlives the staleness threshold (a real iOS
      // suspension), so this resume must mark the transport stale.
      clock.now = clock.now.add(const Duration(seconds: 15));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      // This proves the wiring, not just the method's existence: it only
      // passes if `_DroverAppState` actually registered itself as a
      // `WidgetsBindingObserver` in `initState` (`addObserver(this)`) — with
      // that call deleted, `didChangeAppLifecycleState` never runs and
      // `markStaleCalls` stays 0.
      expect(signal.markStaleCalls, 1);

      // `markStale()` alone isn't the whole path either: the signal debounces
      // before it emits on `changes`. Waiting past that debounce and
      // asserting the emission rules out a stub `markStale()` override that
      // swallows the call instead of routing it through the real coalescing
      // logic.
      await tester.pump(const Duration(milliseconds: 30));
      expect(events, hasLength(1));

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'resuming after a brief background does not mark the transport stale',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final signal = _SpyStaleTransportSignal();
      final clock = _FakeClock();

      await tester.pumpWidget(
        _app(
          hostStore: _SpyHostStore(),
          staleTransportSignal: signal,
          clock: clock.call,
        ),
      );
      await tester.pump();
      await tester.pump();

      // The very first resume after launch: the app has never been
      // backgrounded, so there is nothing stale — this must not mark it.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(signal.markStaleCalls, 0);

      // A brief background — an app-switcher flick, well under the
      // staleness threshold — must likewise not mark it.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      clock.now = clock.now.add(const Duration(seconds: 2));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(signal.markStaleCalls, 0);

      await tester.pumpWidget(const SizedBox());
    },
  );
}
