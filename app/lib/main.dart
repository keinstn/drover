import 'dart:async';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:marionette_flutter/marionette_flutter.dart';
import 'package:uuid/uuid.dart';

import 'l10n/app_localizations.dart';
import 'src/app_theme.dart';
import 'src/demo/demo_backend.dart';
import 'src/demo/demo_screen.dart';
import 'src/firebase/app_check.dart';
import 'src/herdr/herdr_client.dart';
import 'src/herdr/host_platform.dart';
import 'src/infra/best_effort.dart';
import 'src/infra/host_connections.dart';
import 'src/infra/host_store.dart';
import 'src/infra/settings_store.dart';
import 'src/infra/ssh_command_runner.dart';
import 'src/models/agent_info.dart';
import 'src/models/host_config.dart';
import 'src/models/plugin_info.dart';
import 'src/notifications/notification_registration.dart';
import 'src/notifications/notification_target.dart';
import 'src/notifications/host_pairing.dart';
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
  runApp(
    DroverApp(
      hostStore: store,
      settingsStore: settingsStore,
      initialHosts: hostsState.hosts,
      initialActiveHostId: hostsState.activeHostId,
      initialSettings: settings,
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
  });

  final HostStore hostStore;
  final SettingsStore settingsStore;
  final List<HostConfig> initialHosts;
  final String? initialActiveHostId;
  final AppSettings initialSettings;
  final SpeechInput? speechInput;
  final NotificationRegistration? notificationRegistration;
  final HostPairingGateway? hostPairingGateway;

  @override
  State<DroverApp> createState() => _DroverAppState();
}

class _DroverAppState extends State<DroverApp> {
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
  StreamSubscription<Object>? _notificationFailures;
  StreamSubscription<RemoteMessage>? _notificationOpens;
  final _handledNotificationEvents = <String>{};

  @override
  void initState() {
    super.initState();
    _registry = HostConnectionRegistry(_buildConnection);
    _speechInput = widget.speechInput ?? SpeechInputController();
    _notificationRegistration =
        widget.notificationRegistration ?? NotificationRegistration();
    _hostPairingGateway =
        widget.hostPairingGateway ?? FirebaseHostPairingGateway();
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
        platform: HostPlatform.detect(runner),
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

  @override
  void dispose() {
    _notificationOpens?.cancel();
    _notificationFailures?.cancel();
    _notificationRegistration.dispose();
    unawaited(_registry.disposeAll());
    _demo?.dispose();
    super.dispose();
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
        platform: HostPlatform.detect(runner),
      );
      return await PluginAutoPairer(client).detectPlugin();
    } finally {
      await runner.dispose();
    }
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
        platform: HostPlatform.detect(runner),
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
        platform: HostPlatform.detect(runner),
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

  void _enterDemo() {
    setState(() => _demo = DemoBackend());
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
            onManageHosts: _openHostList,
          ),
        ),
      ),
    );
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
            ),
    );
  }
}
