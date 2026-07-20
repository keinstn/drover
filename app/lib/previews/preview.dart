// Single entrypoint for stubbed-backend UI previews (no SSH host needed) so
// screens can be screenshotted/inspected on a simulator.
//
//   just preview            # a gallery listing every registered screen
//   just preview launch     # boot one screen directly (marionette-friendly)
//
// Scenarios are orthogonal, via `--dart-define`:
//
//   just preview agent --dart-define=SCENARIO=blocked
//
// To add a screen, register a `WidgetBuilder` in [_previews] below — no new
// entrypoint file and no new justfile recipe.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:marionette_flutter/marionette_flutter.dart';

import '../l10n/app_localizations.dart';
import '../src/app_theme.dart';
import '../src/dev/stub_herdr.dart';
import '../src/herdr/command_runner.dart';
import '../src/herdr/herdr_client.dart';
import '../src/models/host_config.dart';
import '../src/screens/agent_screen.dart';
import '../src/screens/herd_screen.dart';
import '../src/screens/host_setup_screen.dart';
import '../src/screens/launch_agent_sheet.dart';

const _scenario = String.fromEnvironment('SCENARIO', defaultValue: 'idle');

HerdrClient _client(CommandResult Function(String) responder) =>
    HerdrClient(StubCommandRunner(responder));

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
      '{"id":"1","result":{"workspace":{"workspace_id":"wZ","label":"x"}}}',
    );
  }
  if (command.contains("'agent' 'start'")) {
    return ok('{"id":"1","result":{"type":"agent_started"}}');
  }
  return ok('{"id":"1","result":{}}');
}

const _herdListEnvelope =
    '{"id":"1","result":{"agents":['
    '{"agent":"claude","agent_status":"idle","cwd":"/tmp/proj-a",'
    '"focused":false,"pane_id":"wA:p1","tab_id":"wA:t1",'
    '"workspace_id":"wA","name":"Agent One"},'
    '{"agent":"claude","agent_status":"blocked","cwd":"/tmp/proj-a",'
    '"focused":false,"pane_id":"wA:p2","tab_id":"wA:t1",'
    '"workspace_id":"wA","name":"Agent Two"},'
    '{"agent":"claude","agent_status":"working","cwd":"/tmp/proj-b",'
    '"focused":false,"pane_id":"wB:p1","tab_id":"wB:t1",'
    '"workspace_id":"wB","name":"Agent Three"}'
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
      '{"id":"1","result":{"agent":{"agent":"claude",'
      '"agent_status":"working","cwd":"/tmp/proj-b","focused":false,'
      '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
      '"name":"Agent Three"}}}',
    );
  }
  if (command.contains("'agent' 'read'")) {
    return ok(
      '{"id":"1","result":{"read":{"text":${jsonEncodeString(_herdAgentReadText)}}}}',
    );
  }
  return ok('{"id":"1","result":{}}');
}

/// Registry of named previews. Add a screen = add an entry here.
final _previews = <String, WidgetBuilder>{
  'herd': (_) => HerdScreen(
    client: _client(_herdResponder),
    onOpenSettings: () {},
    pollInterval: const Duration(hours: 1),
  ),
  'agent': (_) => AgentScreen(
    client: _client(
      _scenario == 'blocked' ? blockedPromptResponse : idleWithModeResponse,
    ),
    paneId: 'wB:p1',
    pollInterval: const Duration(hours: 1),
  ),
  'launch': (_) => Scaffold(
    body: LaunchAgentSheet(
      client: _client(_launchResponder),
      existingCwds: const ['/home/dev/proj'],
    ),
  ),
  'host-setup': (_) => HostSetupScreen(
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
  ),
};

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
      theme: droverTheme,
      home: target == 'gallery'
          ? _PreviewGallery(names: _previews.keys.toList())
          : (builder != null
                ? Builder(builder: builder)
                : _UnknownPreview(
                    target: target,
                    names: _previews.keys.toList(),
                  )),
    ),
  );
}

/// In-app list of every registered preview; tapping one pushes it.
class _PreviewGallery extends StatelessWidget {
  const _PreviewGallery({required this.names});

  final List<String> names;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Drover previews')),
      body: ListView(
        children: [
          for (final name in names)
            ListTile(
              key: ValueKey('preview_$name'),
              leading: const Icon(Icons.visibility),
              title: Text(name),
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: _previews[name]!)),
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
