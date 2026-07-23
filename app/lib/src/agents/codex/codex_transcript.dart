// Codex CLI's native transcript source: parses the user-visible portion of
// its JSONL session format into the shared `TranscriptEntry` model, and
// incrementally loads it from the exact session file herdr reports.
//
// Observed on Codex CLI 0.144.6: each line is one JSON record
// `{timestamp, type, payload, ...}`. User and assistant chat messages come
// from type='event_msg' with payload.type='user_message' or 'agent_message'.
// Tool invocations and results all come from type='response_item':
//   - payload.type='function_call' or 'custom_tool_call' → tool use
//   - payload.type='function_call_output' or 'custom_tool_call_output'
//     → tool result, with the matching call id at payload.call_id
// All other records (reasoning, lifecycle, token/world-state, response_item
// message with role='assistant', etc.) are noise and are skipped.
// response_item payload.type='message' (role assistant) records are
// explicitly skipped to avoid duplicating the text already emitted by the
// corresponding event_msg record.

import 'dart:convert';

import '../../herdr/command_runner.dart';
import '../../herdr/host_platform.dart';
import '../../models/agent_info.dart';
import '../../transcript/native_transcript.dart';

/// Parses the user-visible portion of Codex CLI's JSONL session format.
class CodexTranscriptParser {
  const CodexTranscriptParser();

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
      return switch (record['type']) {
        'event_msg' => _eventMsg(record['payload']),
        'response_item' => _responseItem(record['payload']),
        _ => const [],
      };
    } on FormatException {
      return const [];
    }
  }

  List<TranscriptEntry> _eventMsg(dynamic payload) {
    if (payload is! Map<String, dynamic>) return const [];
    final message = payload['message'];
    if (message is! String) return const [];
    return switch (payload['type']) {
      'user_message' => _message(TranscriptSpeaker.user, message),
      'agent_message' => _message(TranscriptSpeaker.assistant, message),
      _ => const [],
    };
  }

  List<TranscriptEntry> _message(TranscriptSpeaker speaker, String text) {
    final trimmed = text.trim();
    return trimmed.isEmpty
        ? const []
        : [TranscriptMessage(speaker: speaker, text: trimmed)];
  }

  List<TranscriptEntry> _responseItem(dynamic payload) {
    if (payload is! Map<String, dynamic>) return const [];
    return switch (payload['type']) {
      'function_call' => _functionCall(payload),
      'custom_tool_call' => _customToolCall(payload),
      'function_call_output' => _toolResult(payload),
      'custom_tool_call_output' => _toolResult(payload),
      // payload.type='message' (role assistant) would duplicate the text from
      // the event_msg record.
      _ => const [],
    };
  }

  List<TranscriptEntry> _functionCall(Map<String, dynamic> payload) {
    final name = payload['name'];
    if (name is! String) return const [];
    final callId = payload['call_id'];
    final rawArgs = payload['arguments'];
    Map<String, dynamic>? parsedInput;
    if (rawArgs is String) {
      try {
        final decoded = jsonDecode(rawArgs);
        if (decoded is Map<String, dynamic>) parsedInput = decoded;
      } on FormatException {
        // malformed JSON → parsedInput stays null → empty map below
      }
    }
    return [
      TranscriptToolUse(
        name: name,
        input: parsedInput ?? const {},
        id: callId is String ? callId : null,
      ),
    ];
  }

  List<TranscriptEntry> _customToolCall(Map<String, dynamic> payload) {
    final name = payload['name'];
    if (name is! String) return const [];
    final callId = payload['call_id'];
    final inputStr = payload['input'];
    final input = inputStr is String
        ? <String, dynamic>{'input': inputStr}
        : const <String, dynamic>{};
    return [
      TranscriptToolUse(
        name: name,
        input: input,
        id: callId is String ? callId : null,
      ),
    ];
  }

  List<TranscriptEntry> _toolResult(Map<String, dynamic> payload) {
    final callId = payload['call_id'];
    return callId is String ? [TranscriptToolResult(callId)] : const [];
  }
}

/// Loads Codex CLI's exact, herdr-reported session file and caches its parsed
/// prefix. The very first load of a large file fetches only a bounded tail
/// (see `nativeTranscriptWindowBytes`); a poll thereafter transfers only
/// bytes appended since the last read, and [loadOlder] fetches earlier
/// bounded chunks on demand. Session/path/window orchestration is delegated
/// to [JsonlSessionLoader]; only Codex-specific session validation, path
/// location, and JSONL parsing remain here.
class CodexTranscriptLoader implements NativeTranscriptAdapter {
  CodexTranscriptLoader(
    this._runner, {
    CodexTranscriptParser? parser,
    JsonlTranscriptWindow? window,
    this._platform = const UnixHostPlatform(),
  }) : _parser = parser ?? const CodexTranscriptParser(),
       _loader = JsonlSessionLoader(window: window);

  final CommandRunner _runner;
  final CodexTranscriptParser _parser;
  final JsonlSessionLoader _loader;
  final HostPlatform _platform;

  static bool supportsAgent(AgentInfo agent) {
    final session = agent.agentSession;
    return agent.agent == 'codex' &&
        session != null &&
        session.agent == 'codex' &&
        session.kind == 'id' &&
        isNativeTranscriptSessionId(session.value);
  }

  @override
  Future<NativeTranscript?> load(AgentInfo agent) {
    if (!supportsAgent(agent)) return Future.value(null);
    final id = agent.agentSession!.value;
    return _loader.load(
      sessionId: id,
      locate: _locate,
      statSize: (path) async => (await _runner.statFile(path)).size,
      readRange: (path, offset, length) =>
          _runner.readFile(path, offset: offset, length: length),
      parseLines: _parser.parseLines,
      parseLine: _parser.parseLine,
    );
  }

  @override
  bool get hasOlderHistory => _loader.hasOlderHistory;

  @override
  Future<NativeTranscript?> loadOlder(AgentInfo agent) {
    return _loader.loadOlder(
      readRange: (path, offset, length) =>
          _runner.readFile(path, offset: offset, length: length),
      parseLines: _parser.parseLines,
    );
  }

  Future<String?> _locate(String sessionId) async {
    // [supportsAgent] validated the id above (UUID pattern: hex and hyphens
    // only). Session files live at:
    //   ${CODEX_HOME:-$HOME/.codex}/sessions/YYYY/MM/DD/rollout-*-<uuid>.jsonl
    // The date components are unknown, so we do a bounded search over the
    // three-level date hierarchy — exactly depth 4 relative to the sessions
    // root. Only the Codex sessions root is searched; no broad $HOME scan.
    // [HostPlatform] owns the OS-specific search command, honoring
    // CODEX_HOME when the host sets it.
    final result = await _runner.run(
      _platform.findFileAtDepthCommand(
        envVar: 'CODEX_HOME',
        homeFallback: '.codex',
        suffix: 'sessions',
        depth: 4,
        namePattern: 'rollout-*-$sessionId.jsonl',
      ),
    );
    if (result.exitCode != 0) {
      throw StateError('Unable to locate Codex transcript: ${result.stderr}');
    }
    final paths = result.stdout
        .split('\n')
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    if (paths.isEmpty) return null;
    if (paths.length != 1 ||
        !paths.single.startsWith('/') ||
        paths.single.split('/').contains('..') ||
        !paths.single.endsWith('-$sessionId.jsonl')) {
      throw StateError('Codex transcript was not found');
    }
    return paths.single;
  }
}
