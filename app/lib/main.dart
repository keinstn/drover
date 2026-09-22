import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:marionette_flutter/marionette_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import 'l10n/app_localizations.dart';
import 'src/app_theme.dart';
import 'src/demo/demo_backend.dart';
import 'src/demo/demo_content.dart';
import 'src/demo/demo_screen.dart';
import 'src/firebase/app_check.dart';
import 'src/firebase/apple_account.dart';
import 'src/firebase/voice_wallet.dart';
import 'src/herdr/herdr_client.dart';
import 'src/herdr/host_platform.dart';
import 'src/infra/best_effort.dart';
import 'src/infra/host_connections.dart';
import 'src/infra/host_store.dart';
import 'src/infra/network_change_signal.dart';
import 'src/infra/settings_store.dart';
import 'src/infra/ssh_command_runner.dart';
import 'src/infra/stale_transport_signal.dart';
import 'src/models/agent_info.dart';
import 'src/models/host_config.dart';
import 'src/models/plugin_info.dart';
import 'src/notifications/notification_registration.dart';
import 'src/notifications/notification_target.dart';
import 'src/notifications/host_pairing.dart';
import 'src/notifications/notify_plugin_version.dart';
import 'src/notifications/plugin_auto_pairer.dart';
import 'src/screens/agent_screen.dart';
import 'src/screens/herd_screen.dart';
import 'src/screens/host_list_screen.dart';
import 'src/screens/host_setup_screen.dart';
import 'src/screens/settings_screen.dart';
import 'src/speech/speech_input.dart';
import 'src/widgets/host_switcher_sheet.dart';
import 'src/widgets/top_toast.dart';

Future<void> main() async {
  if (kDebugMode) {
    MarionetteBinding.ensureInitialized();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }
  // Read inside the bootstrap below and passed down, rather than read from
  // the widget tree: touching FirebaseAuth there would make the whole app
  // need Firebase initialized to build.
  var appleSignedIn = false;
  await runBestEffort(() async {
    await Firebase.initializeApp();
    final appleProvider = appleAppCheckProvider(
      platform: defaultTargetPlatform,
      isDebug: kDebugMode,
    );
    if (appleProvider != null) {
      await FirebaseAppCheck.instance.activate(providerApple: appleProvider);
      await FirebaseAppCheck.instance.setTokenAutoRefreshEnabled(true);
    }
    if (FirebaseAuth.instance.currentUser == null) {
      await FirebaseAuth.instance.signInAnonymously();
    }
    appleSignedIn =
        FirebaseAuth.instance.currentUser?.providerData.any(
          (provider) => provider.providerId == AppleAuthProvider.PROVIDER_ID,
        ) ??
        false;
  }, context: 'firebase bootstrap');
  final store = HostStore();
  var hostsState = const HostsState(hosts: []);
  try {
    hostsState = await store.loadHosts();
  } catch (_) {
    // Unreadable storage falls back to first-run setup.
  }
  final settingsStore = SettingsStore();
  var settings = const AppSettings();
  try {
    settings = await settingsStore.load();
  } catch (_) {
    // Unreadable prefs fall back to the defaults (system theme, device
    // locale) rather than blocking startup.
  }
  // Read from the bundle, never baked from pubspec: Xcode Cloud assigns the
  // shipped build number from its own counter, so a pubspec-derived string
  // can name a build the user doesn't actually have.
  String? appVersion;
  try {
    final info = await PackageInfo.fromPlatform();
    // The emptiness checks are not redundant with the catch: the plugin
    // coerces a missing Info.plist key to '' rather than throwing (see
    // package_info_plus_platform_interface's method_channel_package_info),
    // so a build without CFBundleShortVersionString would otherwise render
    // a blank " (66)" in the row the support pages tell people to copy.
    if (info.version.isNotEmpty) {
      appVersion = info.buildNumber.isEmpty
          ? info.version
          : '${info.version} (${info.buildNumber})';
    }
  } catch (_) {
    // Version is only used for a support row; failing to read it must not
    // block startup, and the row hides itself when it is null.
  }
  runApp(
    DroverApp(
      hostStore: store,
      settingsStore: settingsStore,
      initialHosts: hostsState.hosts,
      initialActiveHostId: hostsState.activeHostId,
      initialSettings: settings,
      appVersion: appVersion,
      initialAppleSignedIn: appleSignedIn,
    ),
  );
}

class DroverApp extends StatefulWidget {
  const DroverApp({
    super.key,
    required this.hostStore,
    required this.settingsStore,
    this.initialHosts = const [],
    this.initialActiveHostId,
    this.initialSettings = const AppSettings(),
    this.speechInput,
    this.notificationRegistration,
    this.hostPairingGateway,
    this.staleTransportSignal,
    this.hostConnectionRegistry,
    this.appVersion,
    this.clock,
    this.initialAppleSignedIn = false,
  });

  final HostStore hostStore;
  final SettingsStore settingsStore;
  final List<HostConfig> initialHosts;
  final String? initialActiveHostId;
  final AppSettings initialSettings;
  final SpeechInput? speechInput;
  final NotificationRegistration? notificationRegistration;
  final HostPairingGateway? hostPairingGateway;

