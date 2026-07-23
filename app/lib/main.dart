import 'dart:async';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:marionette_flutter/marionette_flutter.dart';
import 'package:uuid/uuid.dart';

import 'l10n/app_localizations.dart';
import 'src/app_theme.dart';
import 'src/firebase/app_check.dart';
import 'src/herdr/herdr_client.dart';
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
import 'src/screens/agent_screen.dart';
import 'src/screens/herd_screen.dart';
import 'src/screens/host_setup_screen.dart';
import 'src/speech/speech_input.dart';
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
  final store = HostStore(
    storage: const FlutterSecureStorage(
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    ),
  );
  HostConfig? config;
  try {
    config = await store.load();
  } catch (_) {
    config = null;
  }
  runApp(DroverApp(hostStore: store, initialConfig: config));
}

class DroverApp extends StatefulWidget {
  const DroverApp({
    super.key,
    required this.hostStore,
    this.initialConfig,
    this.speechInput,
    this.notificationRegistration,
    this.hostPairingGateway,
  });

  final HostStore hostStore;
  final HostConfig? initialConfig;
  final SpeechInput? speechInput;
  final NotificationRegistration? notificationRegistration;
  final HostPairingGateway? hostPairingGateway;

  @override
  State<DroverApp> createState() => _DroverAppState();
}

class _DroverAppState extends State<DroverApp> {
  final _navKey = GlobalKey<NavigatorState>();
  HostConfig? _config;
  SshCommandRunner? _runner;
  HerdrClient? _client;
  late final SpeechInput _speechInput;
  late final NotificationRegistration _notificationRegistration;
  late final HostPairingGateway _hostPairingGateway;
  StreamSubscription<Object>? _notificationFailures;
  StreamSubscription<RemoteMessage>? _notificationOpens;
  final _handledNotificationEvents = <String>{};

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
    _config = widget.initialConfig;
    if (_config != null) {
      _runner = SshCommandRunner(_config!);
      _client = HerdrClient(_runner!, herdrBin: _config!.herdrBin);
      _scheduleNotificationRegistration();
    }
  }

  @override
  void dispose() {
    _notificationOpens?.cancel();
    _notificationFailures?.cancel();
    _notificationRegistration.dispose();
    _runner?.dispose();
    super.dispose();
  }

  Future<void> _applyConfig(HostConfig c) async {
    final replacedHost = _config != null && _hostIdentityChanged(_config!, c);
    if (replacedHost && _config!.hostId != null) {
      await runBestEffort(
        () => _hostPairingGateway.revokeHost(_config!.hostId!),
        context: 'revoke replaced host',
      );
    }
    final config = _ensureHostId(replacedHost ? c.withHostId(null) : c);
    await _runner?.dispose();
    final runner = SshCommandRunner(config);
    final client = HerdrClient(runner, herdrBin: config.herdrBin);
    await widget.hostStore.save(config);
    if (!mounted) return;
    setState(() {
      _config = config;
      _runner = runner;
      _client = client;
    });
    _scheduleNotificationRegistration();
    _navKey.currentState?.popUntil((r) => r.isFirst);
  }

  HostConfig _ensureHostId(HostConfig config) =>
      config.hostId == null ? config.withHostId(const Uuid().v4()) : config;

  bool _hostIdentityChanged(HostConfig previous, HostConfig next) =>
      previous.host != next.host ||
      previous.port != next.port ||
      previous.user != next.user;

  Future<PairingCode> _createPairingCode(HostConfig config) async {
    final pairedConfig = _ensureHostId(config);
    if (pairedConfig.hostId != config.hostId) {
      await widget.hostStore.save(pairedConfig);
      if (mounted) setState(() => _config = pairedConfig);
    }
    return _hostPairingGateway.createPairingCode(pairedConfig.hostId!);
  }

  Future<PluginInfo?> _detectNotifyPlugin(HostConfig config) async {
    final runner = SshCommandRunner(config);
    try {
      final client = HerdrClient(runner, herdrBin: config.herdrBin);
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
      final client = HerdrClient(runner, herdrBin: config.herdrBin);
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
    final client = _client;
    if (client == null || _config?.hostId != target.hostId) {
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

  Future<void> _resetConfig() async {
    final hostId = _config?.hostId;
    if (hostId != null) {
      await runBestEffort(
        () => _hostPairingGateway.revokeHost(hostId),
        context: 'revoke host on reset',
      );
    }
    await widget.hostStore.clear();
    await _runner?.dispose();
    if (!mounted) return;
    setState(() {
      _config = null;
      _runner = null;
      _client = null;
    });
    _navKey.currentState?.popUntil((r) => r.isFirst);
  }

  Future<String> _testConnection(HostConfig c) async {
    final runner = SshCommandRunner(c);
    try {
      final client = HerdrClient(runner, herdrBin: c.herdrBin);
      final agents = await client.listAgents();
      final l10n = AppLocalizations.of(_navKey.currentContext!)!;
      return l10n.testConnectionOk(agents.length);
    } finally {
      await runner.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Drover',
      navigatorKey: _navKey,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: droverLightTheme,
      darkTheme: droverDarkTheme,
      themeMode: ThemeMode.system,
      home: _config == null
          ? HostSetupScreen(onSubmit: _applyConfig, onTest: _testConnection)
          : HerdScreen(
              client: _client!,
              speechInput: _speechInput,
              onOpenSettings: () {
                _navKey.currentState?.push(
                  MaterialPageRoute<void>(
                    builder: (_) => HostSetupScreen(
                      initial: _config,
                      onSubmit: _applyConfig,
                      onTest: _testConnection,
                      onReset: _resetConfig,
                      onCreatePairingCode: _createPairingCode,
                      onDetectPlugin: _detectNotifyPlugin,
                      onAutoPair: _autoPairNotifications,
                    ),
                  ),
                );
              },
            ),
    );
  }
}
