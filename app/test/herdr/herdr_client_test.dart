import 'dart:convert';
import 'dart:typed_data';

import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/image/image_input.dart';
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
    test('returns result.read.text and builds the read command', () async {
      final runner = FakeCommandRunner(
        (_) => ok('{"id":"1","result":{"read":{"text":"some output"}}}'),
      );
      final client = HerdrClient(runner);

      final text = await client.readAgent('wB:p4', lines: 50);

      expect(text, 'some output');
      expect(
        runner.commands.single,
        "~/.local/bin/herdr 'agent' 'read' 'wB:p4' '--source' 'recent' "
        "'--lines' '50' '--format' 'ansi'",
      );
    });
  });

  group('HerdrClient.sendText / sendKeys / prompt', () {
    test('sendText builds the agent send command', () async {
      final runner = FakeCommandRunner((_) => ok('{"id":"1","result":{}}'));
      final client = HerdrClient(runner);

      await client.sendText('wB:p4', "it's a test");

      expect(
        runner.commands.single,
        r"~/.local/bin/herdr 'agent' 'send' 'wB:p4' 'it'\''s a test'",
      );
    });

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

    test('prompt sends text then enter', () async {
      // agent send returns an envelope; pane send-keys returns empty stdout.
      final runner = FakeCommandRunner(
        (c) =>
            c.contains("'send-keys'") ? ok('') : ok('{"id":"1","result":{}}'),
      );
      final client = HerdrClient(runner);

      await client.prompt('wB:p4', 'go');

      expect(runner.commands, [
        "~/.local/bin/herdr 'agent' 'send' 'wB:p4' 'go'",
        "~/.local/bin/herdr 'pane' 'send-keys' 'wB:p4' 'enter'",
      ]);
    });
  });

  group('HerdrClient.sendImages', () {
    test('uploads bytes and prompts with caption and paths', () async {
      final runner = FakeCommandRunner((_) => ok('{"id":"1","result":{}}'));
      final client = HerdrClient(runner);
      const agent = AgentInfo(
        paneId: 'wB:p1',
        workspaceId: 'wB',
        tabId: 'wB:t1',
        agent: 'claude',
        status: AgentStatus.idle,
        cwd: '/tmp/proj',
        focused: false,
      );

      final paths = await client.sendImages(
        agent,
        images: [
          PickedImage(bytes: Uint8List.fromList([1, 2, 3]), extension: 'png'),
          PickedImage(bytes: Uint8List.fromList([4, 5, 6]), extension: 'jpg'),
        ],
        caption: 'look at this',
        timestampMs: 42,
      );

      expect(paths, [
        '/tmp/proj/.drover/img-42-0.png',
        '/tmp/proj/.drover/img-42-1.jpg',
      ]);
      expect(runner.uploads[0].path, '/tmp/proj/.drover/img-42-0.png');
      expect(runner.uploads[0].bytes, [1, 2, 3]);
      expect(runner.uploads[1].path, '/tmp/proj/.drover/img-42-1.jpg');
      expect(runner.uploads[1].bytes, [4, 5, 6]);
      expect(runner.uploads[2].path, '/tmp/proj/.drover/.gitignore');
      expect(utf8.decode(runner.uploads[2].bytes), '*\n');
      expect(
        runner.commands.where(
          (c) => c == "command mkdir -p '/tmp/proj/.drover'",
        ),
        hasLength(1),
      );
      expect(
        runner.commands,
        containsAllInOrder([
          "command mkdir -p '/tmp/proj/.drover'",
          "~/.local/bin/herdr 'agent' 'send' 'wB:p1' "
              "'look at this\n/tmp/proj/.drover/img-42-0.png\n"
              "/tmp/proj/.drover/img-42-1.jpg'",
          "~/.local/bin/herdr 'pane' 'send-keys' 'wB:p1' 'enter'",
        ]),
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

      expect(found, [kAgentPresets[0], kAgentPresets[5]]);
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
    test('returns workspace_id and builds the create command', () async {
      final runner = FakeCommandRunner(
        (_) => ok(
          '{"id":"1","result":{"workspace":{"workspace_id":"wJ",'
          '"label":"proj"}}}',
        ),
      );
      final client = HerdrClient(runner);

      final id = await client.createWorkspace(label: 'proj', cwd: '/tmp/proj');

      expect(id, 'wJ');
      expect(
        runner.commands.single,
        "~/.local/bin/herdr 'workspace' 'create' '--label' 'proj' "
        "'--cwd' '/tmp/proj' '--no-focus'",
      );
    });

    test('omits --cwd when not given', () async {
      final runner = FakeCommandRunner(
        (_) => ok(
          '{"id":"1","result":{"workspace":{"workspace_id":"wJ",'
          '"label":"proj"}}}',
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

  group('HerdrClient.startAgent', () {
    test('builds the start command with a workspace id', () async {
      final runner = FakeCommandRunner(
        (_) => ok('{"id":"1","result":{"type":"agent_started"}}'),
      );
      final client = HerdrClient(runner);

      await client.startAgent(
        name: 'proj',
        argv: ['claude'],
        cwd: '/tmp/proj',
        workspaceId: 'wJ',
      );

      expect(
        runner.commands.single,
        "~/.local/bin/herdr 'agent' 'start' 'proj' '--cwd' '/tmp/proj' "
        "'--workspace' 'wJ' '--no-focus' '--' 'claude'",
      );
    });

    test('omits --workspace when not given', () async {
      final runner = FakeCommandRunner(
        (_) => ok('{"id":"1","result":{"type":"agent_started"}}'),
      );
      final client = HerdrClient(runner);

      await client.startAgent(name: 'proj', argv: ['claude'], cwd: '/tmp/proj');

      expect(
        runner.commands.single,
        "~/.local/bin/herdr 'agent' 'start' 'proj' '--cwd' '/tmp/proj' "
        "'--no-focus' '--' 'claude'",
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
