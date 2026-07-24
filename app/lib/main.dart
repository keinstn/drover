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
import 'src/firebase/app_check.dart';
import 'src/herdr/herdr_client.dart';
import 'src/herdr/host_platform.dart';
import 'src/infra/best_effort.dart';
import 'src/infra/host_store.dart';
import 'src/infra/ssh_command_runner.dart';
import 'src/models/agent_info.dart';
import 'src/models/host_config.dart';
import 'src/models/plugin_info.dart';
import 'src/notifications/notification_registration.dart';
import 'src/notifications/notification_target.dart';
import 'src/notifications/host_pairing.dart';
import 'src/notifications/plugin_auto_pairer.dart';
import 'src/screens/agent_draft_store.dart';
import 'src/screens/agent_screen.dart';
import 'src/screens/herd_screen.dart';
import 'src/screens/host_list_screen.dart';
import 'src/screens/host_setup_screen.dart';
import 'src/speech/speech_input.dart';
import 'src/utils/mutex.dart';
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
  runApp(
    DroverApp(
      hostStore: store,
      initialHosts: hostsState.hosts,
      initialActiveHostId: hostsState.activeHostId,
    ),
  );
}

class DroverApp extends StatefulWidget {
  const DroverApp({
    super.key,
    required this.hostStore,
    this.initialHosts = const [],
    this.initialActiveHostId,
    this.speechInput,
    this.notificationRegistration,
    this.hostPairingGateway,
  });

  final HostStore hostStore;
  final List<HostConfig> initialHosts;
  final String? initialActiveHostId;
  final SpeechInput? speechInput;
  final NotificationRegistration? notificationRegistration;
  final HostPairingGateway? hostPairingGateway;

  @override
  State<DroverApp> createState() => _DroverAppState();
}

class _DroverAppState extends State<DroverApp> {
  final _navKey = GlobalKey<NavigatorState>();
  List<HostConfig> _hosts = [];
  String? _activeHostId;
  SshCommandRunner? _runner;
  HerdrClient? _client;
  late final SpeechInput _speechInput;
  late final NotificationRegistration _notificationRegistration;
  late final HostPairingGateway _hostPairingGateway;
  StreamSubscription<Object>? _notificationFailures;
  StreamSubscription<RemoteMessage>? _notificationOpens;
  final _handledNotificationEvents = <String>{};

  /// Serializes every connection-changing section (activate, apply-config,
  /// delete): each persists and disposes across awaits before swapping
  /// `_runner`/`_client`, so two interleaved switches (e.g. a manual switch
  /// racing an FCM deep-link) could otherwise orphan a live runner.
  final _connectionMutex = Mutex();

  /// The host the app is connected to: the [_activeHostId] match, else the
  /// first stored host. Null when no hosts are configured.
  HostConfig? get _activeHost {
    for (final host in _hosts) {
      if (host.hostId != null && host.hostId == _activeHostId) return host;
    }
    return _hosts.isEmpty ? null : _hosts.first;
  }

  @override
  void initState() {
    super.initState();
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
    final active = _activeHost;
    // Normalize a stale/absent active id to the host actually connected to.
    _activeHostId = active?.hostId;
    if (active != null) {
      final (runner, client) = _buildConnection(active);
      _runner = runner;
      _client = client;
      _scheduleNotificationRegistration();
    }
  }

  /// Builds the SSH runner + herdr client pair for [host], binding the
  /// host-key pin callback to that host's id — the learned fingerprint must
  /// land on the host the runner was built for, even if another host has
  /// become active in the meantime.
  (SshCommandRunner, HerdrClient) _buildConnection(HostConfig host) {
    final hostId = host.hostId;
    final runner = SshCommandRunner(
      host,
      onHostKeyLearned: (fingerprint) => _pinHostKey(hostId, fingerprint),
    );
    final client = HerdrClient(
      runner,
      herdrBin: host.herdrBin,
      platform: HostPlatform.detect(runner),
    );
    return (runner, client);
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
    _runner?.dispose();
    super.dispose();
  }

  Future<void> _persistHosts() => widget.hostStore.saveHosts(
    HostsState(hosts: _hosts, activeHostId: _activeHostId),
  );

  Future<void> _applyConfig(HostConfig c) {
    return _connectionMutex.run(() async {
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
      // A brand-new host becomes active; editing the active host rebuilds its
      // connection in place (the settings may have changed). Editing a
      // non-active host only updates storage — it must not hijack the live
      // connection.
      final isNewHost = stored == null;
      final editsActive = !isNewHost && stored.hostId == _activeHost?.hostId;
      SshCommandRunner? runner;
      HerdrClient? client;
      if (isNewHost || editsActive) {
        await _runner?.dispose();
        (runner, client) = _buildConnection(config);
        if (isNewHost || replacedHost) {
          // Drafts are keyed by paneId; a different machine must not
          // inherit them.
          AgentDraftStore.shared.clearAll();
        }
      }
      final activeHostId = runner == null ? _activeHostId : config.hostId;
      await widget.hostStore.saveHosts(
        HostsState(hosts: hosts, activeHostId: activeHostId),
      );
      if (!mounted) return;
      setState(() {
        _hosts = hosts;
        _activeHostId = activeHostId;
        if (runner != null) {
          _runner = runner;
          _client = client;
        }
      });
      if (runner != null) _scheduleNotificationRegistration();
      _navKey.currentState?.popUntil((r) => r.isFirst);
    });
  }

