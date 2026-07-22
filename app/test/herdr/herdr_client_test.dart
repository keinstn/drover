import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/models/agent_preset.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
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
  final uploads = <({String path, List<int> bytes})>[];

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
    return _response(command);
  }

  @override
  Future<void> uploadFile(String remotePath, List<int> bytes) async {
    uploads.add((path: remotePath, bytes: bytes));
  }

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

void main() {
  group('HerdrClient.listAgents', () {
    test('parses result.agents', () async {
      final runner = FakeCommandRunner(
        (_) => ok(
          '{"id":"1","result":{"agents":[{"agent":"claude",'
          '"agent_status":"idle","cwd":"/tmp","focused":false,'
          '"pane_id":"wB:p4","tab_id":"wB:t1","workspace_id":"wB"}]}}',
        ),
      );
      final client = HerdrClient(runner);

      final agents = await client.listAgents();

      expect(agents, hasLength(1));
      expect(agents.single.paneId, 'wB:p4');
      expect(agents.single.status, AgentStatus.idle);
      expect(runner.commands.single, "~/.local/bin/herdr 'agent' 'list'");
    });

    test('throws HerdrException on an error envelope', () async {
      final runner = FakeCommandRunner(
        (_) => ok(
          '{"id":"1","error":{"code":"not_found","message":"pane not found"}}',
        ),
      );
      final client = HerdrClient(runner);

      await expectLater(
        client.listAgents(),
        throwsA(
          isA<HerdrException>()
              .having((e) => e.code, 'code', 'not_found')
              .having((e) => e.message, 'message', 'pane not found'),
        ),
      );
    });

    test('throws HerdrException on non-zero exit code', () async {
      final runner = FakeCommandRunner(
        (_) => const CommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'command not found',
        ),
      );
      final client = HerdrClient(runner);

      await expectLater(
        client.listAgents(),
        throwsA(
          isA<HerdrException>().having((e) => e.code, 'code', 'transport'),
        ),
      );
    });
  });

  group('HerdrClient.getAgent', () {
    test('parses result.agent and builds the get command', () async {
      final runner = FakeCommandRunner(
        (_) => ok(
          '{"id":"1","result":{"agent":{"agent":"claude",'
          '"agent_status":"working","cwd":"/tmp","focused":true,'
          '"pane_id":"wB:p4","tab_id":"wB:t1","workspace_id":"wB"}}}',
        ),
      );
      final client = HerdrClient(runner);

      final agent = await client.getAgent("it's mine");

      expect(agent.status, AgentStatus.working);
      expect(
        runner.commands.single,
        r"~/.local/bin/herdr 'agent' 'get' 'it'\''s mine'",
      );
    });
  });

  group('HerdrClient.readAgent', () {
    test('returns raw terminal output and builds the read command', () async {
      final runner = FakeCommandRunner((_) => ok('\x1b[31msome output\x1b[0m'));
      final client = HerdrClient(runner);

      final text = await client.readAgent('wB:p4', lines: 50);

      expect(text, '\x1b[31msome output\x1b[0m');
      expect(
        runner.commands.single,
        "~/.local/bin/herdr 'agent' 'read' 'wB:p4' '--source' 'recent' "
        "'--lines' '50' '--format' 'ansi'",
      );
    });
  });

  group('HerdrClient.sendKeys / prompt', () {
    test('sendKeys tolerates herdr\'s empty ok response', () async {
      // `pane send-keys` prints nothing on success (exit 0, empty stdout); the
      // client must not treat that as an unparseable response.
      final runner = FakeCommandRunner((_) => ok(''));
      final client = HerdrClient(runner);

      await client.sendKeys('wB:p4', 'shift+tab');

      expect(
        runner.commands.single,
        "~/.local/bin/herdr 'pane' 'send-keys' 'wB:p4' 'shift+tab'",
      );
    });

    test('sendPaneText builds the pane send-text command', () async {
      // `pane send-text` prints nothing on success (exit 0, empty stdout), like
      // send-keys; the client must tolerate that and build the raw-text command.
      final runner = FakeCommandRunner((_) => ok(''));
      final client = HerdrClient(runner);

      await client.sendPaneText('wB:p4', '2');

      expect(
        runner.commands.single,
        "~/.local/bin/herdr 'pane' 'send-text' 'wB:p4' '2'",
      );
    });

    test('prompt builds a single agent prompt command', () async {
      // `agent prompt` prints nothing on success (exit 0, empty stdout), like
      // send-keys; the client must tolerate that and build a single command.
      final runner = FakeCommandRunner((_) => ok(''));
      final client = HerdrClient(runner);

      await client.prompt('wB:p4', 'go');

      expect(
        runner.commands.single,
        "~/.local/bin/herdr 'agent' 'prompt' 'wB:p4' 'go'",
      );
    });
  });

  group('HerdrClient.closeAgent', () {
    test('builds the pane close command', () async {
      final runner = FakeCommandRunner((_) => ok('{"id":"1","result":{}}'));
      final client = HerdrClient(runner);

      await client.closeAgent('wB:p4');

      expect(
        runner.commands.single,
        "~/.local/bin/herdr 'pane' 'close' 'wB:p4'",
      );
    });
  });

  group('HerdrClient.detectAgents', () {
    test('returns the presets whose bin is found on PATH', () async {
      final runner = FakeCommandRunner((_) => ok('claude\ncursor-agent\n'));
      final client = HerdrClient(runner);

      final found = await client.detectAgents(kAgentPresets);

      expect(found, [kAgentPresets[0]]);
      expect(runner.commands, hasLength(1));
      expect(runner.commands.single, contains('command -v'));
      for (final preset in kAgentPresets) {
        expect(runner.commands.single, contains(preset.bin));
      }
    });

    test('returns empty without calling run when presets is empty', () async {
      final runner = FakeCommandRunner((_) => ok(''));
      final client = HerdrClient(runner);

      final found = await client.detectAgents([]);

      expect(found, isEmpty);
      expect(runner.commands, isEmpty);
    });
  });

  group('HerdrClient.createWorkspace', () {
    test(
      'returns workspace and root pane ids and builds the create command',
      () async {
        final runner = FakeCommandRunner(
          (_) => ok(
            '{"id":"1","result":{"workspace":{"workspace_id":"wJ",'
            '"label":"proj"},"root_pane":{"pane_id":"wJ:p1"}}}',
          ),
        );
        final client = HerdrClient(runner);

        final workspace = await client.createWorkspace(
          label: 'proj',
          cwd: '/tmp/proj',
        );

        expect(workspace.workspaceId, 'wJ');
        expect(workspace.paneId, 'wJ:p1');
        expect(
          runner.commands.single,
          "~/.local/bin/herdr 'workspace' 'create' '--label' 'proj' "
          "'--cwd' '/tmp/proj' '--no-focus'",
        );
      },
    );

    test('omits --cwd when not given', () async {
      final runner = FakeCommandRunner(
        (_) => ok(
          '{"id":"1","result":{"workspace":{"workspace_id":"wJ",'
          '"label":"proj"},"root_pane":{"pane_id":"wJ:p1"}}}',
        ),
      );
      final client = HerdrClient(runner);

      await client.createWorkspace(label: 'proj');

      expect(
        runner.commands.single,
        "~/.local/bin/herdr 'workspace' 'create' '--label' 'proj' '--no-focus'",
      );
    });
  });

  group('HerdrClient.listWorkspaces', () {
    test('parses result.workspaces and builds the list command', () async {
      final runner = FakeCommandRunner(
        (_) => ok(
          '{"id":"1","result":{"workspaces":[{"workspace_id":"w7",'
          '"label":"ideas"}]}}',
        ),
      );
      final client = HerdrClient(runner);

      final workspaces = await client.listWorkspaces();

      expect(workspaces, hasLength(1));
      expect(workspaces.single.workspaceId, 'w7');
      expect(workspaces.single.label, 'ideas');
      expect(runner.commands.single, "~/.local/bin/herdr 'workspace' 'list'");
    });
  });

  group('HerdrClient.closeWorkspace', () {
    test('builds the close command', () async {
      final runner = FakeCommandRunner(
        (_) => ok('{"id":"1","result":{"type":"ok"}}'),
      );
      final client = HerdrClient(runner);

      await client.closeWorkspace('wZ');

      expect(
        runner.commands.single,
        "~/.local/bin/herdr 'workspace' 'close' 'wZ'",
      );
    });
  });

  group('HerdrClient.renameWorkspace', () {
    test('builds the rename command', () async {
      final runner = FakeCommandRunner(
        (_) => ok('{"id":"1","result":{"type":"workspace_renamed"}}'),
      );
      final client = HerdrClient(runner);

      await client.renameWorkspace('wZ', 'Project Z');

      expect(
        runner.commands.single,
        "~/.local/bin/herdr 'workspace' 'rename' 'wZ' 'Project Z'",
      );
    });
  });

  group('HerdrClient.startAgent', () {
    test('builds the 0.7.5 start command for an existing pane', () async {
      final runner = FakeCommandRunner(
        (_) => ok('{"id":"1","result":{"type":"agent_started"}}'),
      );
      final client = HerdrClient(runner);

      await client.startAgent(name: 'proj', kind: 'claude', paneId: 'wJ:p1');

      expect(
        runner.commands.single,
        "~/.local/bin/herdr 'agent' 'start' 'proj' '--kind' 'claude' "
        "'--pane' 'wJ:p1'",
      );
    });

    test('splits a pane in the requested workspace', () async {
      final runner = FakeCommandRunner((command) {
        if (command.contains("'pane' 'list'")) {
          return ok('{"id":"1","result":{"panes":[{"pane_id":"wJ:p1"}]}}');
        }
        if (command.contains("'pane' 'split'")) {
          return ok('{"id":"1","result":{"pane":{"pane_id":"wJ:p2"}}}');
        }
        throw StateError('unexpected command: $command');
      });
      final client = HerdrClient(runner);

      final paneId = await client.splitPane(
        workspaceId: 'wJ',
        cwd: '/tmp/proj',
      );

      expect(paneId, 'wJ:p2');
      expect(runner.commands, [
        "~/.local/bin/herdr 'pane' 'list' '--workspace' 'wJ'",
        "~/.local/bin/herdr 'pane' 'split' 'wJ:p1' '--direction' 'right' "
            "'--cwd' '/tmp/proj' '--no-focus'",
      ]);
    });

    test('rejects a workspace with no pane to split', () async {
      final runner = FakeCommandRunner(
        (_) => ok('{"id":"1","result":{"panes":[]}}'),
      );
      final client = HerdrClient(runner);

      await expectLater(
        client.splitPane(workspaceId: 'wJ', cwd: '/tmp/proj'),
        throwsA(
          isA<HerdrException>().having(
            (e) => e.message,
            'message',
            'missing panes field',
          ),
        ),
      );
    });
  });

  group('HerdrClient.renameAgent', () {
    test('builds the rename command', () async {
      final runner = FakeCommandRunner(
        (_) => ok('{"id":"1","result":{"type":"agent_renamed"}}'),
      );
      final client = HerdrClient(runner);

      await client.renameAgent('wA:p1', 'Pair Programmer');

      expect(
        runner.commands.single,
        "~/.local/bin/herdr 'agent' 'rename' 'wA:p1' 'Pair Programmer'",
      );
    });
  });

  group('HerdrClient.listDirectory / resolvePath', () {
    test(
      'listDirectory forwards to the runner and returns its entries',
      () async {
        final runner = FakeCommandRunner(
          (_) => ok(''),
          listDirectory: (path) async => [
            RemoteDirEntry(name: '$path/src', isDirectory: true),
          ],
        );
        final client = HerdrClient(runner);

        final entries = await client.listDirectory('/tmp/proj');

        expect(entries, hasLength(1));
        expect(entries.single.name, '/tmp/proj/src');
        expect(entries.single.isDirectory, isTrue);
      },
    );

    test('resolvePath forwards to the runner and returns its result', () async {
      final runner = FakeCommandRunner(
        (_) => ok(''),
        resolvePath: (path) async => path == '.' ? '/home/dev' : path,
      );
      final client = HerdrClient(runner);

      final resolved = await client.resolvePath('.');

      expect(resolved, '/home/dev');
    });
  });
}
