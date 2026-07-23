import 'package:drover/src/agents/agent_capabilities.dart';
import 'package:drover/src/agents/copilot/copilot_mode.dart';
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

// Fixtures below are the exact composer footer lines observed live on
// Copilot CLI 1.0.72 — see docs/herdr-notes.md. Idle footers name the mode
// with a leading `<mode> · ` prefix; working footers name it with a
// trailing ` - <mode>` before the `esc interrupt` chrome. Neither form
// appears for the default/interactive mode.
const defaultIdleFixture = '''
Session
› Type a message
/ commands · ? help · tab next tab''';

const planIdleFixture = '''
Session
› Type a message
plan · / commands · ? help · tab next tab''';

const autopilotIdleFixture = '''
Session
› Type a message
autopilot · / commands · tab next tab''';

const defaultWorkingFixture = '''
› Type a message
◎ Working esc interrupt''';

const planWorkingFixture = '''
› Type a message
◉ Working - plan esc interrupt''';

const autopilotWorkingFixture = '''
› Type a message
Working - autopilot esc interrupt''';

// Raw backtab landed on the top-nav (composer not focused) instead of
// cycling the mode. There is no footer chrome line here at all, so parsing
// must not invent a mode from the nav labels.
const navFocusedFixture = '''
Session | Issues | Pull requests | Gists
› Type a message''';

void main() {
  group('parseCopilotMode', () {
    test('reads the default/interactive idle footer as normal', () {
      expect(parseCopilotMode(defaultIdleFixture), AgentMode.normal);
    });

    test('reads the default/interactive working footer as normal', () {
      expect(parseCopilotMode(defaultWorkingFixture), AgentMode.normal);
    });

    test('reads plan mode from the idle footer', () {
      expect(parseCopilotMode(planIdleFixture), AgentMode.plan);
    });

    test('reads plan mode from a terminal-wrapped idle footer', () {
      const wrapped = '''
› Type a message
v1.0.73 available · run / · plan · / commands · ? help · tab
next
update                                      tab
GPT-5.6 Sol''';

      expect(parseCopilotMode(wrapped), AgentMode.plan);
    });

    test('reads plan mode when its prefix wraps before commands', () {
      const wrappedPrefix = '''
› Type a message
plan · /
commands · ? help · tab next tab''';

      expect(parseCopilotMode(wrappedPrefix), AgentMode.plan);
    });

    test('reads plan mode from the working footer', () {
      expect(parseCopilotMode(planWorkingFixture), AgentMode.plan);
    });

    test('does not read a mode word from output above a working footer', () {
      const outputThenNormalWorking = '''
I will make a plan before editing.
› Type a message
◎ Working esc interrupt''';

      expect(parseCopilotMode(outputThenNormalWorking), AgentMode.normal);
    });

    test('prefers a trailing idle footer to earlier working-like output', () {
      const workingThenNormalIdle = '''
Working - autopilot esc interrupt
› Type a message
/ commands · ? help · tab next tab''';

      expect(parseCopilotMode(workingThenNormalIdle), AgentMode.normal);
    });

    test('does not read plan mode from the composer draft', () {
      const planDraftThenNormalIdle = '''
› plan
/ commands · ? help · tab next tab''';

      expect(parseCopilotMode(planDraftThenNormalIdle), AgentMode.normal);
    });

    test('does not read a wrapped plan marker from the composer draft', () {
      const planDraftThenNormalIdle = '''
› plan · /
commands · ? help · tab next tab''';

      expect(parseCopilotMode(planDraftThenNormalIdle), AgentMode.normal);
    });

    test('reads autopilot mode from the idle footer', () {
      expect(parseCopilotMode(autopilotIdleFixture), AgentMode.auto);
    });

    test('reads autopilot mode when its prefix wraps before commands', () {
      const wrappedPrefix = '''
› Type a message
autopilot · /
commands · tab next tab''';

      expect(parseCopilotMode(wrappedPrefix), AgentMode.auto);
    });

    test('does not treat an autopilot composer draft as idle chrome', () {
      const draft = '''
› autopilot
/ commands · tab next tab''';

      expect(parseCopilotMode(draft), isNull);
    });

    test('does not treat an autopilot-like composer row as idle chrome', () {
      const draft = '''
› autopilot · / commands · tab next tab''';

      expect(parseCopilotMode(draft), isNull);
    });

    test('reads autopilot mode from the working footer', () {
      expect(parseCopilotMode(autopilotWorkingFixture), AgentMode.auto);
    });

    test('does not invent a mode from top-nav text lacking footer chrome', () {
      expect(parseCopilotMode(navFocusedFixture), isNull);
    });

    test('returns null when there is no recognizable footer at all', () {
      expect(parseCopilotMode('just some unrelated pane text'), isNull);
    });

    test('tolerates different separator glyphs and spacing', () {
      const spaced = '''
Session
›  Type a message
plan   /commands  ?help  tab  next  tab''';
      expect(parseCopilotMode(spaced), AgentMode.plan);
    });

    test('tolerates upper-case mode wording', () {
      const upper = '''
› Type a message
Working - AUTOPILOT esc interrupt''';
      expect(parseCopilotMode(upper), AgentMode.auto);
    });

    test('only scans the trailing few lines, ignoring a stale scrolled-off '
        'footer', () {
      // A stale autopilot footer scrolled far up the pane, followed by
      // enough unrelated lines that it falls outside the trailing window
      // the parser scans, then a fresh default footer at the very bottom.
      final padding = List.filled(10, 'some earlier output').join('\n');
      final text = '$autopilotIdleFixture\n$padding\n$defaultIdleFixture';
      expect(parseCopilotMode(text), AgentMode.normal);
    });
  });

  group('CopilotModeCapability', () {
    test('parseMode delegates to parseCopilotMode', () {
      const capability = CopilotModeCapability();
      expect(capability.parseMode(autopilotIdleFixture), AgentMode.auto);
    });

    test('cycleMode sends the raw backtab escape sequence', () async {
      const capability = CopilotModeCapability();
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
