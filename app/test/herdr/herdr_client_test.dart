import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCommandRunner implements CommandRunner {
  FakeCommandRunner(this._response);

  final CommandResult Function(String command) _response;
  final commands = <String>[];

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
    return _response(command);
  }

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
        "'--lines' '50' '--format' 'text'",
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

    test('sendKeys builds the pane send-keys command', () async {
      final runner = FakeCommandRunner((_) => ok('{"id":"1","result":{}}'));
      final client = HerdrClient(runner);

      await client.sendKeys('wB:p4', 'enter');

      expect(
        runner.commands.single,
        "~/.local/bin/herdr 'pane' 'send-keys' 'wB:p4' 'enter'",
      );
    });

    test('prompt sends text then enter', () async {
      final runner = FakeCommandRunner((_) => ok('{"id":"1","result":{}}'));
      final client = HerdrClient(runner);

      await client.prompt('wB:p4', 'go');

      expect(runner.commands, [
        "~/.local/bin/herdr 'agent' 'send' 'wB:p4' 'go'",
        "~/.local/bin/herdr 'pane' 'send-keys' 'wB:p4' 'enter'",
      ]);
    });
  });
}