  /// Injected at the [StaleTransportSignal] level (not the underlying
  /// [NetworkChangeSignal]) so tests can hold the exact instance
  /// `_DroverAppState` calls `markStale()` on and observe its `changes`
  /// stream directly, without needing a configured host or a live connection
  /// registry to make the effect visible.
  final StaleTransportSignal? staleTransportSignal;

  /// Injected so a test can hold the exact instance `_DroverAppState` calls
  /// `invalidateAll()` on (via [_staleTransportSignal]'s subscription) and
  /// count those calls directly, without needing a real SSH connection.
  final HostConnectionRegistry? hostConnectionRegistry;

  /// `"<marketing version> (<build number>)"` read from the bundle in
  /// [main]; null when the lookup failed, which hides the settings row.
  final String? appVersion;

  /// Wall clock used to measure how long the app was backgrounded (see
  /// [_DroverAppState.didChangeAppLifecycleState]). Injectable so a test can
  /// control the elapsed duration without sleeping the threshold out on the
  /// real clock; production always uses [DateTime.now].
  final DateTime Function()? clock;

  /// Whether an Apple ID was already linked to the Firebase account when
  /// [main] read it at startup. Passed in rather than read here so the app
  /// still builds without Firebase (tests do exactly that).
  final bool initialAppleSignedIn;

  @override
  State<DroverApp> createState() => _DroverAppState();
}

class _DroverAppState extends State<DroverApp> with WidgetsBindingObserver {
  final _navKey = GlobalKey<NavigatorState>();
  List<HostConfig> _hosts = [];

  /// Non-null while the scripted demo session is showing. Built lazily on
  /// entry (not in [build]) so a rebuild triggered by something else — e.g.
  /// the theme changing — doesn't reset the transcript mid-session.
  DemoBackend? _demo;

  /// The herd screen's host filter: a stored host's id, or null for "All
  /// hosts". Persisted as [HostsState.activeHostId] — existing users simply
  /// start filtered to their previously active host.
  String? _activeHostId;

  ThemeMode _themeMode = ThemeMode.system;

  /// null = follow the device locale (see [build] for how that resolves).
  Locale? _locale;
  bool _voiceAssistantEnabled = false;

  /// Flipped once the Apple link succeeds; never back — there is no
  /// sign-out, because a balance signed out of is stranded.
  bool _appleSignedIn = false;

  /// The voice-credit balance, as last read from the server. Owned here
  /// because this is where the Firebase guard and the wallet call already
  /// live, and shared: the voice screen's chip and its receipt both read
  /// this one notifier, so they can never quote different numbers. Null
  /// means nobody has managed to read it — a build without Firebase behind
  /// it, the demo, or a fetch that failed — and everything that renders it
  /// renders nothing instead of a guess.
  final _voiceCredits = ValueNotifier<int?>(null);

  /// Whether this device has already said its owner would pay to keep using
  /// voice. Seeded from [AppSettings] in `initState` and persisted on the
  /// tap: the server counts the taps and keeps no uid, so the device is the
  /// only thing that can remember having sent one.
  final _voicePaidInterest = ValueNotifier(false);

  /// Per-device push opt-ins, mirrored to the backend on every change.
  bool _notifyOnBlocked = true;
  bool _notifyOnDone = true;

  /// One lazily built connection per host; HerdScreen resolves clients from
  /// it via [HerdScreen.clientFor], so no connection is opened for a host
  /// until something actually talks to it.
  late final HostConnectionRegistry _registry;

  /// Bumped whenever a host's connection is rebuilt (config edit), so
  /// HerdScreen drops per-host state bound to the evicted runner.
  final _hostRevisions = <String, int>{};

  late final SpeechInput _speechInput;
  late final NotificationRegistration _notificationRegistration;
  late final HostPairingGateway _hostPairingGateway;
  late final StaleTransportSignal _staleTransportSignal;
  late final DateTime Function() _now;
  StreamSubscription<Object>? _notificationFailures;
  StreamSubscription<RemoteMessage>? _notificationOpens;
  StreamSubscription<void>? _staleTransportSub;
  final _handledNotificationEvents = <String>{};

  /// When the app last left the foreground (set on [AppLifecycleState.paused]
  /// only — see [didChangeAppLifecycleState]); null until the first time that
  /// happens, and cleared again on every `resumed`.
  DateTime? _backgroundedAt;

  /// How long the app must have been backgrounded before a resume is treated
  /// as "the cached SSH transport might be stale" (see
  /// [didChangeAppLifecycleState]). A tuning knob, not a measured bound:
  /// there is no OS signal that says "your socket was actually torn down",
  /// so this is a heuristic guess at how long a real iOS suspension takes —
  /// short enough to catch one, long enough that an app-switcher flick or a
  /// Control Centre glance doesn't churn a reconnect.
  static const _backgroundStaleThreshold = Duration(seconds: 10);

