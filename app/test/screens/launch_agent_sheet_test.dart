import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:drover/src/screens/launch_agent_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCommandRunner implements CommandRunner {
  FakeCommandRunner(
    this._response, {
    Future<List<RemoteDirEntry>> Function(String path)? listDirectory,
    Future<String> Function(String path)? resolvePath,
  }) : _listDirectory = listDirectory ?? ((_) async => []),
       _resolvePath = resolvePath ?? ((path) async => path);

  final CommandResult Function(String command) _response;
  final Future<List<RemoteDirEntry>> Function(String path) _listDirectory;
  final Future<String> Function(String path) _resolvePath;
  final commands = <String>[];

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
    return _response(command);
  }

  @override
  Future<void> uploadFile(String remotePath, List<int> bytes) async {}

  @override
  Future<List<RemoteDirEntry>> listDirectory(String path) =>
      _listDirectory(path);

  @override
  Future<String> resolvePath(String path) => _resolvePath(path);

  @override
  Future<void> dispose() async {}
}

CommandResult ok(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');

CommandResult _response(String command) {
  if (command.contains('command -v')) {
    return ok('claude\n');
  }
  if (command.contains("'workspace' 'create'")) {
    return ok(
      '{"id":"1","result":{"workspace":'
      '{"workspace_id":"wZ","label":"proj"}}}',
    );
  }
  if (command.contains("'workspace' 'list'")) {
    return ok(
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"wA","label":"Project A"},'
      '{"workspace_id":"wB","label":"Project B"}]}}',
    );
  }
  if (command.contains("'agent' 'start'")) {
    return ok('{"id":"1","result":{"type":"agent_started"}}');
  }
  throw StateError('unexpected command: $command');
}

CommandResult _responseWithDuplicateWorkspaceLabels(String command) {
  if (command.contains("'workspace' 'list'")) {
    return ok(
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"wA","label":"Project"},'
      '{"workspace_id":"wB","label":"Project"}]}}',
    );
  }
  return _response(command);
}

/// Pushes [LaunchAgentSheet] as a route and captures its pop value.
class _Harness extends StatefulWidget {
  const _Harness({required this.client});

  final HerdrClient client;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool? poppedValue;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () async {
            poppedValue = await showModalBottomSheet<bool>(
              context: context,
              isScrollControlled: true,
              builder: (_) => LaunchAgentSheet(
                client: widget.client,
                existingCwds: const [],
              ),
            );
            setState(() {});
          },
          child: const Text('open'),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('shows the detected preset after loading', (tester) async {
    final runner = FakeCommandRunner(_response);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LaunchAgentSheet(client: client, existingCwds: const []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.byKey(const ValueKey('preset_claude')), findsOneWidget);
  });

