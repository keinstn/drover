// GitHub Copilot CLI's native transcript source: parses the user-visible
// portion of its session `events.jsonl` format into the shared
// `TranscriptEntry` model, and incrementally loads it from the exact session
// file herdr's `agent_session` reports.
//
// Live-observed on Copilot CLI 1.0.72 (see docs/herdr-notes.md): each line is
// one JSON event `{type, data, id, timestamp, parentId, agentId?}`. Only four
// event types carry user-visible content —
// `user.message` (`data.content`, plus attachment metadata this parser does
// not render), `assistant.message` (`data.content` with `data.phase` —
// visible when `final_answer` or `commentary`; the intermediate `null`
// phase's content is opaque/encrypted reasoning and is never rendered even
// if non-empty), `tool.execution_start`
// (`data.{toolCallId, toolName, arguments}`), and `tool.execution_complete`
// (`data.{toolCallId, success, result}`, paired to its start by
// `toolCallId`). Every other event type (hooks, session lifecycle, usage,
// etc.) is noise and is skipped. Tool events reuse the same
// `TranscriptToolUse`/`TranscriptToolResult` shapes Claude Code's parser
// produces so a later ask_user detector can work across agents.

import 'dart:convert';

import '../../herdr/command_runner.dart';
import '../../models/agent_info.dart';
import '../../transcript/native_transcript.dart';

/// Parses the user-visible portion of Copilot CLI's JSONL session event
/// format.
class CopilotTranscriptParser {
  const CopilotTranscriptParser();

  List<TranscriptEntry> parseLines(String input) {
    final entries = <TranscriptEntry>[];
    for (final line in const LineSplitter().convert(input)) {
      entries.addAll(parseLine(line));
    }
    return entries;
  }

  List<TranscriptEntry> parseLine(String line) {
    try {
      final record = jsonDecode(line);
      if (record is! Map<String, dynamic>) return const [];
      final data = record['data'];
      if (data is! Map<String, dynamic>) return const [];
      return switch (record['type']) {
        'user.message' => _message(TranscriptSpeaker.user, data['content']),
        'assistant.message' => _assistantMessage(data),
        'tool.execution_start' => _toolUse(data),
        'tool.execution_complete' => _toolResult(data),
        // Hook/session-lifecycle/usage/etc. events are not user-visible
        // transcript content.
        _ => const [],
      };
    } on FormatException {
      return const [];
    }
  }

  List<TranscriptEntry> _assistantMessage(Map<String, dynamic> data) {
    final phase = data['phase'];
    // The intermediate (null) phase's content is opaque/encrypted reasoning
    // and must never be rendered, regardless of whether it looks non-empty.
    if (phase != 'final_answer' && phase != 'commentary') return const [];
    return _message(TranscriptSpeaker.assistant, data['content']);
  }

  List<TranscriptEntry> _message(TranscriptSpeaker speaker, dynamic content) {
    if (content is! String) return const [];
    final text = content.trim();
    return text.isEmpty
        ? const []
        : [TranscriptMessage(speaker: speaker, text: text)];
  }

  List<TranscriptEntry> _toolUse(Map<String, dynamic> data) {
    final toolCallId = data['toolCallId'];
    final toolName = data['toolName'];
    if (toolCallId is! String || toolName is! String) return const [];
    final arguments = data['arguments'];
    return [
      TranscriptToolUse(
        name: toolName,
        input: arguments is Map<String, dynamic> ? arguments : const {},
        id: toolCallId,
      ),
    ];
  }

  List<TranscriptEntry> _toolResult(Map<String, dynamic> data) {
    final toolCallId = data['toolCallId'];
    return toolCallId is String ? [TranscriptToolResult(toolCallId)] : const [];
  }
}

/// Loads Copilot CLI's exact, herdr-reported session's `events.jsonl` and
/// caches its parsed prefix. A poll transfers only bytes appended since the
/// last read.
class CopilotTranscriptLoader implements NativeTranscriptAdapter {
  CopilotTranscriptLoader(this._runner, {CopilotTranscriptParser? parser})
    : _parser = parser ?? const CopilotTranscriptParser();