  @override
  void initState() {
    super.initState();
    _registry =
        widget.hostConnectionRegistry ??
        HostConnectionRegistry(_buildConnection);
    _now = widget.clock ?? DateTime.now;
    _speechInput = widget.speechInput ?? SpeechInputController();
    _notificationRegistration =
        widget.notificationRegistration ?? NotificationRegistration();
    // Read at registration time, so both the first registration and every
    // later re-registration carry whatever the switches say right then.
    _notificationRegistration.preferences = () =>
        (onBlocked: _notifyOnBlocked, onDone: _notifyOnDone);
    _hostPairingGateway =
        widget.hostPairingGateway ?? FirebaseHostPairingGateway();
    _staleTransportSignal =
        widget.staleTransportSignal ??
        StaleTransportSignal(ConnectivityChangeSignal());
    WidgetsBinding.instance.addObserver(this);
    _staleTransportSub = _staleTransportSignal.changes.listen(
      (_) => unawaited(
        runBestEffort(
          _registry.invalidateAll,
          context: 'invalidate connections on network change',
        ),
      ),
    );
    _notificationFailures = _notificationRegistration.failures.listen(
      (_) => _showNotificationRegistrationFailure(),
    );
    try {
      _notificationOpens = FirebaseMessaging.onMessageOpenedApp.listen(
        _handleNotificationOpen,
      );
      unawaited(_handleInitialNotification());
    } catch (_) {
      // Firebase Messaging is unavailable (e.g. Firebase failed to initialize);
      // the app still runs without notification deep-linking.
    }
    _hosts = [...widget.initialHosts];
    _activeHostId = widget.initialActiveHostId;
    _themeMode = widget.initialSettings.themeMode;
    _locale = widget.initialSettings.locale;
    _notifyOnBlocked = widget.initialSettings.notifyOnBlocked;
    _notifyOnDone = widget.initialSettings.notifyOnDone;
    _voiceAssistantEnabled = widget.initialSettings.voiceAssistantEnabled;
    _voicePaidInterest.value = widget.initialSettings.voicePaidInterest;
    _appleSignedIn = widget.initialAppleSignedIn;
    // Read at launch, but only for someone who has the assistant on: the
    // voice screen's chip is the first thing that quotes this number, and a
    // chip that appears a second after the screen does reads as a change to
    // the balance rather than as it arriving.
    if (_voiceAssistantEnabled) _refreshVoiceCredits();
    if (_hosts.isNotEmpty) {
      _scheduleNotificationRegistration();
    }
  }

  /// Builds one host's connection for the registry, binding the host-key pin
  /// callback to that host's id — the learned fingerprint must land on the
  /// host the runner was built for, whichever hosts are on screen later.
  HostConnection _buildConnection(HostConfig host) {
    final hostId = host.hostId;
    final runner = SshCommandRunner(
      host,
      onHostKeyLearned: (fingerprint) => _pinHostKey(hostId, fingerprint),
    );
    return HostConnection(
      config: host,
      runner: runner,
      client: HerdrClient(
        runner,
        herdrBin: host.herdrBin,
        platform: () => HostPlatform.detect(runner),
      ),
    );
  }

  Future<void> _pinHostKey(String? hostId, String fingerprint) async {
    if (hostId == null) return;
    final index = _hosts.indexWhere((host) => host.hostId == hostId);
    if (index < 0 || _hosts[index].hostKeyFingerprint != null) return;
    final hosts = [..._hosts];
    hosts[index] = hosts[index].withHostKeyFingerprint(fingerprint);
    await runBestEffort(
      () => widget.hostStore.saveHosts(
        HostsState(hosts: hosts, activeHostId: _activeHostId),
      ),
      context: 'pin host key',
    );
    if (!mounted) return;
    setState(() => _hosts = hosts);
  }

  /// iOS tears down a suspended app's sockets, so the cached SSH client can
  /// be dead by the time the app is foregrounded again even though nothing
  /// about the network changed — this is the trigger that matches the
  /// user-reported "reopen the app, host shows disconnected" symptom. But
  /// iOS does NOT tear sockets down for a brief background (an app-switcher
  /// flick, Control Centre, a notification banner), and reconnecting pays a
  /// full SSH handshake including the **synchronous** `SSHKeyPair.fromPem`
  /// KDF on the UI isolate — for a passphrase-protected key that is a visible
  /// frame hitch (see `ssh_command_runner.dart`'s `_defaultAuthTimeout` doc
  /// comment). So only `paused` records when the app left the foreground
  /// (not `inactive`/`hidden`, which also fire on the way back IN — recording
  /// there would overwrite the real backgrounding time moments before
  /// `resumed` and make the elapsed check always ~0), and `resumed` only
  /// marks the transport stale if that background lasted at least
  /// [_backgroundStaleThreshold]. If the app has never been backgrounded (the
  /// first `resumed` after launch), [_backgroundedAt] is still null, so
  /// nothing is marked stale — there is nothing stale yet, and the cold-start
  /// connect must not be disturbed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _backgroundedAt = _now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    final backgroundedAt = _backgroundedAt;
    _backgroundedAt = null;
    if (backgroundedAt == null) return;
    if (_now().difference(backgroundedAt) >= _backgroundStaleThreshold) {
      _staleTransportSignal.markStale();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _staleTransportSub?.cancel();
    unawaited(_staleTransportSignal.dispose());
    _notificationOpens?.cancel();
    _notificationFailures?.cancel();
    _notificationRegistration.dispose();
    unawaited(_registry.disposeAll());
    _demo?.dispose();
    _voiceCredits.dispose();
    _voicePaidInterest.dispose();
    super.dispose();
  }

