// The stateful fake behind drover's demo mode: a scripted Claude Code session
// (permission prompt -> answer -> reply -> follow-up -> reply) driven by
// command-invocation counts rather than a Timer, so it stays deterministic
// under `flutter test`.
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../herdr/command_runner.dart';
import '../herdr/herdr_client.dart';
import 'demo_herdr.dart';

/// Identity of the demo's single synthetic agent — never persisted, never a
/// real [HostConfig].
const demoHostId = 'demo';
const demoPaneId = 'demo:p1';
const demoWorkspaceId = 'demo:w1';
const demoTabId = 'demo:t1';

const _demoHerdrVersion = '0.7.5';

/// The demo session's identity, reported as the agent's `agent_session` value.
/// Must be a real UUID: every native-transcript loader gates on
/// `isNativeTranscriptSessionId`, so a made-up id (e.g. `demo-session`) makes
/// the adapter refuse the session and the demo renders no chat at all —
/// silently, since "no adapter resolved" is not an error. Guarded by
/// `demo_backend_test.dart`.
const _sessionId = '01988e5a-0c1d-7a3f-9b2e-4d6c8f0a1b23';
const _cwd = '/home/demo/drover-demo';

/// Where the demo's native transcript "lives", answered for herdr's `find`
/// probe the same way [nativeTranscriptPath] is in previews.
const demoTranscriptPath =
    '/home/demo/.claude/projects/-home-demo-drover-demo/$_sessionId.jsonl';

const _toolUseId = 'toolu_demo_bash';

String _userLine(String text) => jsonEncode({
  'type': 'user',
  'message': {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
});

String _assistantTextLine(String text) => jsonEncode({
  'type': 'assistant',
  'message': {
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
});

String _toolResultLine() => jsonEncode({
  'type': 'user',
  'message': {
    'role': 'user',
    'content': [
      {
        'type': 'tool_result',
        'tool_use_id': _toolUseId,
        'content': 'spike-test.txt created.',
      },
    ],
  },
});

final _initialTranscript =
    '${[
      _userLine('Can you set up a quick test file so I can see how this works?'),
      jsonEncode({
        'type': 'assistant',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'thinking', 'thinking': "I'll create an empty file with touch."},
            {
              'type': 'tool_use',
              'id': _toolUseId,
              'name': 'Bash',
              'input': {'command': 'touch spike-test.txt', 'description': 'Create empty file spike-test.txt'},
            },
          ],
        },
      }),
    ].join('\n')}\n';

const _reply1 =
    "Done — I've created spike-test.txt. Want me to add something to it, "
    'or ask me anything else?';
const _reply2 =
    "Happy to help with that too — in a real session I'd go read the "
    "relevant files and make the change. This demo's script ends here, "
    'though.';

/// Trailing pane-text lines for the Claude Code mode indicator, one per
/// cycle stop — the same wording [ClaudeModeCapability] parses in the real
/// app. Cycling starts at "auto" to match the idle preview scenario.
const _modeLines = <String>[
  '-- INSERT -- ⏵⏵ auto mode on (shift+tab to cycle)',
  '-- INSERT -- ⏵⏵ accept edits on (shift+tab to cycle)',
  '-- INSERT -- ⏵⏵ bypass permissions on (shift+tab to cycle)',
  '⏸ plan mode on (shift+tab to cycle)',
  '-- INSERT -- manual mode on (shift+tab to cycle)',
];

/// How many `agent list` polls the fake stays "working" before its canned
/// reply lands.
const _workingTicks = 2;

enum _Phase { blockedPrompt, working1, idle1, working2, idle2 }

/// A small stateful fake standing in for a real Herdr host during drover's
/// demo mode: a mutable transcript, an agent status, and a mode index, all
/// advanced by command dispatch rather than wall-clock time. Notifies
/// listeners on every phase change, so [DemoScreen] can react when
/// [isComplete] flips without polling on its own.
class DemoBackend extends ChangeNotifier {
  DemoBackend() : _files = {demoTranscriptPath: _initialTranscript};

  final Map<String, String> _files;
  _Phase _phase = _Phase.blockedPrompt;
  int _ticksRemaining = 0;
  int _modeIndex = 0;

  /// True once the scripted session has landed its second (follow-up) reply.
  bool get isComplete => _phase == _Phase.idle2;

  HerdrClient buildClient() =>
      HerdrClient(StubCommandRunner(_respond, files: _files));

