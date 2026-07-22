import 'package:drover/src/agents/claude/claude_adapter.dart';
import 'package:drover/src/agents/copilot/copilot_adapter.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCommandRunner extends CommandRunner {
  final commands = <String>[];

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<void> uploadFile(String remotePath, List<int> bytes) async {}

  @override
  Future<List<RemoteDirEntry>> listDirectory(String path) async => [];

  @override
  Future<String> resolvePath(String path) async => path;

  @override
  Future<void> dispose() async {}
}

/// Records commands like [FakeCommandRunner] but throws on the first command
/// that contains [throwOn], without recording that command.
class ThrowingCommandRunner extends FakeCommandRunner {
  ThrowingCommandRunner({required this.throwOn});

  final String throwOn;

  @override
  Future<CommandResult> run(String command) async {
    if (command.contains(throwOn)) {
      throw Exception('simulated failure: $command');
    }
    return super.run(command);
  }
}

void main() {
  group('CopilotAgentAdapter.deliverPrompt', () {
    test(
      'brackets the prompt with a focus-gained/focus-lost pair, in order',
      () async {
        final runner = FakeCommandRunner();
        final client = HerdrClient(runner);

        await const CopilotAgentAdapter().deliverPrompt(client, 'wB:p1', 'hi');

        expect(runner.commands, hasLength(3));
        expect(runner.commands[0], contains('send-text'));
        expect(runner.commands[0], contains('\x1b[I'));
        expect(runner.commands[1], contains("'agent' 'prompt' 'wB:p1' 'hi'"));
        expect(runner.commands[2], contains('send-text'));
        expect(runner.commands[2], contains('\x1b[O'));
      },
    );

    test(
      'still sends focus-lost even when the prompt operation throws',
      () async {
        final runner = ThrowingCommandRunner(throwOn: "'agent' 'prompt'");
        final client = HerdrClient(runner);

        await expectLater(
          () => const CopilotAgentAdapter().deliverPrompt(
            client,
            'wB:p1',
            'hi',
          ),
          throwsException,
        );

        // focus-gained was sent (the throw hadn't happened yet)
        expect(runner.commands, hasLength(2));
        expect(runner.commands[0], contains('send-text'));
        expect(runner.commands[0], contains('\x1b[I'));
        // focus-lost was sent as cleanup despite the failure
        expect(runner.commands[1], contains('send-text'));
        expect(runner.commands[1], contains('\x1b[O'));
        // the prompt itself never completed
        expect(
          runner.commands.any((c) => c.contains("'agent' 'prompt'")),
          isFalse,
        );
      },
    );
  });

  group('AgentAdapter.deliverPrompt default', () {
    test('issues a single agent prompt with no focus brackets', () async {
      final runner = FakeCommandRunner();
      final client = HerdrClient(runner);

      await const ClaudeAgentAdapter().deliverPrompt(client, 'wB:p1', 'hi');

      expect(runner.commands, hasLength(1));
      expect(runner.commands[0], contains("'agent' 'prompt' 'wB:p1' 'hi'"));
      expect(runner.commands[0], isNot(contains('send-text')));
    });
  });
}