  /// Re-reads the wallet: publishes the balance to [_voiceCredits] and hands
  /// the whole thing back, which is what the settings screen's activity list
  /// needs. One call feeds both, so the two can never quote different
  /// numbers.
  ///
  /// Null when there is nothing to read — no Firebase behind this build, or
  /// the demo, which must not call out to anything. A *failed* read leaves
  /// the last known balance where it was rather than blanking it: a chip
  /// that vanishes mid-call reads as the balance changing.
  Future<VoiceWallet>? _refreshVoiceCredits() {
    if (_demo != null || Firebase.apps.isEmpty) return null;
    final wallet = fetchVoiceWallet();
    unawaited(
      wallet.then((value) {
        if (mounted) _voiceCredits.value = value.credits;
      }, onError: (Object _) {}),
    );
    return wallet;
  }

  /// Adds this device's tap to the count, then flips the card over to its
  /// thank-you and remembers it.
  ///
  /// Persisted only after the call succeeds: a device that failed to send its
  /// tap must still be able to send it, and the card is what offers that.
  Future<void> _recordVoicePaidInterest() async {
    await recordVoicePaidInterest();
    await widget.settingsStore.saveVoicePaidInterest();
    if (mounted) _voicePaidInterest.value = true;
  }

  /// Links the Apple ID. Shared by the settings row and the voice path —
  /// both are the same act, and two copies of it would drift.
  ///
  /// No scopes on either provider: the account needs the stable identifier
  /// only, and asking for a name or an email would make drover collect
  /// contact information it has no use for.
  Future<void> _signInWithApple() async {
    await linkAppleAccount(
      link: () => FirebaseAuth.instance.currentUser!.linkWithProvider(
        AppleAuthProvider(),
      ),
      signIn: () =>
          FirebaseAuth.instance.signInWithProvider(AppleAuthProvider()),
    );
    setState(() => _appleSignedIn = true);
    // The free credits are granted on a signed-in account's first wallet
    // read, so the balance the app is holding is stale by exactly the thing
    // the user just signed in for.
    _refreshVoiceCredits();
  }

  Future<void> _persistHosts() => widget.hostStore.saveHosts(
    HostsState(hosts: _hosts, activeHostId: _activeHostId),
  );

  /// [_activeHostId] validated against the stored hosts: a stale id (its
  /// host was deleted or replaced) falls back to null, i.e. "All hosts".
  String? get _filterHostId {
    for (final host in _hosts) {
      if (host.hostId != null && host.hostId == _activeHostId) {
        return _activeHostId;
      }
    }
    return null;
  }

  void _bumpRevision(String hostId) {
    _hostRevisions[hostId] = (_hostRevisions[hostId] ?? 0) + 1;
  }

  /// Sets the herd's host filter (null = All hosts), persists it
  /// best-effort, and navigates home.
  void _setFilter(String? hostId) {
    setState(() => _activeHostId = hostId);
    unawaited(runBestEffort(_persistHosts, context: 'persist host filter'));
    _navKey.currentState?.popUntil((r) => r.isFirst);
  }

  Future<void> _applyConfig(HostConfig c) async {
    // Editing an existing host when the submitted hostId matches a stored
    // one; anything else is a brand-new host.
    final index = c.hostId == null
        ? -1
        : _hosts.indexWhere((host) => host.hostId == c.hostId);
    final stored = index < 0 ? null : _hosts[index];
    final replacedHost = stored != null && _hostIdentityChanged(stored, c);
    if (replacedHost && stored.hostId != null) {
      await runBestEffort(
        () => _hostPairingGateway.revokeHost(stored.hostId!),
        context: 'revoke replaced host',
      );
    }
    // The setup form never carries a host-key fingerprint, so preserve the
    // one already pinned when the host identity is unchanged (a benign edit
    // like the herdr path). A replaced host is a different machine, so its
    // stale pin must be dropped and re-learned on first connect.
    final config = _ensureHostId(
      replacedHost
          ? c.withHostId(null)
          : c.withHostKeyFingerprint(stored?.hostKeyFingerprint),
    );
    final hosts = [..._hosts];
    if (index < 0) {
      hosts.add(config);
    } else {
      hosts[index] = config;
    }
    final wasEmpty = _hosts.isEmpty;
    final connectionChanged = stored != null && !stored.sameConnection(config);
    var activeHostId = _activeHostId;
    if (stored == null) {
      // A brand-new host: clear the filter to All hosts so it is visible.
      activeHostId = null;
    } else {
      if (connectionChanged) {
        // The edit changed the connection, so bump the revision so
        // HerdScreen resets that host's bucket. A name-only edit keeps the
        // live connection and its bucket.
        _bumpRevision(config.hostId!);
      }
      if (replacedHost) {
        // The identity change re-minted the hostId; drop the dead id's
        // revision entry so it doesn't linger.
        _hostRevisions.remove(stored.hostId);
      }
      // Keep the filter following the host the user just edited.
      if (activeHostId == stored.hostId) activeHostId = config.hostId;
    }
    await widget.hostStore.saveHosts(
      HostsState(hosts: hosts, activeHostId: activeHostId),
    );
    if (!mounted) return;
    setState(() {
      _hosts = hosts;
      _activeHostId = activeHostId;
    });
    // Belt-and-braces teardown of the pre-edit connection, after the new
    // state is committed so a racing poll rebuilds from the new config
    // (correctness comes from the registry validating configs on obtain).
    // When the identity changed the hostId was re-minted, so the OLD id is
    // the one holding the stale connection.
    final staleHostId = stored?.hostId;
    if (connectionChanged && staleHostId != null) {
      unawaited(_registry.evict(staleHostId));
    }
    if (wasEmpty && hosts.isNotEmpty) _scheduleNotificationRegistration();
    _navKey.currentState?.popUntil((r) => r.isFirst);
  }