  testWidgets(
    'new-workspace launch creates a workspace then starts the agent',
    (tester) async {
      final runner = FakeCommandRunner(_response);
      final client = HerdrClient(runner);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: _Harness(client: client),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('cwd_field')),
        '/tmp/proj',
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('launch_button')));
      await tester.pumpAndSettle();

      final createIndex = runner.commands.indexWhere(
        (c) => c.contains("'workspace' 'create'"),
      );
      final startIndex = runner.commands.indexWhere(
        (c) => c.contains("'agent' 'start'"),
      );
      expect(createIndex, greaterThanOrEqualTo(0));
      expect(startIndex, greaterThan(createIndex));
      expect(runner.commands[startIndex], contains("'--workspace'"));
      expect(runner.commands[startIndex], contains("'claude'"));

      final state = tester.state<_HarnessState>(find.byType(_Harness));
      expect(state.poppedValue, true);
    },
  );

  testWidgets('new workspace name defaults to the cwd segment', (tester) async {
    final runner = FakeCommandRunner(_response);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: _Harness(client: client),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('cwd_field')),
      '/tmp/proj',
    );
    await tester.pump();

    final nameField = tester.widget<TextField>(
      find.byKey(const ValueKey('agent_name_field')),
    );
    expect(nameField.controller!.text, 'claude-proj');
    final workspaceNameField = tester.widget<TextField>(
      find.byKey(const ValueKey('workspace_name_field')),
    );
    expect(workspaceNameField.controller!.text, 'proj');

    await tester.tap(find.byKey(const ValueKey('launch_button')));
    await tester.pumpAndSettle();

    final createCommand = runner.commands.firstWhere(
      (c) => c.contains("'workspace' 'create'"),
    );
    final startCommand = runner.commands.firstWhere(
      (c) => c.contains("'agent' 'start'"),
    );
    expect(createCommand, contains("'proj'"));
    expect(startCommand, contains("'claude-proj'"));
  });

  testWidgets('editing the workspace name does not change the agent name', (
    tester,
  ) async {
    final runner = FakeCommandRunner(_response);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: _Harness(client: client),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('cwd_field')),
      '/tmp/proj',
    );
    await tester.enterText(
      find.byKey(const ValueKey('workspace_name_field')),
      'Shared project',
    );
    await tester.tap(find.byKey(const ValueKey('launch_button')));
    await tester.pumpAndSettle();

    final createCommand = runner.commands.firstWhere(
      (c) => c.contains("'workspace' 'create'"),
    );
    final startCommand = runner.commands.firstWhere(
      (c) => c.contains("'agent' 'start'"),
    );
    expect(createCommand, contains("'Shared project'"));
    expect(startCommand, contains("'claude-proj'"));
  });

  testWidgets('editing the agent name overrides the default', (tester) async {
    final runner = FakeCommandRunner(_response);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: _Harness(client: client),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('cwd_field')),
      '/tmp/proj',
    );
    await tester.pump();

    await tester.enterText(
      find.byKey(const ValueKey('agent_name_field')),
      'myagent',
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('launch_button')));
    await tester.pumpAndSettle();

    final startCommand = runner.commands.firstWhere(
      (c) => c.contains("'agent' 'start'"),
    );
    expect(startCommand, contains("'myagent'"));
    expect(startCommand, isNot(contains("'claude-proj'")));
  });

  testWidgets('hides IDs for uniquely named existing workspaces', (
    tester,
  ) async {
    final runner = FakeCommandRunner(_response);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LaunchAgentSheet(client: client, existingCwds: const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ws_mode_existing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ws_dropdown')));
    await tester.pumpAndSettle();

    expect(find.text('Project A'), findsOneWidget);
    expect(find.text('Project B'), findsOneWidget);
    expect(find.text('Project A (wA)'), findsNothing);
    expect(find.text('Project B (wB)'), findsNothing);
  });

  testWidgets('shows IDs to distinguish duplicate workspace names', (
    tester,
  ) async {
    final runner = FakeCommandRunner(_responseWithDuplicateWorkspaceLabels);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LaunchAgentSheet(client: client, existingCwds: const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ws_mode_existing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ws_dropdown')));
    await tester.pumpAndSettle();

    expect(find.text('Project (wA)'), findsOneWidget);
    expect(find.text('Project (wB)'), findsOneWidget);
  });

  testWidgets('browsing and selecting a directory populates the cwd field', (
    tester,
  ) async {
    final runner = FakeCommandRunner(
      _response,
      resolvePath: (path) async => path == '.' ? '/home/dev' : path,
      listDirectory: (path) async {
        if (path == '/home/dev') {
          return [const RemoteDirEntry(name: 'proj', isDirectory: true)];
        }
        return [];
      },
    );
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LaunchAgentSheet(client: client, existingCwds: const []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('cwd_browse_button')));
    await tester.pumpAndSettle();

    expect(find.text('/home/dev'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dir_entry_proj')));
    await tester.pumpAndSettle();

    expect(find.text('/home/dev/proj'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dir_picker_select')));
    await tester.pumpAndSettle();

    final cwdField = tester.widget<TextField>(
      find.byKey(const ValueKey('cwd_field')),
    );
    expect(cwdField.controller!.text, '/home/dev/proj');
  });
}
