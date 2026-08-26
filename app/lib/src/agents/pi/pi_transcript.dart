// pi's native transcript source: parses the user-visible portion of its
// JSONL session format into the shared `TranscriptEntry` model, and
// incrementally loads it from the session file herdr reports.
//
// Observed on pi 0.84.3 (herdr integration pi v8): each line is one JSON
// record with a top-level `type`. Only `type='message'` carries user-visible
// content; `custom` (e.g. customType='web-search-results'), `model_change`,
// `session` and `thinking_level_change` records are noise and are skipped.
//
// A message record nests its payload under `message`, keyed by `role`:
//   - role='user' / 'assistant' → a `content` array of blocks:
//       {type:'text', text}              → TranscriptMessage
//       {type:'thinking', thinking}      → TranscriptThinking (assistant)
//       {type:'toolCall', id, name,
//        arguments}                      → TranscriptToolUse. Unlike Codex's
//         `function_call.arguments`, pi's `arguments` is already a decoded
//         JSON object, so it is used as-is.
//     One assistant message can carry several blocks in any combination
//     (e.g. thinking,toolCall,toolCall), so every block is walked in order.
//   - role='toolResult' → its OWN top-level record (unlike Claude/Codex,
//     which nest results in a following user record), carrying `toolCallId`
//     plus `toolName`/`isError`/`content`. Only the id maps onto the shared
//     model, so the rest is dropped rather than widening that model. A
//     toolResult's content may also include image blocks; those are ignored.
//   - role='bashExecution' — a user-run `!command` shell escape carrying
//     {command, output} instead of a `content` array — is out of scope for
//     this phase and skipped.
//
// Unlike the other three agents, herdr reports pi's session as
// `kind:'path'`: the session value IS the absolute transcript path, so there
// is no remote lookup to perform — only validation of that path.

import 'dart:convert';

import '../../herdr/command_runner.dart';
import '../../models/agent_info.dart';
import '../../transcript/native_transcript.dart';

/// Parses the user-visible portion of pi's JSONL session format.
class PiTranscriptParser {
  const PiTranscriptParser();

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
      if (record['type'] != 'message') return const [];
      final message = record['message'];
      if (message is! Map<String, dynamic>) return const [];
      return switch (message['role']) {
        'user' => _content(message, TranscriptSpeaker.user),
        'assistant' => _content(message, TranscriptSpeaker.assistant),
        'toolResult' => _toolResult(message),
        // 'bashExecution' (a user-run `!command`) is deliberately out of
        // scope, as is any role pi may add later.
        _ => const [],
      };
    } on FormatException {
      return const [];
    }
  }

  /// Walks a message's content blocks in order, emitting one entry per
  /// user-visible block. An empty (or missing) `content` array yields
  /// nothing. Unlike Claude's parser this does not merge adjacent text
  /// blocks into one message — pi has not been observed emitting two
  /// adjacent text blocks, so the buffering that would need isn't earned.
  List<TranscriptEntry> _content(
    Map<String, dynamic> message,
    TranscriptSpeaker speaker,
  ) {
    final blocks = message['content'];
    if (blocks is! List) return const [];
    final entries = <TranscriptEntry>[];
    for (final block in blocks.whereType<Map<String, dynamic>>()) {
      switch (block['type']) {
        case 'text':
          final text = block['text'];
          if (text is String) {
            final trimmed = text.trim();
            if (trimmed.isNotEmpty) {
              entries.add(TranscriptMessage(speaker: speaker, text: trimmed));
            }
          }
        case 'thinking':
          final thinking = block['thinking'];
          if (thinking is String && thinking.isNotEmpty) {
            entries.add(TranscriptThinking(thinking));
          }
        case 'toolCall':
          final name = block['name'];
          if (name is String) {
            // `arguments` arrives already decoded, so it needs no jsonDecode.
            final arguments = block['arguments'];
            final id = block['id'];
            entries.add(
              TranscriptToolUse(
                name: name,
                input: arguments is Map<String, dynamic> ? arguments : const {},
                id: id is String ? id : null,
              ),
            );
          }
        // Any other block type (e.g. an image in a toolResult) is ignored.
      }
    }
    return entries;
  }

  List<TranscriptEntry> _toolResult(Map<String, dynamic> message) {
    final callId = message['toolCallId'];
    return callId is String ? [TranscriptToolResult(callId)] : const [];
  }
}

