// Single entrypoint for stubbed-backend UI previews (no SSH host needed) so
// screens can be screenshotted/inspected on a simulator.
//
//   just preview            # a gallery listing every screen x scenario
//   just preview launch     # boot one screen directly (marionette-friendly)
//
// Scenarios are orthogonal, via `--dart-define`, for direct single-screen
// boot:
//
//   just preview agent --dart-define=SCENARIO=blocked
//
// The gallery lists every scenario registered in [_scenariosByPreview] as
// its own tappable entry, so browsing them doesn't require relaunching.
//
// To add a screen, register a builder in [_previews] below — no new
// entrypoint file and no new justfile recipe. If it varies by scenario, list
// the scenario names in [_scenariosByPreview] too.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:marionette_flutter/marionette_flutter.dart';

import '../l10n/app_localizations.dart';
import '../src/app_theme.dart';
import '../src/dev/stub_herdr.dart';
import '../src/herdr/command_runner.dart';
import '../src/herdr/herdr_client.dart';
import '../src/infra/ssh_command_runner.dart';
import '../src/models/host_config.dart';
import '../src/models/plugin_info.dart';
import '../src/notifications/host_pairing.dart';
import '../src/screens/agent_screen.dart';
import '../src/screens/herd_screen.dart';
import '../src/screens/host_setup_screen.dart';
import '../src/screens/launch_agent_sheet.dart';
import '../src/widgets/error_message_view.dart';

const _scenario = String.fromEnvironment('SCENARIO', defaultValue: 'idle');

typedef PreviewBuilder = Widget Function(BuildContext context, String scenario);

/// Scenario names each screen responds to. Screens omitted here don't vary
/// by scenario, so the gallery shows a single entry for them.
const _scenariosByPreview = <String, List<String>>{
  'agent': ['idle', 'blocked', 'native', 'askuser'],
  'host-setup': ['idle', 'plugin-detected', 'auto-pair-failure'],
  'errors': ['en', 'ja'],
};

HerdrClient _client(
  CommandResult Function(String) responder, {
  Map<String, String>? files,
}) => HerdrClient(StubCommandRunner(responder, files: files));

CommandResult _launchResponder(String command) {
  if (command.contains('command -v')) {
    return ok('claude\n');
  }
  if (command.contains("'workspace' 'list'")) {
    return ok(
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"wA","label":"drover"}]}}',
    );
  }
  if (command.contains("'workspace' 'create'")) {
    return ok(
      '{"id":"1","result":{"workspace":{"workspace_id":"wZ","label":"x"},'
      '"root_pane":{"pane_id":"wZ:p1"}}}',
    );
  }
  if (command.contains("'pane' 'list'")) {
    return ok('{"id":"1","result":{"panes":[{"pane_id":"wA:p1"}]}}');
  }
  if (command.contains("'pane' 'split'")) {
    return ok('{"id":"1","result":{"pane":{"pane_id":"wA:p2"}}}');
  }
  if (command.contains("'agent' 'start'")) {
    return ok('{"id":"1","result":{"type":"agent_started"}}');
  }
  return ok('{"id":"1","result":{}}');
}

// Two extra agents (besides the scenario's own wB:p1) with mixed types and
// statuses, so the bottom switcher bar is visible in the default agent preview.
const _barExtraAgents =
    '{"agent":"claude","agent_status":"blocked","cwd":"/tmp/proj-a",'
    '"focused":false,"pane_id":"wA:p1","tab_id":"wA:t1","workspace_id":"wA",'
    '"terminal_title_stripped":"データベース migration をレビュー"},'
    '{"agent":"codex","agent_status":"working","cwd":"/tmp/proj-c",'
    '"focused":false,"pane_id":"wC:p1","tab_id":"wC:t1","workspace_id":"wC",'
    '"terminal_title_stripped":"型エラーを修正"}';

/// The scenario's own pane (wB:p1) as a single `agent list` entry.
String _currentAgent(String status) =>
    '{"agent":"claude","agent_status":"$status","cwd":"/tmp/proj",'
    '"focused":false,"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
    '"terminal_title_stripped":"OAuth callback を実装"}';

