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

void main() {
  group('CopilotAgentAdapter.deliverPrompt', () {
    test(
      'brackets the prompt with a focus-gained/focus-lost pair, in order',
      () async {
        final runner = FakeCommandRunner();
        final client = HerdrClient(runner);

        await const CopilotAgentAdapter().deliverPrompt(client, 'wB:p1', 'hi');

        expect(runner.commands, [
          "~/.local/bin/herdr 'pane' 'send-text' 'wB:p1' '[I'",
          "~/.local/bin/herdr 'agent' 'prompt' 'wB:p1' 'hi'",
          "~/.local/bin/herdr 'pane' 'send-text' 'wB:p1' '[O'",
        ]);
      },
    );
  });

  group('AgentAdapter.deliverPrompt default', () {
    test('issues a single agent prompt with no focus brackets', () async {
      final runner = FakeCommandRunner();
      final client = HerdrClient(runner);

      await const ClaudeAgentAdapter().deliverPrompt(client, 'wB:p1', 'hi');

      expect(runner.commands, [
        "~/.local/bin/herdr 'agent' 'prompt' 'wB:p1' 'hi'",
      ]);
    });
  });
}
