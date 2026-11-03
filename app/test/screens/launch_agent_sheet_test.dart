import 'dart:async';

import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/herdr/combined_client.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/hc_client.dart';
import 'package:drover/src/herdr/herdr_backend.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/models/agent_preset.dart';
import 'package:drover/src/models/workspace_info.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:drover/src/screens/launch_agent_sheet.dart';
import 'package:drover/src/widgets/agent_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCommandRunner extends CommandRunner {
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
      '{"workspace_id":"wZ","label":"proj"},'
      '"root_pane":{"pane_id":"wZ:p1"}}}',
    );
  }
  if (command.contains("'workspace' 'list'")) {
    return ok(
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"wA","label":"Project A"},'
      '{"workspace_id":"wB","label":"Project B"}]}}',
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
  throw StateError('unexpected command: $command');
}

/// Answers the first `claude-proj` start with herdr's `agent_name_taken`, so
/// only the retry's `claude-proj-2` gets through.
CommandResult _responseWithTakenAgentName(String command) {
  if (command.contains("'agent' 'start'") &&
      command.contains("'claude-proj'")) {
    return ok('{"id":"1","error":{"code":"agent_name_taken","message":"t"}}');
  }
  return _response(command);
}

/// Answers every start with herdr's `agent_not_ready`, and lists [agents]
/// (raw `agent list` entries) as the agents herdr still holds afterwards.
CommandResult Function(String) _responseWithAgentNotReady(String agents) =>
    (command) {
      if (command.contains("'agent' 'start'")) {
        return ok(
          '{"id":"1","error":{"code":"agent_not_ready",'
          '"message":"agent claude-proj is blocked during startup"}}',
        );
      }
      if (command.contains("'agent' 'list'")) {
        return ok('{"id":"1","result":{"agents":[$agents]}}');
      }
      if (command.contains("'workspace' 'close'")) {
        return ok('{"id":"1","result":{}}');
      }
      return _response(command);
    };

const _blockedClaudeProj =
    '{"pane_id":"wZ:p1","workspace_id":"wZ","tab_id":"wZ:t1",'
    '"agent":"claude","name":"claude-proj","agent_status":"blocked",'
    '"cwd":"/tmp/proj","focused":false}';

/// Detects every preset's bin on the host.
CommandResult _responseWithAllAgents(String command) {
  if (command.contains('command -v')) {
    return ok('claude\ncodex\ncopilot\npi\nomp\n');
  }
  return _response(command);
}

Widget _sheetApp(HerdrClient client, {List<String> existingCwds = const []}) =>
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: LaunchAgentSheet(client: client, existingCwds: existingCwds),
      ),
    );

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

/// A Herdr 2 client with canned spaces that records [runAgent] calls.
class _FakeHcClient extends HcClient {
  _FakeHcClient(this.spaces) : super(FakeCommandRunner(_response));

  final List<WorkspaceInfo> spaces;
  final runs = <Map<String, Object?>>[];

  @override
  Future<List<AgentPreset>> detectAgents(List<AgentPreset> presets) async => [
    presets.first,
  ];

  @override
  Future<List<WorkspaceInfo>> listWorkspaces() async => spaces;

  @override
  Future<List<AgentInfo>> listAgents() async => const [];

  @override
  Future<String> runAgent({
    required List<String> argv,
    required String cwd,
    required String spaceId,
    String? name,
  }) async {
    runs.add({'argv': argv, 'cwd': cwd, 'spaceId': spaceId, 'name': name});
    return 'term-9';
  }
}

const _both = [HerdrBackend.herdr, HerdrBackend.hc];

/// A Herdr 2 part whose listWorkspaces calls each wait on the next of
/// [pending], in order.
class _SequencedHcClient extends _FakeHcClient {
  _SequencedHcClient() : super(const []);

  final pending = <Completer<List<WorkspaceInfo>>>[];

  @override
  Future<List<WorkspaceInfo>> listWorkspaces() {
    final c = Completer<List<WorkspaceInfo>>();
    pending.add(c);
    return c.future;
  }
}