/// Wraps [base] so `agent list` returns wB:p1 (at [status]) plus the two extra
/// agents — making the switcher bar visible — while every other command
/// delegates to [base].
CommandResult Function(String) _withSwitcherBar(
  CommandResult Function(String) base,
  String status,
) => (command) {
  if (command.contains("'agent' 'list'")) {
    return ok(
      '{"id":"1","result":{"agents":['
      '${_currentAgent(status)},$_barExtraAgents]}}',
    );
  }
  return base(command);
};

const _herdListEnvelope =
    '{"id":"1","result":{"agents":['
    '{"agent":"claude","agent_status":"idle","cwd":"/tmp/proj-a",'
    '"focused":false,"pane_id":"wA:p1","tab_id":"wA:t1",'
    '"workspace_id":"wA","terminal_title_stripped":"OAuth callback を実装"},'
    '{"agent":"claude","agent_status":"blocked","cwd":"/tmp/proj-a",'
    '"focused":false,"pane_id":"wA:p2","tab_id":"wA:t1",'
    '"workspace_id":"wA",'
    '"terminal_title_stripped":"データベース migration をレビュー"},'
    '{"agent":"copilot","agent_status":"working","cwd":"/tmp/proj-b",'
    '"focused":false,"pane_id":"wB:p1","tab_id":"wB:t1",'
    '"workspace_id":"wB",'
    '"terminal_title_stripped":"Herd の session 表示を設計 - GitHub Copilot"}'
    ']}}';

const _herdAgentReadText =
    'Working on the task...\n'
    '-- INSERT -- auto mode on\n';

CommandResult _herdResponder(String command) {
  if (command.contains("'workspace' 'list'")) {
    return ok(
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"wA","label":"Project A"},'
      '{"workspace_id":"wB","label":"Project B"}'
      ']}}',
    );
  }
  if (command.contains("'agent' 'list'")) return ok(_herdListEnvelope);
  if (command.contains("'workspace' 'rename'") ||
      command.contains("'agent' 'rename'")) {
    return ok('{"id":"1","result":{"type":"ok"}}');
  }
  if (command.contains("'pane' 'close'")) {
    return ok('{"id":"1","result":{"type":"ok"}}');
  }
  if (command.contains("'agent' 'get'")) {
    return ok(
      '{"id":"1","result":{"agent":{"agent":"copilot",'
      '"agent_status":"working","cwd":"/tmp/proj-b","focused":false,'
      '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
      '"terminal_title_stripped":"Herd の session 表示を設計 - GitHub Copilot"}}}',
    );
  }
  if (command.contains("'agent' 'read'")) {
    return ok(_herdAgentReadText);
  }
  return ok('{"id":"1","result":{}}');
}

/// Registry of named previews. Add a screen = add an entry here.
final _previews = <String, PreviewBuilder>{
  'herd': (_, _) => HerdScreen(
    client: _client(_herdResponder),
    onOpenSettings: () {},
    pollInterval: const Duration(hours: 1),
  ),
  'agent': (_, scenario) => switch (scenario) {
    'native' => AgentScreen(
      client: _client(
        nativeHistoryResponse,
        files: {nativeTranscriptPath: nativeTranscriptJsonl},
      ),
      paneId: 'wB:p1',
      pollInterval: const Duration(hours: 1),
    ),
    'askuser' => AgentScreen(
      client: _client(
        nativeHistoryResponse,
        files: {nativeTranscriptPath: askUserTranscriptJsonl},
      ),
      paneId: 'wB:p1',
      pollInterval: const Duration(hours: 1),
    ),
    _ => AgentScreen(
      client: _client(
        scenario == 'blocked'
            ? _withSwitcherBar(blockedPromptResponse, 'blocked')
            : _withSwitcherBar(idleWithModeResponse, 'idle'),
      ),
      paneId: 'wB:p1',
      pollInterval: const Duration(hours: 1),
    ),
  },
  'launch': (_, _) => Scaffold(
    body: LaunchAgentSheet(
      client: _client(_launchResponder),
      existingCwds: const ['/home/dev/proj'],
    ),
  ),
  // Notification pairing: SCENARIO=idle (default) shows the manual dialog,
  // as if drover.notify were not linked on the host. SCENARIO=plugin-detected
  // shows the auto-pair confirmation → success path. SCENARIO=auto-pair-failure
  // confirms auto-pairing but has it fail, falling back to the manual dialog.
  'host-setup': (_, scenario) => HostSetupScreen(
    initial: const HostConfig(
      host: 'devbox.local',
      port: 22,
      user: 'dev',
      privateKeyPem:
          '-----BEGIN OPENSSH PRIVATE KEY-----\n'
          'stub-preview-key\n'
          '-----END OPENSSH PRIVATE KEY-----',
    ),
    onSubmit: (_) async {},
    onTest: (_) async => 'SSH connection succeeded (stubbed preview)',
    onCreatePairingCode: (_) async => const PairingCode(
      code: 'STUB-CODE-42',
      hostId: 'stub-host-id',
      completionUrl: 'https://drover.example/completePairing/stub',
    ),
    onDetectPlugin: (_) async =>
        scenario == 'plugin-detected' || scenario == 'auto-pair-failure'
        ? const PluginInfo(
            pluginId: 'drover.notify',
            enabled: true,
            pluginRoot: '/home/dev/drover/plugins/drover-notify',
          )
        : null,
    onAutoPair: (config, plugin, pairing) async {
      if (scenario == 'auto-pair-failure') {
        throw Exception('node was not found on the host PATH (stubbed).');
      }
    },
  ),
  // Every ErrorMessageView kind side by side, so the localized headlines and
  // the collapsible details can be eyeballed. SCENARIO=ja renders the whole
  // list under the Japanese locale via a Localizations override.
  'errors': (context, scenario) => Localizations.override(
    context: context,
    locale: scenario == 'ja' ? const Locale('ja') : const Locale('en'),
    child: Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(title: const Text('Error states')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final (label, error) in _errorSamples) ...[
              Text(label, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              ErrorMessageView(error),
              const Divider(height: 32),
            ],
          ],
        ),
      ),
    ),
  ),
};

