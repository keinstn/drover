import 'package:drover/src/agents/agent_capabilities.dart';
import 'package:drover/src/agents/codex/codex_mode.dart';
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

// Fixtures mimic the trailing footer area observed live on Codex CLI 0.144.6.
// The footer chrome is `<model> <effort> · <cwd>`; "Plan mode (shift+tab to
// cycle)" is appended when plan mode is active.

const normalModeFixture = '''
Some transcript content here.
gpt-5.6-terra medium · ~/Projects/myproject''';

const planModeFixture = '''
Some transcript content here.
gpt-5.6-terra medium · ~/Projects/myproject Plan mode (shift+tab to cycle)''';

// Plan-mode label on a separate line (narrow pane wrapping).
const planModeWrappedFixture = '''
Some transcript content here.
gpt-5.6-terra medium · ~/Projects/myproject
Plan mode (shift+tab to cycle)''';

// Absolute-path cwd (non-home directory).
const normalModeAbsCwdFixture = '''
gpt-5.6-terra medium · /var/projects/myproject''';

// No footer chrome — pane is in a working or dialog state.
const workingStateFixture = '''
⠸ Thinking...
Writing to src/main.dart''';

// Transcript prose containing the word "plan" — must not match.
const planProseFixture = '''
I recommend using a plan mode to organize your work.
gpt-5.6-terra medium · ~/Projects/myproject''';

// Pane showing only the top nav (no composer footer).
const navOnlyFixture = 'Session | Issues | Pull requests | Gists';

void main() {
  group('parseCodexMode', () {
    test(
      'returns normal when the footer chrome is present with no mode label',
      () {
        expect(parseCodexMode(normalModeFixture), AgentMode.normal);
      },
    );

    test(
      'returns plan when "Plan mode" follows the footer chrome on same line',
      () {
        expect(parseCodexMode(planModeFixture), AgentMode.plan);
      },
    );

    test('returns plan when mode label wraps to the next line', () {
      expect(parseCodexMode(planModeWrappedFixture), AgentMode.plan);
    });

    test('returns normal for an absolute-path cwd footer', () {
      expect(parseCodexMode(normalModeAbsCwdFixture), AgentMode.normal);
    });

    test('returns null when there is no footer chrome', () {
      expect(parseCodexMode(workingStateFixture), isNull);
    });

    test('returns null for a bare nav line with no footer', () {
      expect(parseCodexMode(navOnlyFixture), isNull);
    });

    test('does not match bare "plan" in transcript prose — footer needed', () {
      // planProseFixture ends with a normal-mode footer, so normal is returned.
      expect(parseCodexMode(planProseFixture), AgentMode.normal);
    });

    test('returns null for empty text', () {
      expect(parseCodexMode(''), isNull);
    });

    test('returns null when footer chrome appears only far above the trailing '
        'window', () {
      // Build a pane where the chrome line is well above the last 6 lines.
      final lines = [
        'gpt-5.6-terra medium · ~/Projects/myproject',
        ...List.filled(10, 'filler line'),
      ];
      expect(parseCodexMode(lines.join('\n')), isNull);
    });
  });

  group('CodexModeCapability', () {
    test('parseMode delegates to parseCodexMode', () {
      const capability = CodexModeCapability();
      expect(capability.parseMode(planModeFixture), AgentMode.plan);
      expect(capability.parseMode(normalModeFixture), AgentMode.normal);
      expect(capability.parseMode(workingStateFixture), isNull);
    });

    test('cycleMode sends the raw backtab escape sequence', () async {
      const capability = CodexModeCapability();
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