  static final _copilotSessionId = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  final CommandRunner _runner;
  final CopilotTranscriptParser _parser;
  String? _sessionId;
  String? _path;
  var _size = 0;
  var _remainder = '';
  var _remainderParsed = false;
  final _entries = <TranscriptEntry>[];

  static bool supportsAgent(AgentInfo agent) {
    final session = agent.agentSession;
    return agent.agent == 'copilot' &&
        session?.agent == 'copilot' &&
        session?.kind == 'id' &&
        session != null &&
        _copilotSessionId.hasMatch(session.value);
  }

  @override
  Future<NativeTranscript?> load(AgentInfo agent) async {
    if (!supportsAgent(agent)) {
      return null;
    }
    final id = agent.agentSession!.value;
    if (_sessionId != id) {
      _reset(id);
    }
    final path = _path ?? await _locate(id);
    if (path == null) {
      return null;
    }
    _path = path;
    final stat = await _runner.statFile(path);
    if (stat.size < _size) {
      _resetIncrementalState();
    }
    if (stat.size == _size) {
      return NativeTranscript(List.unmodifiable(_entries));
    }

    final bytes = await _runner.readFile(path, offset: _size);
    _size += bytes.length;
    final appended = utf8.decode(bytes, allowMalformed: true);
    final completesParsedRemainder =
        _remainderParsed && appended.startsWith('\n');
    if (completesParsedRemainder) {
      _remainder = '';
      _remainderParsed = false;
    }
    final input = completesParsedRemainder
        ? appended.substring(1)
        : '$_remainder$appended';
    final lastNewline = input.lastIndexOf('\n');
    if (lastNewline < 0) {
      _remainder = input;
      final entries = _parser.parseLine(input);
      if (entries.isNotEmpty && !_remainderParsed) {
        _entries.addAll(entries);
        _remainderParsed = true;
      }
    } else {
      _entries.addAll(_parser.parseLines(input.substring(0, lastNewline)));
      _remainder = input.substring(lastNewline + 1);
      _remainderParsed = false;
      final entries = _parser.parseLine(_remainder);
      if (entries.isNotEmpty) {
        _entries.addAll(entries);
        _remainderParsed = true;
      }
    }
    return NativeTranscript(List.unmodifiable(_entries));
  }

  void _reset(String id) {
    _sessionId = id;
    _path = null;
    _resetIncrementalState();
  }

  void _resetIncrementalState() {
    _size = 0;
    _remainder = '';
    _remainderParsed = false;
    _entries.clear();
  }

  Future<String?> _locate(String sessionId) async {
    // [supportsAgent] validated the id above (hex digits and hyphens only),
    // so it is safe to interpolate directly. Unlike Claude Code's
    // per-project session layout, Copilot's session path is fully
    // deterministic from the id alone
    // (`${COPILOT_HOME:-$HOME/.copilot}/session-state/<id>/events.jsonl`),
    // so no broad `find` traversal of $HOME is needed — only the exact
    // candidate path is tested for existence, honoring COPILOT_HOME when the
    // host sets it. A missing session directory/file (normal before the
    // session's first turn) yields empty stdout and exit 0 rather than an
    // error, since the `if` has no `else` branch.
    final result = await _runner.run(
      'p="\${COPILOT_HOME:-\$HOME/.copilot}/session-state/$sessionId/events.jsonl"; '
      'if [ -f "\$p" ]; then command printf "%s" "\$p"; fi',
    );
    if (result.exitCode != 0) {
      throw StateError('Unable to locate Copilot transcript: ${result.stderr}');
    }
    final path = result.stdout;
    if (path.isEmpty) {
      return null;
    }
    if (!path.startsWith('/') ||
        path.split('/').contains('..') ||
        !path.endsWith('/session-state/$sessionId/events.jsonl')) {
      throw StateError('Copilot transcript path was not found');
    }
    return path;
  }
}