/// One representative error per [errorHeadline] branch, in the two forms the
/// UI actually sees: bare (direct SFTP calls) and wrapped in a HerdrException
/// (herdr commands, which carry the transport error as `cause`).
final _errorSamples = <(String, Object)>[
  (
    'host-key mismatch (wrapped)',
    HerdrException(
      'transport',
      'wrapped',
      cause: SshHostKeyMismatchException(
        expected: 'SHA256:trusted-key-from-first-connect',
        observed: 'SHA256:different-key-presented-now',
      ),
    ),
  ),
  ('ssh auth (bare)', SshAuthException('Permission denied (publickey).')),
  (
    'host connection (wrapped socket error)',
    HerdrException(
      'transport',
      'sock',
      cause: Exception('SSHSocketError: Connection refused'),
    ),
  ),
  (
    'unknown (herdr command failed, no cause)',
    const HerdrException('command_failed', "workspace 'ws-9' not found"),
  ),
];

void main() {
  if (kDebugMode) {
    MarionetteBinding.ensureInitialized();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }

  const target = String.fromEnvironment('PREVIEW', defaultValue: 'gallery');
  final builder = _previews[target];

  runApp(
    MaterialApp(
      title: 'Drover preview',
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: droverLightTheme,
      darkTheme: droverDarkTheme,
      themeMode: ThemeMode.system,
      home: target == 'gallery'
          ? _PreviewGallery(previews: _previews, scenarios: _scenariosByPreview)
          : (builder != null
                ? Builder(builder: (ctx) => builder(ctx, _scenario))
                : _UnknownPreview(
                    target: target,
                    names: _previews.keys.toList(),
                  )),
    ),
  );
}

/// In-app list of every registered preview x scenario; tapping one pushes it.
class _PreviewGallery extends StatelessWidget {
  const _PreviewGallery({required this.previews, required this.scenarios});

  final Map<String, PreviewBuilder> previews;
  final Map<String, List<String>> scenarios;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Drover previews')),
      body: ListView(
        children: [
          for (final name in previews.keys)
            for (final scenario in scenarios[name] ?? const ['none'])
              ListTile(
                key: ValueKey('preview_${name}_$scenario'),
                leading: const Icon(Icons.visibility),
                title: Text(
                  scenarios.containsKey(name) ? '$name ($scenario)' : name,
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (ctx) => previews[name]!(ctx, scenario),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _UnknownPreview extends StatelessWidget {
  const _UnknownPreview({required this.target, required this.names});

  final String target;
  final List<String> names;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Text(
          'Unknown preview "$target".\nAvailable: ${names.join(', ')}',
        ),
      ),
    );
  }
}
