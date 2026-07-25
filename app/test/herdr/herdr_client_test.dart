import 'dart:async';
import 'dart:convert';

import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/herdr/host_platform.dart';
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

    test('throws the coded error when a non-zero exit carries a JSON error '
        'envelope on stderr', () async {
      final runner = FakeCommandRunner(
        (_) => const CommandResult(
          exitCode: 1,
          stdout: '',
          stderr:
              '{"id":"1","error":{"code":"not_found",'
              '"message":"pane not found"}}',
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

    test(
      'throws HerdrException with the failing command, exit code, stdout and '
      'stderr on unparseable stdout',
      () async {
        final runner = FakeCommandRunner(
          (_) => ok('not json\nwith a stray line'),
        );
        final client = HerdrClient(runner);

        await expectLater(
          client.listAgents(),
          throwsA(
            isA<HerdrException>()
                .having((e) => e.code, 'code', 'transport')
                .having(
                  (e) => e.message,
                  'message',
                  allOf(
                    contains('herdr agent list'),
                    contains('exit 0'),
                    contains(jsonEncode('not json\nwith a stray line')),
                  ),
                ),
          ),
        );
      },
    );
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
      // The Unix default probes under a POSIX login shell.
      expect(runner.commands.single, startsWith('sh -lc '));
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

  group('HerdrClient platform wiring', () {
    const encodedPrefix =
        'powershell.exe -NoProfile -NonInteractive -EncodedCommand ';

    /// Decode an `-EncodedCommand` exec line back to the PowerShell script:
    /// base64 → UTF-16LE bytes → code units (low byte first).
    String decodeScript(String command) {
      expect(command, startsWith(encodedPrefix));
      final bytes = base64.decode(command.substring(encodedPrefix.length));
      final units = [
        for (var i = 0; i < bytes.length; i += 2)
          bytes[i] | (bytes[i + 1] << 8),
      ];
      return String.fromCharCodes(units);
    }

    const agentsEnvelope =
        '{"id":"1","result":{"agents":[{"agent":"claude",'
        '"agent_status":"idle","cwd":"/tmp","focused":false,'
        '"pane_id":"wB:p4","tab_id":"wB:t1","workspace_id":"wB"}]}}';

    test('WindowsHostPlatform wraps herdr commands in powershell', () async {
      final runner = FakeCommandRunner((_) => ok(agentsEnvelope));
      final client = HerdrClient(runner, platform: const WindowsHostPlatform());

      final agents = await client.listAgents();

      expect(agents, hasLength(1));
      final script = decodeScript(runner.commands.single);
      // Bare 'herdr' proves the default ~/.local/bin/herdr was resolved for
      // Windows.
      expect(script, contains("& 'herdr' 'agent' 'list'"));
    });

    test('accepts an async platform (the production detect path)', () async {
      final runner = FakeCommandRunner((_) => ok(agentsEnvelope));
      final client = HerdrClient(
        runner,
        platform: Future<HostPlatform>.value(const WindowsHostPlatform()),
      );

      final agents = await client.listAgents();

      expect(agents, hasLength(1));
      final script = decodeScript(runner.commands.single);
      expect(script, contains("& 'herdr' 'agent' 'list'"));
    });

    test('surfaces a detection failure as a transport error', () async {
      final runner = FakeCommandRunner((_) => ok(agentsEnvelope));
      final client = HerdrClient(
        runner,
        platform: Future<HostPlatform>.error(
          HostPlatformDetectionException('nope'),
        )..ignore(),
      );

      await expectLater(
        client.listAgents(),
        throwsA(
          isA<HerdrException>()
              .having((e) => e.code, 'code', 'transport')
              .having((e) => e.message, 'message', contains('nope')),
        ),
      );
      expect(runner.commands, isEmpty);
    });

    test('detectAgents probes via the platform command', () async {
      // Windows output has \r\n line endings; the shared parse must cope.
      final runner = FakeCommandRunner((_) => ok('claude\r\ncopilot\r\n'));
      final client = HerdrClient(runner, platform: const WindowsHostPlatform());

      final found = await client.detectAgents(kAgentPresets);

      expect(
        found,
        kAgentPresets
            .where((p) => p.bin == 'claude' || p.bin == 'copilot')
            .toList(),
      );
      expect(runner.commands.single, startsWith(encodedPrefix));
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
      final sleeps = <Duration>[];
      final runner = FakeCommandRunner(
        (_) => ok('{"id":"1","result":{"type":"agent_started"}}'),
      );
      final client = HerdrClient(
        runner,
        sleep: (duration) async {
          sleeps.add(duration);
        },
      );

      await client.startAgent(name: 'proj', kind: 'claude', paneId: 'wJ:p1');

      expect(
        runner.commands.single,
        "~/.local/bin/herdr 'agent' 'start' 'proj' '--kind' 'claude' "
        "'--pane' 'wJ:p1'",
      );
      expect(sleeps, isEmpty);
    });
  });

  group('HerdrClient.startAgent retry', () {
    int agentStartCalls(FakeCommandRunner runner) => runner.commands
        .where((command) => command.contains("'agent' 'start'"))
        .length;

    test('retries on agent_pane_busy then succeeds', () async {
      var starts = 0;
      final sleeps = <Duration>[];
      final runner = FakeCommandRunner((command) {
        if (command.contains("'agent' 'start'")) {
          starts++;
          if (starts <= 2) {
            return ok(
              '{"id":"1","error":{"code":"agent_pane_busy",'
              '"message":"agent target pane is not an available shell"}}',
            );
          }
          return ok('{"id":"1","result":{"type":"agent_started"}}');
        }
        throw StateError('unexpected command: $command');
      });
      final client = HerdrClient(
        runner,
        sleep: (duration) async {
          sleeps.add(duration);
        },
      );

      await client.startAgent(name: 'proj', kind: 'claude', paneId: 'wJ:p1');

      expect(agentStartCalls(runner), 3);
      expect(sleeps, [
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 500),
      ]);
    });

    test('retries when agent_pane_busy arrives as exit 0 with an empty stdout '
        'and the error envelope on stderr', () async {
      var starts = 0;
      final sleeps = <Duration>[];
      final runner = FakeCommandRunner((command) {
        if (command.contains("'agent' 'start'")) {
          starts++;
          if (starts <= 2) {
            return const CommandResult(
              exitCode: 0,
              stdout: '',
              stderr:
                  '{"id":"1","error":{"code":"agent_pane_busy",'
                  '"message":"agent target pane is not an available '
                  'shell"}}',
            );
          }
          return ok('{"id":"1","result":{"type":"agent_started"}}');
        }
        throw StateError('unexpected command: $command');
      });
      final client = HerdrClient(
        runner,
        sleep: (duration) async {
          sleeps.add(duration);
        },
      );

      await client.startAgent(name: 'proj', kind: 'claude', paneId: 'wJ:p1');

      expect(agentStartCalls(runner), 3);
      expect(sleeps, [
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 500),
      ]);
    });

    test('does not retry on a different error code', () async {
      final sleeps = <Duration>[];
      final runner = FakeCommandRunner(
        (_) => ok(
          '{"id":"1","error":{"code":"some_other_error",'
          '"message":"not pane busy"}}',
        ),
      );
      final client = HerdrClient(
        runner,
        sleep: (duration) async {
          sleeps.add(duration);
        },
      );

      await expectLater(
        client.startAgent(name: 'proj', kind: 'claude', paneId: 'wJ:p1'),
        throwsA(
          isA<HerdrException>()
              .having((e) => e.code, 'code', 'some_other_error')
              .having((e) => e.message, 'message', 'not pane busy'),
        ),
      );

      expect(agentStartCalls(runner), 1);
      expect(sleeps, isEmpty);
    });

    test('gives up after the max attempts', () async {
      final sleeps = <Duration>[];
      final runner = FakeCommandRunner(
        (_) => ok(
          '{"id":"1","error":{"code":"agent_pane_busy",'
          '"message":"still busy"}}',
        ),
      );
      final client = HerdrClient(
        runner,
        sleep: (duration) async {
          sleeps.add(duration);
        },
      );

      await expectLater(
        client.startAgent(name: 'proj', kind: 'claude', paneId: 'wJ:p1'),
        throwsA(
          isA<HerdrException>()
              .having((e) => e.code, 'code', 'agent_pane_busy')
              .having((e) => e.message, 'message', 'still busy'),
        ),
      );

      expect(agentStartCalls(runner), 6);
      expect(sleeps, [
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 500),
        const Duration(milliseconds: 1000),
        const Duration(milliseconds: 2000),
        const Duration(milliseconds: 4000),
      ]);
    });
  });

  group('HerdrClient.splitPane', () {
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

  group('HerdrClient.findPlugin', () {
    test('returns the plugin when the CLI list is non-empty', () async {
      final runner = FakeCommandRunner(
        (_) => ok(
          '{"id":"1","result":{"plugins":[{"description":"d",'
          '"enabled":true,"plugin_id":"drover.notify",'
          '"plugin_root":"/checkout/drover-notify"}]}}',
        ),
      );
      final client = HerdrClient(runner);

      final plugin = await client.findPlugin('drover.notify');

      expect(plugin, isNotNull);
      expect(plugin!.pluginId, 'drover.notify');
      expect(plugin.enabled, isTrue);
      expect(plugin.pluginRoot, '/checkout/drover-notify');
      expect(
        runner.commands.single,
        "~/.local/bin/herdr 'plugin' 'list' '--plugin' 'drover.notify' '--json'",
      );
    });

    test('returns null when the CLI list is empty', () async {
      final runner = FakeCommandRunner(
        (_) => ok('{"id":"1","result":{"plugins":[]}}'),
      );
      final client = HerdrClient(runner);

      expect(await client.findPlugin('drover.notify'), isNull);
    });
  });

  group('HerdrClient.pluginConfigDir', () {
    test('returns the trimmed raw stdout, not a JSON envelope', () async {
      final runner = FakeCommandRunner(
        (_) => ok('/home/dev/.config/herdr/plugins/config/drover.notify\n'),
      );
      final client = HerdrClient(runner);

      final dir = await client.pluginConfigDir('drover.notify');

      expect(dir, '/home/dev/.config/herdr/plugins/config/drover.notify');
      expect(
        runner.commands.single,
        "~/.local/bin/herdr 'plugin' 'config-dir' 'drover.notify'",
      );
    });
  });
}
