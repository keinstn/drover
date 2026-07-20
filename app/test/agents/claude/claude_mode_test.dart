import 'package:drover/src/agents/agent_capabilities.dart';
import 'package:drover/src/agents/claude/claude_mode.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCommandRunner extends CommandRunner {
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

const permissionPromptFixture = '''
 Bash command

   touch spike-test.txt
   Create empty file spike-test.txt

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to drover-spike-test/ from this
      project
   3. No

 Esc to cancel · Tab to amend · ctrl+e to explain''';

const chromeFixture = '''
✻ Baked for 13s

─────────────────────────────────────────
❯ send it a real task
─────────────────────────────────────────
  -- INSERT -- ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents''';

void main() {
  group('parseAgentMode', () {
    test('reads auto-accept from the mode line', () {
      expect(parseAgentMode(chromeFixture), AgentMode.autoAccept);
    });

    test('reads auto-accept from the "accept edits" wording', () {
      expect(
        parseAgentMode('body\n  ⏵⏵ accept edits on (shift+tab to cycle)'),
        AgentMode.autoAccept,
      );
    });

    test('maps the default "manual mode" line to normal', () {
      expect(
        parseAgentMode('body\n  -- INSERT -- ⏸ manual mode on'),
        AgentMode.normal,
      );
    });

    test('reads plan mode', () {
      expect(
        parseAgentMode('body\n  ⏸ plan mode on (shift+tab to cycle)'),
        AgentMode.plan,
      );
    });

    test('reads bypass permissions mode', () {
      expect(
        parseAgentMode('body\n  ⏵⏵ bypass permissions on (shift+tab to cycle)'),
        AgentMode.bypass,
      );
    });

    test('falls back to normal for a bare insert line', () {
      expect(parseAgentMode('body\n  -- INSERT --'), AgentMode.normal);
    });

    test('returns null when there is no mode line', () {
      expect(parseAgentMode(permissionPromptFixture), isNull);
    });
  });

  group('ClaudeModeCapability', () {
    test('parseMode delegates to parseAgentMode', () {
      const capability = ClaudeModeCapability();
      expect(capability.parseMode(chromeFixture), AgentMode.autoAccept);
    });

    test('cycleMode sends the raw backtab escape sequence', () async {
      const capability = ClaudeModeCapability();
      final runner = _FakeCommandRunner();
      final client = HerdrClient(runner);

      await capability.cycleMode(client, 'wB:p1');

      expect(
        runner.commands.single,
        "~/.local/bin/herdr 'pane' 'send-text' 'wB:p1' '\u001b[Z'",
      );
    });
  });
}
