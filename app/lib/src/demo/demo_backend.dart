// The stateful fake behind drover's demo mode: a scripted Claude Code session
// (permission prompt -> answer -> reply -> follow-up -> reply) driven by
// command-invocation counts rather than a Timer, so it stays deterministic
// under `flutter test`. Two further, non-interactive agents round out the herd
// so its status pills carry real values.
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../herdr/command_runner.dart';
import '../herdr/herdr_client.dart';
import 'demo_content.dart';
import 'demo_content_en.dart';
import 'demo_herdr.dart';

/// Identity of the demo's synthetic host and its scripted agent — never
/// persisted, never a real [HostConfig].
const demoHostId = 'demo';
const demoPaneId = 'demo:p1';
const demoWorkspaceId = 'demo:w1';
const demoTabId = 'demo:t1';

/// The two agents that exist only to give the herd screen a realistic spread
/// of statuses. They are not interactive: opening one shows a plain live
/// terminal with no composer (see [DemoScreen]'s `showComposerFor`), and
/// nothing they receive advances the script.
///
/// One tab each, not three panes sharing [demoTabId]: three agents in one tab
/// is a split tab with two backgrounded panes, which is a herdr configuration
/// that drops keystrokes — incoherent data to put in a screen whose job is to
/// look like a real herd.
const demoReviewPaneId = 'demo:p2';
const demoDocsPaneId = 'demo:p3';
const _reviewTabId = 'demo:t2';
const _docsTabId = 'demo:t3';

const _demoHerdrVersion = '0.7.5';

/// The demo session's identity, reported as the agent's `agent_session` value.
/// Must be a real UUID: every native-transcript loader gates on
/// `isNativeTranscriptSessionId`, so a made-up id (e.g. `demo-session`) makes
/// the adapter refuse the session and the demo renders no chat at all —
/// silently, since "no adapter resolved" is not an error. Guarded by
/// `demo_backend_test.dart`.
const _sessionId = '01988e5a-0c1d-7a3f-9b2e-4d6c8f0a1b23';
const _cwd = '/home/demo/drover-demo';
const _reviewCwd = '/home/demo/billing-api';
const _docsCwd = '/home/demo/drover-demo';

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

/// The turn the demo opens on: the assistant thinks, then asks to run a Bash
/// command — the tool call the permission prompt is still waiting on. The tool
/// name and the command itself are what the CLI emits, so they stay English in
/// every locale (see `demo_content.dart`).
String _blockedToolUseLine(DemoContent content) => jsonEncode({
  'type': 'assistant',
  'message': {
    'role': 'assistant',
    'content': [
      {'type': 'thinking', 'thinking': content.thinking},
      {
        'type': 'tool_use',
        'id': _toolUseId,
        'name': 'Bash',
        'input': {
          'command': 'touch spike-test.txt',
          'description': 'Create empty file spike-test.txt',
        },
      },
    ],
  },
});

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

/// Live pane text for the two non-interactive agents. CLI output, therefore
/// English in every locale — and deliberately without a mode indicator line:
/// [_modeLines] is Claude Code's wording, which a codex or copilot pane never
/// emits, so echoing it here would be both implausible and something the
/// per-agent mode capability could misread.
const _reviewLiveText = 'Reading src/webhooks/billing.ts…\n';
const _docsLiveText = 'Idle.\n';

/// How many `agent list` polls the fake stays "working" before its canned
/// reply lands.
const _workingTicks = 2;

enum _Phase { blockedPrompt, working1, idle1, working2, idle2 }

/// A small stateful fake standing in for a real Herdr host during drover's
/// demo mode: a mutable transcript, an agent status, and a mode index, all
/// advanced by command dispatch rather than wall-clock time. Notifies
/// listeners on every phase change, so [DemoScreen] can react when
/// [isComplete] flips without polling on its own.
///
/// [content] is fixed for the lifetime of the session, deliberately. Rewriting
/// the transcript file in another language mid-session would change bytes the
/// reader has already consumed, and `JsonlTranscriptWindow` only handles
/// append-or-truncate — a same-path rewrite that happened to grow would splice
/// the new tail onto the old head. It is also the honest behaviour: drover
/// does not translate a real transcript either, so a demo session simply stays
/// in the language it was started in.
class DemoBackend extends ChangeNotifier {
  DemoBackend({this.content = demoContentEn}) {
    _writeTranscript();
  }

  final DemoContent content;

  final _files = <String, String>{};
  _Phase _phase = _Phase.blockedPrompt;
  int _ticksRemaining = 0;
  int _modeIndex = 0;

  /// The user's own follow-up text, once they have sent one — echoed back into
  /// the transcript verbatim.
  String? _followUp;

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