  HostConfig _ensureHostId(HostConfig config) =>
      config.hostId == null ? config.withHostId(const Uuid().v4()) : config;

  bool _hostIdentityChanged(HostConfig previous, HostConfig next) =>
      previous.host != next.host ||
      previous.port != next.port ||
      previous.user != next.user;

  Future<void> _deleteHost(HostConfig host) async {
    final hostId = host.hostId;
    if (hostId != null) {
      await runBestEffort(
        () => _hostPairingGateway.revokeHost(hostId),
        context: 'revoke deleted host',
      );
      _hostRevisions.remove(hostId);
    }
    final wasFiltered = hostId != null && hostId == _activeHostId;
    final hosts = [..._hosts]
      ..removeWhere((other) => other.hostId == host.hostId);
    setState(() {
      _hosts = hosts;
      if (wasFiltered) _activeHostId = null;
    });
    await runBestEffort(_persistHosts, context: 'persist deleted host');
    if (hostId != null) {
      // Evict last: with the host already gone from [_hosts], a poll tick
      // landing inside the evict window can no longer find it and resurrect
      // its connection.
      await _registry.evict(hostId);
    }
    if (!mounted) return;
    if (hosts.isEmpty || wasFiltered) {
      // Home flips to setup (empty) or the filter just changed under an open
      // host list — either way the stale route stack must go.
      _navKey.currentState?.popUntil((r) => r.isFirst);
    }
  }

  Future<PairingCode> _createPairingCode(HostConfig config) async {
    final pairedConfig = _ensureHostId(config);
    if (pairedConfig.hostId != config.hostId) {
      // The config predates hostIds; store the minted pairing key on the
      // host it came from.
      final hosts = [..._hosts];
      final index = hosts.indexWhere((host) => identical(host, config));
      if (index < 0) {
        hosts.add(pairedConfig);
      } else {
        hosts[index] = pairedConfig;
      }
      await widget.hostStore.saveHosts(
        HostsState(hosts: hosts, activeHostId: _activeHostId),
      );
      if (mounted) setState(() => _hosts = hosts);
    }
    return _hostPairingGateway.createPairingCode(pairedConfig.hostId!);
  }

  Future<PluginInfo?> _detectNotifyPlugin(HostConfig config) async {
    final runner = SshCommandRunner(config);
    try {
      final client = HerdrClient(
        runner,
        herdrBin: config.herdrBin,
        platform: () => HostPlatform.detect(runner),
      );
      return await PluginAutoPairer(client).detectPlugin();
    } finally {
      await runner.dispose();
    }
  }

  /// Per-host cap on how long Settings waits for the stale-plugin probe — it
  /// does not cancel it. The probe keeps running: a cold-path runner winds
  /// down on its own bounded waits (10s connect/auth, 15s per command), and
  /// a warm-path one is the registry's and stays, still serving the poll.
  static const _notifyProbeTimeout = Duration(seconds: 20);

  /// Probes every saved host for an out-of-date notification plugin, one
  /// future per host rather than a single `Future.wait`-combined one: the
  /// registry caches a connection object even when its socket is dead, so
  /// "cached" does not mean "fast" — an unreachable host must not hold back
  /// a row whose sibling already has its answer. Notifications arrive from
  /// all hosts, not just the one in view, so the active-host filter is
  /// deliberately not applied. Each probe is bounded and swallows its own
  /// failures: an unreachable host must not hang its row or hide a stale
  /// sibling.
  ///
  /// Reuses the registry's already-connected client when one is cached,
  /// rather than always building a fresh [SshCommandRunner]: this row is
  /// invisible until the probe returns, and paying a full connect + auth
  /// (up to 10s + 10s) on every Settings open makes it feel like it never
  /// loads, when the polling connection sitting right there could answer in
  /// one round trip. The shared runner serializes channels, so the probe
  /// queues behind an in-flight poll command rather than racing it — one
  /// short command, and still far cheaper than a second handshake.
  ///
  /// Accepted with it: a `plugin list` that wedges past the runner's 15s
  /// per-command bound now invalidates the connection the herd list polls
  /// on, blipping it through a reconnect. That is the same recovery any
  /// wedged command on that runner triggers, and a wedged connection is one
  /// worth dropping — a private connection would only hide it. Same for a
  /// cached entry whose socket has died (the network-switch path keeps the
  /// entry and drops only the client): the probe pays the reconnect inside
  /// the runner's mutex and the poll queues behind it, but that poll would
  /// have paid the very same reconnect on its next tick.
  ///
  /// `.toList()` is mandatory on the `.map(...)` below: a lazy `Iterable`
  /// would re-run each async body — a fresh SSH probe — every time Settings
  /// traverses the list, instead of returning the one future already
  /// in flight.
  List<Future<StaleNotifyPlugin?>> _checkNotifyPlugins() {
    return _hosts.where((host) => host.hostId != null).map((config) async {
      try {
        final cached = _registry.get(config.hostId!);
        final plugin =
            await (cached != null
                    ? PluginAutoPairer(cached.client).detectPlugin()
                    : _detectNotifyPlugin(config))
                .timeout(_notifyProbeTimeout);
        // Only a GitHub install is fixed by the reinstall commands the notice
        // renders; a linked checkout is updated with git, and an unknown kind
        // stays silent rather than suggesting the wrong thing.
        if (plugin?.sourceKind != 'github') return null;
        final version = plugin?.version;
        if (!isNotifyPluginStale(version)) return null;
        return StaleNotifyPlugin(
          hostName: config.displayName,
          installedVersion: version!,
          herdrBin: config.herdrBin,
        );
      } catch (_) {
        return null;
      }
    }).toList();
  }