/// True when [path] is safe to read as a pi transcript. The value crosses a
/// trust boundary — it comes from the host's herdr integration and is fed
/// straight into a remote stat/read — so it must be an absolute POSIX path,
/// free of any `..` traversal segment, and named like a JSONL session file.
/// A Windows host never reaches here: pi's integration only reports a path
/// when it starts with `/`, so it falls back to reporting a session id there
/// and [PiTranscriptLoader.supportsAgent] rejects the `kind:'id'` session
/// (see `docs/agents/pi-notes.md`).
bool _isSafeTranscriptPath(String path) =>
    path.startsWith('/') &&
    !path.split('/').contains('..') &&
    path.endsWith('.jsonl');

/// Loads pi's herdr-reported session file and caches its parsed prefix. The
/// very first load of a large file fetches only a bounded tail (see
/// `nativeTranscriptWindowBytes`); a poll thereafter transfers only bytes
/// appended since the last read, and [loadOlder] fetches earlier bounded
/// chunks on demand. Session/path/window orchestration is delegated to
/// [JsonlSessionLoader]; only pi-specific session validation and JSONL
/// parsing remain here.
///
/// Because herdr reports pi's session as `kind:'path'`, this loader needs no
/// [HostPlatform] and issues no lookup command at all — unlike the Claude,
/// Codex and Copilot loaders, which each have to find their session file.
class PiTranscriptLoader implements NativeTranscriptAdapter {
  PiTranscriptLoader(
    this._runner, {
    PiTranscriptParser? parser,
    JsonlTranscriptWindow? window,
  }) : _parser = parser ?? const PiTranscriptParser(),
       _loader = JsonlSessionLoader(window: window);

  final CommandRunner _runner;
  final PiTranscriptParser _parser;
  final JsonlSessionLoader _loader;

  static bool supportsAgent(AgentInfo agent) {
    final session = agent.agentSession;
    return agent.agent == 'pi' &&
        session != null &&
        session.agent == 'pi' &&
        session.kind == 'path' &&
        _isSafeTranscriptPath(session.value);
  }

  @override
  Future<NativeTranscript?> load(AgentInfo agent) {
    if (!supportsAgent(agent)) return Future.value(null);
    final path = agent.agentSession!.value;
    return _loader.load(
      sessionId: path,
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

  /// The session value already IS the transcript path, so "locating" it runs
  /// no lookup command — it validates the path and probes that it is actually
  /// readable. [supportsAgent] applies the same predicate before [load] gets
  /// here; re-checking keeps this safe for any future caller that reaches
  /// [JsonlSessionLoader.load] directly.
  ///
  /// The stat probe is what gives pi the same "not located yet" signal the
  /// other three loaders get for free from their lookup command: returning
  /// null makes [JsonlSessionLoader.load] return null, so AgentScreen falls
  /// back to pane-text history. Without it, an unreadable path (pruned or
  /// rotated sessions, a stale path from the integration, a file this SSH
  /// account cannot read) would instead surface as a retry banner re-armed on
  /// every poll. Only the first load per session pays for it — the resolved
  /// path is cached thereafter.
  ///
  /// ponytail: this catches every throw, not just "no such file", so a
  /// transport-level failure (a dropped connection, an auth error) also reads
  /// as "not located" and falls back silently, where Codex and Copilot would
  /// surface it — their lookup only returns null on an `exitCode == 0` command
  /// that found nothing. The ceiling is accepted because distinguishing the
  /// two means catching `SftpStatusError`, and `package:dartssh2` is confined
  /// to `infra/ssh_command_runner.dart` — the agents layer only knows the
  /// abstract [CommandRunner]. It is also self-limiting: the pane-text
  /// fallback reads over the same connection, so a genuine transport failure
  /// still surfaces through that path. Upgrade by giving [CommandRunner] an
  /// existence check that reports not-found distinctly from failure, if
  /// another `kind:'path'` agent ever needs the same probe.
  Future<String?> _locate(String sessionId) async {
    if (!_isSafeTranscriptPath(sessionId)) return null;
    try {
      await _runner.statFile(sessionId);
    } catch (_) {
      return null;
    }
    return sessionId;
  }
}