  HostConfig _ensureHostId(HostConfig config) =>
      config.hostId == null ? config.withHostId(const Uuid().v4()) : config;

  bool _hostIdentityChanged(HostConfig previous, HostConfig next) =>
      previous.host != next.host ||
      previous.port != next.port ||
      previous.user != next.user;

  /// Makes [host] the active one: persists the selection, tears down the old
  /// connection, and connects to the new host. Drafts are keyed by paneId, so
  /// they are cleared to keep a same-numbered pane on the new host from
  /// inheriting them.
  Future<void> _activateHost(HostConfig host) =>
      _connectionMutex.run(() => _activateHostLocked(host));

  /// Body of [_activateHost]; callers must already hold [_connectionMutex].
  Future<void> _activateHostLocked(HostConfig host) async {
    _activeHostId = host.hostId;
    // Best-effort: a failed save must not block the in-memory switch; the
    // next successful save reconciles storage.
    await runBestEffort(_persistHosts, context: 'persist active host');
    await _runner?.dispose();
    final (runner, client) = _buildConnection(host);
    AgentDraftStore.shared.clearAll();
    _scheduleNotificationRegistration();
    if (!mounted) return;
    setState(() {
      _runner = runner;
      _client = client;
    });
  }

  Future<void> _switchHost(HostConfig host) async {
    if (host.hostId == null || host.hostId != _activeHost?.hostId) {
      await _activateHost(host);
      if (!mounted) return;
    }
    _navKey.currentState?.popUntil((r) => r.isFirst);
  }

  Future<void> _deleteHost(HostConfig host) {
    return _connectionMutex.run(() async {
      if (host.hostId != null) {
        await runBestEffort(
          () => _hostPairingGateway.revokeHost(host.hostId!),
          context: 'revoke deleted host',
        );
      }
      final wasActive = _activeHost?.hostId == host.hostId;
      final hosts = [..._hosts]
        ..removeWhere((other) => other.hostId == host.hostId);
      setState(() => _hosts = hosts);
      if (!wasActive) {
        // The host list drops the tile itself; nothing to reconnect.
        await runBestEffort(_persistHosts, context: 'persist deleted host');
        return;
      }
      if (hosts.isNotEmpty) {
        // Fall over to the first remaining host and navigate home — the open
        // host list would otherwise keep showing a stale active marker.
        await _activateHostLocked(hosts.first);
        if (!mounted) return;
        _navKey.currentState?.popUntil((r) => r.isFirst);
        return;
      }
      _activeHostId = null;
      await runBestEffort(_persistHosts, context: 'persist deleted host');
      await _runner?.dispose();
      if (!mounted) return;
      setState(() {
        _runner = null;
        _client = null;
      });
      _navKey.currentState?.popUntil((r) => r.isFirst);
    });
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

  Future<void> _openNotificationTarget(NotificationTarget target) async {
    if (_activeHost?.hostId != target.hostId) {
      // The event came from another stored host: switch to it first, then
      // deep-link into the pane there.
      HostConfig? stored;
      for (final host in _hosts) {
        if (host.hostId == target.hostId) stored = host;
      }
      if (stored == null) {
        _showNotificationTargetUnavailable();
        return;
      }
      await _activateHost(stored);
      if (!mounted) return;
    }
    final client = _client;
    if (client == null) {
      _showNotificationTargetUnavailable();
      return;
    }

    final List<AgentInfo> agents;
    try {
      agents = await client.listAgents();
    } on HerdrException {
      _showNotificationTargetUnavailable();
      return;
    }
    if (_client != client || !mounted) return;

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
          client: client,
          paneId: agent.first.paneId,
          initialAgent: agent.first,
          initialAgents: agents,
          speechInput: _speechInput,
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
      activeHostId: _activeHostId,
      onSelect: (host) => unawaited(_switchHost(host)),
      onManageHosts: _openHostList,
    );
  }

  void _openHostList() {
    _navKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => HostListScreen(
          hosts: _hosts,
          activeHostId: _activeHostId,
          onSelect: _switchHost,
          onAdd: _openAddHost,
          onEdit: _openEditHost,
          onDelete: _deleteHost,
        ),
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    final activeHost = _activeHost;
    return MaterialApp(
      title: 'Drover',
      navigatorKey: _navKey,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: droverLightTheme,
      darkTheme: droverDarkTheme,
      themeMode: ThemeMode.system,
      home: activeHost == null
          ? HostSetupScreen(onSubmit: _applyConfig, onTest: _testConnection)
          : HerdScreen(
              // HerdScreen state (agent list, workspace labels, native-history
              // caches) is per-host: switching hosts must recreate the State
              // instead of leaving it bound to the old host's connection.
              key: ValueKey(activeHost.hostId),
              client: _client!,
              speechInput: _speechInput,
              hostName: activeHost.displayName,
              onOpenHostSwitcher: _openHostSwitcher,
              onOpenSettings: _openHostList,
            ),
    );
  }
}