  Future<void> _autoPairNotifications(
    HostConfig config,
    PluginInfo plugin,
    PairingCode pairing,
  ) async {
    final runner = SshCommandRunner(config);
    try {
      final client = HerdrClient(
        runner,
        herdrBin: config.herdrBin,
        platform: () => HostPlatform.detect(runner),
      );
      await PluginAutoPairer(client).pair(plugin: plugin, pairing: pairing);
    } finally {
      await runner.dispose();
    }
  }

  void _scheduleNotificationRegistration() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_registerNotifications());
    });
  }

  Future<void> _registerNotifications() async {
    try {
      await _notificationRegistration.initialize();
    } catch (_) {
      _showNotificationRegistrationFailure();
    }
  }

  void _showNotificationRegistrationFailure() {
    if (!mounted) return;
    final overlay = _navKey.currentState?.overlay;
    final context = _navKey.currentContext;
    if (overlay == null || context == null) return;
    showTopToastOnOverlay(
      overlay,
      AppLocalizations.of(context)!.notificationRegistrationFailed,
    );
  }

  Future<void> _handleInitialNotification() async {
    await runBestEffort(() async {
      final message = await FirebaseMessaging.instance.getInitialMessage();
      if (message != null) _handleNotificationOpen(message);
    }, context: 'initial notification');
  }

  void _handleNotificationOpen(RemoteMessage message) {
    final target = NotificationTarget.fromData(message.data);
    if (target == null) return;
    final eventId = target.eventId ?? message.messageId;
    if (eventId != null && !_handledNotificationEvents.add(eventId)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_openNotificationTarget(target));
    });
  }

  /// Deep-links a notification into its agent's screen using the stored
  /// host's own connection — the herd filter is left untouched, so the user
  /// lands back on whatever view they had.
  Future<void> _openNotificationTarget(NotificationTarget target) async {
    HostConfig? stored;
    for (final host in _hosts) {
      if (host.hostId == target.hostId) stored = host;
    }
    if (stored == null) {
      _showNotificationTargetUnavailable();
      return;
    }
    final client = _registry.obtain(stored).client;

    final List<AgentInfo> agents;
    try {
      agents = await client.listAgents();
    } on HerdrException {
      _showNotificationTargetUnavailable();
      return;
    }
    if (!mounted) return;
    // The host may have been deleted (or replaced) while listing; its
    // connection was evicted, so don't push a screen bound to it. It may
    // also have been benignly edited, which evicts the pre-await client —
    // re-obtain from the currently stored config so the pushed screen gets
    // a connection matching it.
    HostConfig? current;
    for (final host in _hosts) {
      if (host.hostId == target.hostId) current = host;
    }
    if (current == null) {
      _showNotificationTargetUnavailable();
      return;
    }
    final currentClient = _registry.obtain(current).client;

    final agent = agents.where((agent) => agent.paneId == target.paneId);
    if (agent.isEmpty) {
      _showNotificationTargetUnavailable();
      return;
    }

    final navigator = _navKey.currentState;
    if (navigator == null) return;
    navigator.popUntil((route) => route.isFirst);
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => AgentScreen(
          client: currentClient,
          paneId: agent.first.paneId,
          initialAgent: agent.first,
          initialAgents: agents,
          speechInput: _speechInput,
          draftKeyPrefix: target.hostId,
        ),
      ),
    );
  }

  void _showNotificationTargetUnavailable() {
    if (!mounted) return;
    final overlay = _navKey.currentState?.overlay;
    final context = _navKey.currentContext;
    if (overlay == null || context == null) return;
    showTopToastOnOverlay(
      overlay,
      AppLocalizations.of(context)!.notificationTargetUnavailable,
    );
  }

  Future<String> _testConnection(HostConfig c) async {
    final runner = SshCommandRunner(c);
    try {
      final client = HerdrClient(
        runner,
        herdrBin: c.herdrBin,
        platform: () => HostPlatform.detect(runner),
      );
      final agents = await client.listAgents();
      final l10n = AppLocalizations.of(_navKey.currentContext!)!;
      return l10n.testConnectionOk(agents.length);
    } finally {
      await runner.dispose();
    }
  }

  void _openHostSwitcher() {
    final context = _navKey.currentContext;
    if (context == null) return;
    showHostSwitcherSheet(
      context,
      hosts: _hosts,
      activeHostId: _filterHostId,
      includeAllHosts: true,
      onSelectAll: () => _setFilter(null),
      onSelect: (host) => _setFilter(host.hostId),
      onManageHosts: _openHostList,
    );
  }

  void _openHostList() {
    _navKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => HostListScreen(
          hosts: _hosts,
          activeHostId: _filterHostId,
          onSelect: (host) async => _setFilter(host.hostId),
          onAdd: _openAddHost,
          onEdit: _openEditHost,
          onDelete: _deleteHost,
        ),
      ),
    );
  }

  /// Enters the scripted demo. The session's content language is resolved
  /// once, here: [_locale] is null by default ("follow the device"), so the
  /// effective locale has to come from [Localizations], not from the field.
  /// See [DemoBackend] for why it is then fixed for the session.
  void _enterDemo() {
    final context = _navKey.currentContext;
    final locale = context == null ? null : Localizations.localeOf(context);
    setState(() => _demo = DemoBackend(content: demoContentFor(locale)));
    // Reachable from the settings screen too, which is a pushed route — the
    // demo replaces `home`, so anything stacked above it has to go.
    _navKey.currentState?.popUntil((route) => route.isFirst);
  }

  void _exitDemo() {
    final demo = _demo;
    setState(() => _demo = null);
    demo?.dispose();
  }

  void _openAddHost() {
    _navKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            HostSetupScreen(onSubmit: _applyConfig, onTest: _testConnection),
      ),
    );
  }

  void _openEditHost(HostConfig host) {
    _navKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => HostSetupScreen(
          initial: host,
          onSubmit: _applyConfig,
          onTest: _testConnection,
          onCreatePairingCode: _createPairingCode,
          onDetectPlugin: _detectNotifyPlugin,
          onAutoPair: _autoPairNotifications,
        ),
      ),
    );
  }

  void _openSettings() {
    // Started here, once: the StatefulBuilder below rebuilds on every
    // setting change, and a future created inside it would re-probe every
    // host over SSH each time. Skipped inside the demo, which keeps the
    // stored hosts around but must not reach out to them.
    final staleNotifyPlugins = _demo == null ? _checkNotifyPlugins() : null;
    // Started here for the same reason, and skipped in the demo for the same
    // one: the demo must not call out to anything. Also skipped when the
    // bootstrap above never got Firebase up — there is no wallet to read
    // then, and the screen hides the balance rather than reporting a failure
    // nobody can act on.
    // Not final: deleting the account from this very screen leaves the
    // balance below describing a uid that no longer exists, so that one
    // callback replaces the future and the route re-reads it.
    var voiceWallet = _refreshVoiceCredits();
    _navKey.currentState?.push(
      MaterialPageRoute<void>(
        // The StatefulBuilder is load-bearing, not noise: a pushed route
        // caches its page widget, so an app-level setState re-themes the app
        // but leaves this already-built SettingsScreen holding the OLD
        // themeMode/locale it was constructed with — its "current value" rows
        // would go stale. `rebuildRoute` forces the route to re-read the
        // fields below, which the callbacks have already mutated (hence its
        // empty closure body).
        builder: (_) => StatefulBuilder(
          builder: (_, rebuildRoute) => SettingsScreen(
            themeMode: _themeMode,
            locale: _locale,
            notifyOnBlocked: _notifyOnBlocked,
            notifyOnDone: _notifyOnDone,
            appVersion: widget.appVersion,
            staleNotifyPlugins: staleNotifyPlugins,
            hasHosts: _hosts.isNotEmpty,
            voiceWallet: voiceWallet,
            onThemeModeChanged: (mode) {
              setState(() => _themeMode = mode);
              rebuildRoute(() {});
              unawaited(
                runBestEffort(
                  () => widget.settingsStore.saveThemeMode(mode),
                  context: 'persist theme mode',
                ),
              );
            },
            onLocaleChanged: (locale) {
              setState(() => _locale = locale);
              rebuildRoute(() {});
              unawaited(
                runBestEffort(
                  () => widget.settingsStore.saveLocale(locale),
                  context: 'persist locale',
                ),
              );
            },
            onNotifyOnBlockedChanged: (value) {
              setState(() => _notifyOnBlocked = value);
              rebuildRoute(() {});
              _persistNotifyPreferences();
            },
            onNotifyOnDoneChanged: (value) {
              setState(() => _notifyOnDone = value);
              rebuildRoute(() {});
              _persistNotifyPreferences();
            },
            voiceAssistantEnabled: _voiceAssistantEnabled,
            onVoiceAssistantChanged: (enabled) {
              setState(() => _voiceAssistantEnabled = enabled);
              rebuildRoute(() {});
              unawaited(
                runBestEffort(() async {
                  await widget.settingsStore.saveVoiceAssistantEnabled(enabled);
                  // Off is the revoke: clearing the accepted version makes
                  // turning it back on ask again before anything is sent.
                  if (!enabled) {
                    await widget.settingsStore.saveVoiceConsentVersion(0);
                  }
                }, context: 'persist voice assistant'),
              );
            },
            appleSignedIn: _appleSignedIn,
            onSignInWithApple: () async {
              await _signInWithApple();
              rebuildRoute(() {});
            },
            onDeleteAccount: () async {
              await deleteAccount(
                appleLinked: _appleSignedIn,
                reauthenticate: () async {
                  final credential = await FirebaseAuth.instance.currentUser!
                      .reauthenticateWithProvider(AppleAuthProvider());
                  return credential.additionalUserInfo?.authorizationCode;
                },
                revoke: (code) => FirebaseAuth.instance
                    .revokeTokenWithAuthorizationCode(code),
                // No arguments: the function reads the uid from the auth
                // context, which is the only account it may ever delete.
                delete: () => FirebaseFunctions.instanceFor(
                  region: 'us-central1',
                ).httpsCallable('deleteAccount').call<void>(),
                // Signed out first, and that is not a formality:
                // `signInAnonymously` hands back the *existing* anonymous
                // user when there is one, and the client has no idea its
                // account was just deleted server side. Without the sign-out
                // an anonymous account would carry on under the uid it
                // asked to be rid of, and re-create rows beneath it.
                startOver: () async {
                  await FirebaseAuth.instance.signOut();
                  await FirebaseAuth.instance.signInAnonymously();
                },
              );
              setState(() => _appleSignedIn = false);
              // The screen stays up, and everything it shows about the
              // wallet belonged to the account that just went. Re-read it
              // under the fresh uid — an empty balance and an empty ledger,
              // which is the truth and also the reassurance.
              rebuildRoute(() {
                // The deleted account's balance went with it; the fresh uid
                // starts at nothing, and the shared notifier has to say so
                // as well as this screen.
                _voiceCredits.value = null;
                // The paid-interest flag deliberately stays: it belongs to
                // this device, not to the account that just went, and the
                // count it already added cannot be taken back — nothing on
                // the server says which tap was this one's. Clearing it here
                // would only invite the same person to count themselves
                // twice.
                voiceWallet = _refreshVoiceCredits();
              });
              // The old uid's `users/{uid}/devices` documents went with the
              // account, so this device has to re-register under the fresh
              // one. Unawaited, and through the wrapper that reports its own
              // failure: the delete has already happened, and a push failure
              // surfacing as a failed delete would be a lie.
              unawaited(_pushNotifyPreferences());
            },
            onManageHosts: _openHostList,
            // Hidden while the demo is already showing — settings is reached
            // from inside it, so offering the demo again would be a no-op row.
            onEnterDemo: _demo == null ? _enterDemo : null,
          ),
        ),
      ),
    );
  }

  /// Stores the switches locally and mirrors them to the backend. The two
  /// are independent: a failed re-registration must not cost the user the
  /// local setting they just made. It is reported, though — a silent failure
  /// would leave the device still receiving what the switch says is off.
  void _persistNotifyPreferences() {
    unawaited(
      runBestEffort(
        () => widget.settingsStore.saveNotifyPreferences(
          onBlocked: _notifyOnBlocked,
          onDone: _notifyOnDone,
        ),
        context: 'persist notification preferences',
      ),
    );
    unawaited(_pushNotifyPreferences());
  }

  Future<void> _pushNotifyPreferences() async {
    try {
      await _notificationRegistration.refreshRegistration();
    } catch (_) {
      _showNotificationRegistrationFailure();
    }
  }

  HerdrClient _clientFor(HerdHostRef ref) {
    final host = _hosts.firstWhere((host) => host.hostId == ref.hostId);
    return _registry.obtain(host).client;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Drover',
      // No effect on release builds; keeps debug builds usable for App Store
      // screenshot capture, which needs the debug-only Marionette hookup.
      debugShowCheckedModeBanner: false,
      navigatorKey: _navKey,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // A null [_locale] is the intended default, not a gap: Flutter then
      // resolves against [supportedLocales], whose order (en, ja) means a
      // Japanese device gets ja and everything else falls back to en.
      locale: _locale,
      theme: droverLightTheme,
      darkTheme: droverDarkTheme,
      themeMode: _themeMode,
      home: _demo != null
          ? DemoScreen(
              backend: _demo!,
              hasConfiguredHost: _hosts.isNotEmpty,
              onExitDemo: _exitDemo,
              onOpenSettings: _openSettings,
              voiceAssistantEnabled: _voiceAssistantEnabled,
            )
          : _hosts.isEmpty
          ? HostSetupScreen(
              onSubmit: _applyConfig,
              onTest: _testConnection,
              onEnterDemo: _enterDemo,
            )
          : HerdScreen(
              // Deliberately NOT keyed by host: the screen holds one state
              // bucket per host and must survive filter and host-set changes.
              hosts: [
                for (final host in _hosts)
                  HerdHostRef(
                    hostId: host.hostId!,
                    displayName: host.displayName,
                    revision: _hostRevisions[host.hostId] ?? 0,
                    hostEverConnected: host.hostKeyFingerprint != null,
                  ),
              ],
              clientFor: _clientFor,
              filterHostId: _filterHostId,
              speechInput: _speechInput,
              onOpenHostSwitcher: _openHostSwitcher,
              onOpenSettings: _openSettings,
              networkChanges: _staleTransportSignal.changes,
              voiceAssistantEnabled: _voiceAssistantEnabled,
              voiceCredits: _voiceCredits,
              // Null once an Apple ID is attached: there is nothing left to
              // offer, and the sheet and the refusal card both key on it.
              onVoiceSignIn: _appleSignedIn ? null : _signInWithApple,
              voicePaidInterest: _voicePaidInterest,
              onVoicePaidInterest: _recordVoicePaidInterest,
              onVoiceCreditsStale: _refreshVoiceCredits,
            ),
    );
  }
}
