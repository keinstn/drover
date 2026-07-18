import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:marionette_flutter/marionette_flutter.dart';

import 'l10n/app_localizations.dart';
import 'src/app_theme.dart';
import 'src/herdr/herdr_client.dart';
import 'src/infra/host_store.dart';
import 'src/infra/ssh_command_runner.dart';
import 'src/models/host_config.dart';
import 'src/screens/herd_screen.dart';
import 'src/screens/host_setup_screen.dart';
import 'src/speech/speech_input.dart';

Future<void> main() async {
  if (kDebugMode) {
    MarionetteBinding.ensureInitialized();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }
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
  });

  final HostStore hostStore;
  final HostConfig? initialConfig;
  final SpeechInput? speechInput;

  @override
  State<DroverApp> createState() => _DroverAppState();
}

class _DroverAppState extends State<DroverApp> {
  final _navKey = GlobalKey<NavigatorState>();
  HostConfig? _config;
  SshCommandRunner? _runner;
  HerdrClient? _client;
  late final SpeechInput _speechInput;

  @override
  void initState() {
    super.initState();
    _speechInput = widget.speechInput ?? SpeechInputController();
    _config = widget.initialConfig;
    if (_config != null) {
      _runner = SshCommandRunner(_config!);
      _client = HerdrClient(_runner!, herdrBin: _config!.herdrBin);
    }
  }

  @override
  void dispose() {
    _runner?.dispose();
    super.dispose();
  }

  Future<void> _applyConfig(HostConfig c) async {
    await _runner?.dispose();
    final runner = SshCommandRunner(c);
    final client = HerdrClient(runner, herdrBin: c.herdrBin);
    await widget.hostStore.save(c);
    if (!mounted) return;
    setState(() {
      _config = c;
      _runner = runner;
      _client = client;
    });
    _navKey.currentState?.popUntil((r) => r.isFirst);
  }

  Future<void> _resetConfig() async {
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
      theme: droverTheme,
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
                    ),
                  ),
                );
              },
            ),
    );
  }
}