/// Pushes [LaunchAgentSheet] as a route and captures its pop value.
class _Harness extends StatefulWidget {
  const _Harness({required this.client, this.backends});

  final HerdrClient client;
  final List<HerdrBackend>? backends;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  String? poppedValue;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () async {
            poppedValue = await showModalBottomSheet<String>(
              context: context,
              isScrollControlled: true,
              builder: (_) => LaunchAgentSheet(
                client: widget.client,
                existingCwds: const [],
                backends: widget.backends,
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

    expect(find.text('Claude'), findsOneWidget);
    expect(find.byKey(const ValueKey('preset_claude')), findsOneWidget);
    expect(find.text('pi'), findsNothing);
    expect(find.text('oh-my-pi'), findsNothing);
    expect(find.byKey(const ValueKey('preset_pi')), findsNothing);
    expect(find.byKey(const ValueKey('preset_omp')), findsNothing);
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
      expect(runner.commands[startIndex], contains("'--kind' 'claude'"));
      expect(runner.commands[startIndex], contains("'--pane' 'wZ:p1'"));
      expect(runner.commands.any((c) => c.contains("'pane' 'split'")), isFalse);

      final state = tester.state<_HarnessState>(find.byType(_Harness));
      expect(state.poppedValue, 'wZ:p1');
    },
  );

  testWidgets('an empty working directory blocks launch with an inline error', (
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

    // Leave the working directory empty and try to launch.
    await tester.tap(find.byKey(const ValueKey('launch_button')));
    await tester.pumpAndSettle();

    expect(find.text('Working directory is required'), findsOneWidget);
    expect(
      runner.commands.any((c) => c.contains("'workspace' 'create'")),
      isFalse,
    );
    final state = tester.state<_HarnessState>(find.byType(_Harness));
    expect(state.poppedValue, isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping cancel closes the sheet without launching', (
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

    final cancelButton = find.byKey(const ValueKey('launch_cancel_button'));
    await tester.ensureVisible(cancelButton);
    await tester.pumpAndSettle();
    await tester.tap(cancelButton);
    await tester.pumpAndSettle();

    final state = tester.state<_HarnessState>(find.byType(_Harness));
    expect(state.poppedValue, isNull);
    expect(runner.commands.any((c) => c.contains("'agent' 'start'")), isFalse);
  });

  testWidgets('existing-workspace launch splits a pane then starts the agent', (
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
    await tester.tap(find.byKey(const ValueKey('ws_mode_existing')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ws_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Project A').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('launch_button')));
    await tester.pumpAndSettle();

    expect(
      runner.commands.any((c) => c.contains("'workspace' 'create'")),
      isFalse,
    );
    final splitIndex = runner.commands.indexWhere(
      (c) => c.contains("'pane' 'split'"),
    );
    final startIndex = runner.commands.indexWhere(
      (c) => c.contains("'agent' 'start'"),
    );
    expect(splitIndex, greaterThanOrEqualTo(0));
    expect(startIndex, greaterThan(splitIndex));
    expect(runner.commands[startIndex], contains("'--pane' 'wA:p2'"));
    final state = tester.state<_HarnessState>(find.byType(_Harness));
    expect(state.poppedValue, 'wA:p2');
  });

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
    final workspaceNameField = tester.widget<TextFormField>(
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

  testWidgets('the default name stays legal for any folder name', (
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

    final nameField = find.byKey(const ValueKey('agent_name_field'));
    for (final cwd in ['/tmp/MyProject', '/tmp/案件']) {
      await tester.enterText(find.byKey(const ValueKey('cwd_field')), cwd);
      await tester.pump();
      final text = tester.widget<TextField>(nameField).controller!.text;
      expect(text, matches(RegExp(r'^[a-z][a-z0-9_-]{0,31}$')), reason: cwd);
    }
  });

  testWidgets(
    'a taken agent name retries with a suffix, keeping the workspace',
    (tester) async {
      final runner = FakeCommandRunner(_responseWithTakenAgentName);
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

      final starts = runner.commands
          .where((c) => c.contains("'agent' 'start'"))
          .toList();
      expect(starts, hasLength(2));
      expect(starts.last, contains("'claude-proj-2'"));
      // A collision is not a failed start: the workspace must survive it.
      expect(
        runner.commands.any((c) => c.contains("'workspace' 'close'")),
        isFalse,
      );
      final state = tester.state<_HarnessState>(find.byType(_Harness));
      expect(state.poppedValue, 'wZ:p1');
    },
  );

  testWidgets(
    'an agent blocked at a startup prompt keeps its workspace and opens',
    (tester) async {
      final runner = FakeCommandRunner(
        _responseWithAgentNotReady(_blockedClaudeProj),
      );
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

      // The user still has to answer the prompt, so nothing is rolled back.
      expect(
        runner.commands.any((c) => c.contains("'workspace' 'close'")),
        isFalse,
      );
      final state = tester.state<_HarnessState>(find.byType(_Harness));
      expect(state.poppedValue, 'wZ:p1');
    },
  );

  testWidgets(
    'agent_not_ready with no live agent still rolls the workspace back',
    (tester) async {
      final runner = FakeCommandRunner(_responseWithAgentNotReady(''));
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

      expect(
        runner.commands.where((c) => c.contains("'workspace' 'close' 'wZ'")),
        hasLength(1),
      );
      final state = tester.state<_HarnessState>(find.byType(_Harness));
      expect(state.poppedValue, isNull);
    },
  );

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

    final cwdField = tester.widget<TextFormField>(
      find.byKey(const ValueKey('cwd_field')),
    );
    expect(cwdField.controller!.text, '/home/dev/proj');
  });

  testWidgets('the launch CTA is a stadium', (tester) async {
    final runner = FakeCommandRunner(_response);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LaunchAgentSheet(
            client: client,
            existingCwds: const ['/home/dev/proj'],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The cwd chips take the 9.5 label ramp, so pin their tap target: it is
    // the one tappable element this pass shrinks.
    final chipSize = tester.getSize(find.byType(ActionChip).first);
    expect(chipSize.height, greaterThanOrEqualTo(44));

    // The button carries no local shape any more: assert what is painted,
    // so a call site that re-added one would fail here.
    final material = tester.widget<Material>(
      find.descendant(
        of: find.byKey(const ValueKey('launch_button')),
        matching: find.byType(Material),
      ),
    );
    expect(material.shape, const StadiumBorder());
  });

  testWidgets('each detected agent renders a tile with its avatar', (
    tester,
  ) async {
    final client = HerdrClient(FakeCommandRunner(_responseWithAllAgents));
    await tester.pumpWidget(_sheetApp(client));
    await tester.pumpAndSettle();

    for (final kind in ['claude', 'codex', 'copilot', 'pi', 'omp']) {
      final tile = find.byKey(ValueKey('preset_$kind'));
      expect(tile, findsOneWidget);
      final avatar = tester.widget<AgentAvatar>(
        find.descendant(of: tile, matching: find.byType(AgentAvatar)),
      );
      expect(avatar.agent, kind);
    }
    expect(find.text('Codex'), findsOneWidget);
    for (final label in ['AGENT', 'WORKING DIRECTORY', 'NAME', 'WORKSPACE']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('New'), findsOneWidget);
    expect(find.text('Existing'), findsOneWidget);
  });

  testWidgets('tapping a tile selects it and names it on the launch button', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final client = HerdrClient(FakeCommandRunner(_responseWithAllAgents));
    await tester.pumpWidget(_sheetApp(client));
    await tester.pumpAndSettle();

    expect(find.text('LAUNCH CLAUDE'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('preset_codex'))),
      isSemantics(label: 'Codex', isButton: true, isSelected: false),
    );

    await tester.tap(find.byKey(const ValueKey('preset_codex')));
    await tester.pumpAndSettle();

    expect(find.text('LAUNCH CODEX'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('preset_copilot')));
    await tester.pumpAndSettle();
    expect(find.text('LAUNCH COPILOT'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('preset_codex')));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.byKey(const ValueKey('preset_codex'))),
      isSemantics(label: 'Codex', isButton: true, isSelected: true),
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('preset_claude'))),
      isSemantics(label: 'Claude', isButton: true, isSelected: false),
    );
    final size = tester.getSize(find.byKey(const ValueKey('preset_codex')));
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));
    handle.dispose();
  });

  testWidgets(
    'on a narrow screen the tiles scroll in one row, cut at the edge',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final client = HerdrClient(FakeCommandRunner(_responseWithAllAgents));
      await tester.pumpWidget(_sheetApp(client));
      await tester.pumpAndSettle();

      final kinds = ['claude', 'codex', 'copilot', 'pi', 'omp'];
      final tops = {
        for (final k in kinds)
          tester.getTopLeft(find.byKey(ValueKey('preset_$k'))).dy,
      };
      expect(tops, hasLength(1));
      // The row bleeds to the screen edge: the overflowing tile is cut there,
      // not at the sheet's 16px content inset.
      final last = find.byKey(const ValueKey('preset_omp'));
      final row = tester.getRect(find.byType(ListView));
      expect(row.left, 0);
      expect(row.right, 360);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('preset_claude'))).dx,
        16,
      );
      expect(tester.getTopLeft(last).dx, lessThan(360 - 16));
      expect(tester.getTopRight(last).dx, greaterThan(360));

      await tester.drag(
        find.byKey(const ValueKey('preset_pi')),
        const Offset(-300, 0),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopRight(last).dx, lessThanOrEqualTo(360));
      expect(tester.getTopLeft(last).dy, tops.single);
    },
  );

  testWidgets('recent directories sit below the cwd field and fill it', (
    tester,
  ) async {
    final client = HerdrClient(FakeCommandRunner(_response));
    await tester.pumpWidget(
      _sheetApp(client, existingCwds: const ['/home/dev/alpha', '/srv/beta']),
    );
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('cwd_field'));
    final alpha = find.byKey(const ValueKey('recent_cwd_/home/dev/alpha'));
    final beta = find.byKey(const ValueKey('recent_cwd_/srv/beta'));
    expect(find.text('Recent'), findsOneWidget);
    expect(
      tester.getTopLeft(alpha).dy,
      greaterThan(tester.getBottomLeft(field).dy),
    );
    // One row, not a wrap.
    expect(tester.getTopLeft(beta).dy, tester.getTopLeft(alpha).dy);

    await tester.tap(beta);
    await tester.pumpAndSettle();

    expect(tester.widget<TextFormField>(field).controller!.text, '/srv/beta');
    expect(tester.widget<ActionChip>(beta).side, isNotNull);
    expect(tester.widget<ActionChip>(alpha).side, isNull);
  });

  group('Herdr 2 host', () {
    testWidgets('lists spaces without a new-workspace option and launches '
        'through runAgent', (tester) async {
      final client = _FakeHcClient(const [
        WorkspaceInfo(workspaceId: 's1', label: 'Space One'),
        WorkspaceInfo(workspaceId: 's2', label: 'Space Two'),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: _Harness(client: client),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('SPACE'), findsOneWidget);
      expect(find.text('WORKSPACE'), findsNothing);
      expect(find.byKey(const ValueKey('ws_mode_new')), findsNothing);
      expect(find.byKey(const ValueKey('ws_mode_existing')), findsNothing);
      expect(find.byKey(const ValueKey('workspace_name_field')), findsNothing);
      expect(find.text('Select space'), findsOneWidget);
      // One backend: no switch.
      expect(find.byKey(const ValueKey('launch_backend_switch')), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('cwd_field')),
        '/tmp/proj',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ws_dropdown')));
      await tester.pumpAndSettle();
      expect(find.text('Space Two'), findsWidgets);
      await tester.tap(find.text('Space Two').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('launch_button')));
      await tester.pumpAndSettle();

      expect(client.runs, [
        {
          'argv': ['claude'],
          'cwd': '/tmp/proj',
          'spaceId': 's2',
          'name': 'claude-proj',
        },
      ]);
      final state = tester.state<_HarnessState>(find.byType(_Harness));
      expect(state.poppedValue, 'term-9');
    });

    testWidgets('with no spaces shows the create-a-space empty state', (
      tester,
    ) async {
      final client = _FakeHcClient(const []);
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

      expect(
        find.text(
          'No spaces yet. Create a space in the Herdr app first, then '
          'launch here.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('ws_mode_new')), findsNothing);
    });
  });

  group('host with both backends', () {
    CombinedHerdrClient combined(_FakeHcClient hc) => CombinedHerdrClient(
      herdr: HerdrClient(
        FakeCommandRunner(
          (command) => command.contains("'agent' 'list'")
              ? ok('{"id":"1","result":{"agents":[]}}')
              : _response(command),
        ),
      ),
      hc: hc,
    );

    testWidgets('offers a Herdr 1 / Herdr 2 switch, defaulting to herdr 1; '
        'Herdr 2 launches through the hc part and is remembered', (
      tester,
    ) async {
      final hc = _FakeHcClient(const [
        WorkspaceInfo(workspaceId: 'hc:s1', label: 'Space One'),
      ]);
      final client = combined(hc);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: _Harness(client: client, backends: _both),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('launch_backend_switch')), findsOne);
      expect(find.text('Herdr 1'), findsOneWidget);
      expect(find.text('Herdr 2'), findsOneWidget);
      // herdr 1 by default: its workspace modes.
      expect(find.byKey(const ValueKey('ws_mode_new')), findsOneWidget);
      expect(find.text('SPACE'), findsNothing);

      await tester.tap(find.text('Herdr 2'));
      await tester.pumpAndSettle();
      expect(find.text('SPACE'), findsOneWidget);
      expect(find.byKey(const ValueKey('ws_mode_new')), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('cwd_field')),
        '/tmp/proj',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ws_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Space One').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('launch_button')));
      await tester.pumpAndSettle();

      expect(hc.runs.single['spaceId'], 'hc:s1');
      final state = tester.state<_HarnessState>(find.byType(_Harness));
      expect(state.poppedValue, 'term-9');

      // Reopened for the same client, the sheet starts on Herdr 2.
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('SPACE'), findsOneWidget);
    });

    Widget sheet(
      HerdrClient client, {
      List<HerdrBackend>? backends = _both,
      Future<bool> Function()? herdrTooOld,
    }) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: LaunchAgentSheet(
          client: client,
          existingCwds: const [],
          backends: backends,
          herdrTooOld: herdrTooOld,
        ),
      ),
    );

    testWidgets('starts on the backends it was handed, without asking the '
        'client again', (tester) async {
      final runner = FakeCommandRunner(_response);
      final client = CombinedHerdrClient(
        herdr: HerdrClient(runner),
        hc: _FakeHcClient(const [
          WorkspaceInfo(workspaceId: 'hc:s1', label: 'Space One'),
        ]),
      );
      await tester.pumpWidget(sheet(client, backends: [HerdrBackend.hc]));
      // First frame: already the Herdr 2 UI, no herdr 1 flash.
      expect(find.text('SPACE'), findsOneWidget);
      expect(find.byKey(const ValueKey('ws_mode_new')), findsNothing);
      expect(find.byKey(const ValueKey('launch_backend_switch')), findsNothing);
      await tester.pumpAndSettle();
      expect(
        runner.commands.where((c) => c.contains("'agent' 'list'")),
        isEmpty,
        reason: 'availableBackends was not called again',
      );
    });

    testWidgets('a remembered backend no longer offered falls back to the '
        'first', (tester) async {
      final client = combined(_FakeHcClient(const []));
      await tester.pumpWidget(sheet(client));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Herdr 2')); // remembered
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(sheet(client, backends: [HerdrBackend.herdr]));
      expect(find.byKey(const ValueKey('ws_mode_new')), findsOneWidget);
      expect(find.text('SPACE'), findsNothing);
    });

    testWidgets('Launch is busy during the herdr 1 version gate: no second '
        'tap, no backend switch; a blocked gate re-enables it', (tester) async {
      final gate = Completer<bool>();
      var gateCalls = 0;
      final client = combined(_FakeHcClient(const []));
      await tester.pumpWidget(
        sheet(
          client,
          herdrTooOld: () {
            gateCalls++;
            return gate.future;
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('cwd_field')),
        '/tmp/proj',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('launch_button')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('launch_button')));
      await tester.pump();

      FilledButton launch() =>
          tester.widget(find.byKey(const ValueKey('launch_button')));
      SegmentedButton<HerdrBackend> backendSwitch() =>
          tester.widget(find.byKey(const ValueKey('launch_backend_switch')));
      expect(launch().onPressed, isNull);
      expect(backendSwitch().onSelectionChanged, isNull);
      await tester.tap(
        find.byKey(const ValueKey('launch_button')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(gateCalls, 1);

      gate.complete(true);
      await tester.pumpAndSettle();
      expect(launch().onPressed, isNotNull);
      expect(backendSwitch().onSelectionChanged, isNotNull);
    });

    testWidgets('a stale space list from before a backend switch is ignored', (
      tester,
    ) async {
      final hc = _SequencedHcClient();
      await tester.pumpWidget(sheet(combined(hc)));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('cwd_field')),
        '/tmp/proj',
      );
      await tester.tap(find.text('Herdr 2')); // list A
      await tester.pump();
      await tester.tap(find.text('Herdr 1'));
      await tester.pump();
      await tester.tap(find.text('Herdr 2')); // list B
      await tester.pump();
      expect(hc.pending, hasLength(2));

      hc.pending[1].complete(const [
        WorkspaceInfo(workspaceId: 'hc:s1', label: 'Space One'),
      ]);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ws_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Space One').last);
      await tester.pumpAndSettle();

      hc.pending[0].complete(const []);
      await tester.pumpAndSettle();
      expect(find.text('Space One'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('launch_button')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('fallback space labels hide the hc: prefix', (tester) async {
      final client = combined(
        _FakeHcClient(const [
          WorkspaceInfo(workspaceId: 'hc:s3', label: ''),
          WorkspaceInfo(workspaceId: 'hc:s4', label: 'Dup'),
          WorkspaceInfo(workspaceId: 'hc:s5', label: 'Dup'),
        ]),
      );
      await tester.pumpWidget(sheet(client, backends: [HerdrBackend.hc]));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ws_dropdown')));
      await tester.pumpAndSettle();
      expect(find.text('Unnamed space (s3)'), findsWidgets);
      expect(find.text('Dup (s4)'), findsWidgets);
      expect(find.text('Dup (s5)'), findsWidgets);
      expect(find.textContaining('hc:'), findsNothing);
    });

    testWidgets('a too-old herdr 1 blocks only the herdr 1 launch', (
      tester,
    ) async {
      var gateCalls = 0;
      final runner = FakeCommandRunner(
        (command) => command.contains("'agent' 'list'")
            ? ok('{"id":"1","result":{"agents":[]}}')
            : _response(command),
      );
      final hc = _FakeHcClient(const [
        WorkspaceInfo(workspaceId: 'hc:s1', label: 'Space One'),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: LaunchAgentSheet(
              client: CombinedHerdrClient(herdr: HerdrClient(runner), hc: hc),
              existingCwds: const [],
              backends: _both,
              herdrTooOld: () async {
                gateCalls++;
                return true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('cwd_field')),
        '/tmp/proj',
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('launch_button')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('launch_button')));
      await tester.pumpAndSettle();
      expect(gateCalls, 1);
      expect(
        runner.commands.where(
          (c) =>
              c.contains("'workspace' 'create'") ||
              c.contains("'pane' 'split'") ||
              c.contains("'agent' 'start'"),
        ),
        isEmpty,
      );
      expect(find.byType(LaunchAgentSheet), findsOneWidget);

      await tester.ensureVisible(find.text('Herdr 2'));
      await tester.pump();
      await tester.tap(find.text('Herdr 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ws_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Space One').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('launch_button')));
      await tester.pumpAndSettle();
      expect(hc.runs, hasLength(1));
    });
  });
}