  String get _statusName => switch (_phase) {
    _Phase.blockedPrompt => 'blocked',
    _Phase.working1 || _Phase.working2 => 'working',
    _Phase.idle1 || _Phase.idle2 => 'idle',
  };

  String get _liveText {
    if (_phase == _Phase.blockedPrompt) return blockedPromptText;
    final status = _phase == _Phase.working1 || _phase == _Phase.working2
        ? 'Working on the task…'
        : 'Idle.';
    return '$status\n${_modeLines[_modeIndex]}\n';
  }

  String _agentListEnvelope() =>
      '{"id":"1","result":{"agents":[{"agent":"claude",'
      '"agent_status":"$_statusName","cwd":"$_cwd","focused":false,'
      '"pane_id":"$demoPaneId","tab_id":"$demoTabId",'
      '"workspace_id":"$demoWorkspaceId",'
      '"terminal_title_stripped":"Set up a demo file",'
      '"agent_session":{"source":"claude","agent":"claude","kind":"id",'
      '"value":"$_sessionId"}}]}}';

  CommandResult _respond(String command) {
    if (command.contains("'--version'")) {
      return versionResponse(_demoHerdrVersion);
    }
    if (command.startsWith('command find ')) {
      return ok('$demoTranscriptPath\n');
    }
    if (command.contains("'workspace' 'list'")) {
      return ok(
        '{"id":"1","result":{"workspaces":['
        '{"workspace_id":"$demoWorkspaceId","label":"drover demo"}]}}',
      );
    }
    if (command.contains("'agent' 'list'")) {
      final result = ok(_agentListEnvelope());
      _onAgentListTick();
      return result;
    }
    if (command.contains("'agent' 'read'")) return ok(_liveText);
    if (command.contains("'agent' 'prompt'")) {
      _onPrompt(_promptText(command));
      return ok('{"id":"1","result":{}}');
    }
    // The mode-cycle escape sequence is a fixed literal, so a direct suffix
    // check is enough — no need to parse it out of the command line.
    if (command.endsWith("'[Z'")) {
      _modeIndex = (_modeIndex + 1) % _modeLines.length;
      notifyListeners();
    }
    return ok('{"id":"1","result":{}}');
  }

  /// One `agent list` call is one tick: while "working", ticks count down to
  /// the canned reply landing. Deliberately NOT a [Timer] — see the file
  /// comment.
  void _onAgentListTick() {
    if (_phase != _Phase.working1 && _phase != _Phase.working2) return;
    _ticksRemaining--;
    if (_ticksRemaining > 0) return;
    _appendTranscript(
      _assistantTextLine(_phase == _Phase.working1 ? _reply1 : _reply2),
    );
    _phase = _phase == _Phase.working1 ? _Phase.idle1 : _Phase.idle2;
    notifyListeners();
  }

  /// Both answering the permission prompt and sending a follow-up go through
  /// herdr's `agent prompt` — the same command a real Claude Code pane sees
  /// for a numbered-option answer and free-text input alike. Which one this
  /// is comes entirely from the current phase, not [text]'s shape.
  void _onPrompt(String text) {
    switch (_phase) {
      case _Phase.blockedPrompt:
        _appendTranscript(_toolResultLine());
        _phase = _Phase.working1;
        _ticksRemaining = _workingTicks;
        notifyListeners();
      case _Phase.idle1:
        _appendTranscript(_userLine(text));
        _phase = _Phase.working2;
        _ticksRemaining = _workingTicks;
        notifyListeners();
      case _Phase.working1:
      case _Phase.working2:
      case _Phase.idle2:
      // Mid-flight or already finished: no-op.
    }
  }

  void _appendTranscript(String line) {
    _files[demoTranscriptPath] = '${_files[demoTranscriptPath]}$line\n';
  }
}

/// Extracts the free-text argument from an `agent prompt <paneId> <text>`
/// command line built by [buildHerdrCommand], reversing [shQuote]'s `'\''`
/// escaping for embedded quotes. Anchored on the command's known, fixed
/// prefix rather than scanning for the last `' '` argument boundary: the
/// user's own follow-up text can itself contain a `' '`-shaped run (e.g. two
/// quoted words separated by a space, like `check 'a' or 'b'`), which would
/// make a generic reverse scan find a boundary inside the text instead of
/// before it.
String _promptText(String command) {
  final prefix = "'agent' 'prompt' '$demoPaneId' '";
  final start = command.indexOf(prefix) + prefix.length;
  return command.substring(start, command.length - 1).replaceAll("'\\''", "'");
}