  /// Writes the whole transcript for the current phase, rather than appending
  /// to it — so the file stays a pure function of (content, phase, follow-up)
  /// and the script has one obvious reading order. Every phase only ever
  /// *adds* records, so successive writes are still a strict append as far as
  /// `JsonlTranscriptWindow` is concerned.
  void _writeTranscript() {
    final lines = <String>[
      _userLine(content.userTour),
      _assistantTextLine(content.assistantTour),
      _userLine(content.userSetup),
      _blockedToolUseLine(content),
      if (_phase != _Phase.blockedPrompt) _toolResultLine(),
      if (_phase != _Phase.blockedPrompt && _phase != _Phase.working1)
        _assistantTextLine(content.reply1),
      if (_followUp != null) _userLine(_followUp!),
      if (_phase == _Phase.idle2) _assistantTextLine(content.reply2),
    ];
    _files[demoTranscriptPath] = '${lines.join('\n')}\n';
  }

  String _agentJson({
    required String agent,
    required String status,
    required String paneId,
    required String tabId,
    required String cwd,
    required String title,
    String? sessionId,
  }) {
    final session = sessionId == null
        ? ''
        : ',"agent_session":{"source":"claude","agent":"claude","kind":"id",'
              '"value":"$sessionId"}';
    return '{"agent":"$agent","agent_status":"$status","cwd":"$cwd",'
        '"focused":false,"pane_id":"$paneId","tab_id":"$tabId",'
        '"workspace_id":"$demoWorkspaceId",'
        '"terminal_title_stripped":${jsonEncode(title)}$session}';
  }

  String _agentListEnvelope() {
    final agents = [
      _agentJson(
        agent: 'claude',
        status: _statusName,
        paneId: demoPaneId,
        tabId: demoTabId,
        cwd: _cwd,
        title: content.scriptedTitle,
        sessionId: _sessionId,
      ),
      _agentJson(
        agent: 'codex',
        status: 'working',
        paneId: demoReviewPaneId,
        tabId: _reviewTabId,
        cwd: _reviewCwd,
        title: content.reviewTitle,
      ),
      _agentJson(
        agent: 'copilot',
        status: 'idle',
        paneId: demoDocsPaneId,
        tabId: _docsTabId,
        cwd: _docsCwd,
        title: content.docsTitle,
      ),
    ];
    return '{"id":"1","result":{"agents":[${agents.join(',')}]}}';
  }

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
    // Every branch below is gated on the pane id: the two non-interactive
    // agents share this responder and must neither be shown the scripted
    // pane's live text nor be able to advance its script.
    if (command.contains("'agent' 'read' '$demoPaneId'")) return ok(_liveText);
    if (command.contains("'agent' 'read' '$demoReviewPaneId'")) {
      return ok(_reviewLiveText);
    }
    if (command.contains("'agent' 'read' '$demoDocsPaneId'")) {
      return ok(_docsLiveText);
    }
    if (command.contains(_promptPrefix)) {
      _onPrompt(_promptText(command));
      return ok('{"id":"1","result":{}}');
    }
    // The mode-cycle escape sequence is a fixed literal (backtab, ESC [ Z
    // — see `ClaudeModeCapability`), so a direct suffix check is enough.
    // Spelled as a `\u001b` escape rather than a raw ESC byte so it stays
    // visible in a diff.
    if (command.contains("'pane' 'send-text' '$demoPaneId'") &&
        command.endsWith("'\u001b[Z'")) {
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
    _phase = _phase == _Phase.working1 ? _Phase.idle1 : _Phase.idle2;
    _writeTranscript();
    notifyListeners();
  }

  /// Both answering the permission prompt and sending a follow-up go through
  /// herdr's `agent prompt` — the same command a real Claude Code pane sees
  /// for a numbered-option answer and free-text input alike. Which one this
  /// is comes entirely from the current phase, not [text]'s shape.
  void _onPrompt(String text) {
    switch (_phase) {
      case _Phase.blockedPrompt:
        _phase = _Phase.working1;
        _ticksRemaining = _workingTicks;
        _writeTranscript();
        notifyListeners();
      case _Phase.idle1:
        _followUp = text;
        _phase = _Phase.working2;
        _ticksRemaining = _workingTicks;
        _writeTranscript();
        notifyListeners();
      case _Phase.working1:
      case _Phase.working2:
      case _Phase.idle2:
      // Mid-flight or already finished: no-op.
    }
  }
}

/// The fixed prefix of an `agent prompt` command line aimed at the scripted
/// pane. Doubles as the pane gate in [DemoBackend._respond]: a prompt sent to
/// any other pane never reaches [_promptText].
const _promptPrefix = "'agent' 'prompt' '$demoPaneId' '";

/// Extracts the free-text argument from an `agent prompt <paneId> <text>`
/// command line built by [buildHerdrCommand], reversing [shQuote]'s `'\''`
/// escaping for embedded quotes. Anchored on the command's known, fixed
/// prefix rather than scanning for the last `' '` argument boundary: the
/// user's own follow-up text can itself contain a `' '`-shaped run (e.g. two
/// quoted words separated by a space, like `check 'a' or 'b'`), which would
/// make a generic reverse scan find a boundary inside the text instead of
/// before it.
String _promptText(String command) {
  final start = command.indexOf(_promptPrefix) + _promptPrefix.length;
  return command.substring(start, command.length - 1).replaceAll("'\\''", "'");
}
