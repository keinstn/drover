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
import '../src/screens/agent_screen.dart';
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

/// Registry of named previews. Add a screen = add an entry here.
final _previews = <String, WidgetBuilder>{
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
