// Claude Code's native transcript source: parses the user-visible portion of
// its JSONL session format into the shared `TranscriptEntry` model, and
// incrementally loads it from the exact session file herdr reports.

import 'dart:convert';

import '../../herdr/command_runner.dart';
import '../../models/agent_info.dart';
import '../../transcript/native_transcript.dart';

/// Parses the user-visible portion of Claude Code's JSONL session format.
class ClaudeTranscriptParser {
  const ClaudeTranscriptParser();

  static final _systemReminder = RegExp(
    r'<system-reminder>.*?</system-reminder>',
    dotAll: true,
  );
  static final _commandName = RegExp(r'<command-name>(.*?)</command-name>');
  static final _commandArgs = RegExp(r'<command-args>(.*?)</command-args>');

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
      final type = record['type'];
      final message = record['message'];
      if ((type != 'user' && type != 'assistant') ||
          record['isSidechain'] == true ||
          record['isMeta'] == true ||
          message is! Map<String, dynamic> ||
          message['role'] != type) {
        return const [];
      }
      final content = message['content'];
      if (type == 'assistant') {
        return switch (content) {
          String value => _assistantMessage(value),
          List<dynamic> blocks => _parseAssistantContent(blocks),
          _ => const [],
        };
      }
      // type == 'user': text is visible; tool_result blocks are hidden but
      // become markers so a pending AskUserQuestion can be detected.
      final blocks = content is List<dynamic>
          ? content.whereType<Map<String, dynamic>>()
          : const <Map<String, dynamic>>[];
      final toolResults = <TranscriptToolResult>[];
      for (final block in blocks) {
        if (block['type'] != 'tool_result') continue;
        final toolUseId = block['tool_use_id'];
        if (toolUseId is String) {
          toolResults.add(TranscriptToolResult(toolUseId));
        }
      }
      final text = switch (content) {
        String value => value,
        List<dynamic> _ =>
          blocks
              .where((block) => block['type'] == 'text')
              .map((block) => block['text'])
              .whereType<String>()
              .join(),
        _ => '',
      };
      if (text.isEmpty) return toolResults;
      final stripped = text.replaceAll(_systemReminder, '').trim();
      if (stripped.isEmpty) return toolResults;
      // Only anchor at the start: a prompt merely mentioning these tags
      // mid-text is not a genuine local-command/command record.
      if (stripped.startsWith('<local-command-stdout>') ||
          stripped.startsWith('<local-command-caveat>')) {
        return toolResults;
      }
      if (stripped.startsWith('<command-name>') ||
          stripped.startsWith('<command-message>')) {
        final commandName = _commandName.firstMatch(stripped);
        if (commandName != null) {
          final name = commandName.group(1)!;
          final args = _commandArgs.firstMatch(stripped)?.group(1);
          return [
            ...toolResults,
            TranscriptMessage(
              speaker: TranscriptSpeaker.user,
              text: (args != null && args.isNotEmpty) ? '$name $args' : name,
            ),
          ];
        }
      }
      return [
        ...toolResults,
        TranscriptMessage(speaker: TranscriptSpeaker.user, text: stripped),
      ];
    } on FormatException {
      return const [];
    }
  }

  List<TranscriptEntry> _assistantMessage(String text) {
    final message = _assistantTextEntry(text);
    return message == null ? const [] : [message];
  }

  TranscriptMessage? _assistantTextEntry(String text) {
    final stripped = text.replaceAll(_systemReminder, '').trim();
    return stripped.isEmpty
        ? null
        : TranscriptMessage(
            speaker: TranscriptSpeaker.assistant,
            text: stripped,
          );
  }

  /// Walks an assistant message's content blocks in order. Contiguous text
  /// blocks merge into one message; tool_use and thinking blocks become
  /// their own entries, breaking up the surrounding text runs.
  List<TranscriptEntry> _parseAssistantContent(List<dynamic> blocks) {
    final entries = <TranscriptEntry>[];
    final textBuffer = StringBuffer();
    void flushText() {
      if (textBuffer.isEmpty) return;
      final message = _assistantTextEntry(textBuffer.toString());
      textBuffer.clear();
      if (message != null) entries.add(message);
    }

    for (final block in blocks.whereType<Map<String, dynamic>>()) {
      switch (block['type']) {
        case 'text':
          final text = block['text'];
          if (text is String) textBuffer.write(text);
        case 'tool_use':
          flushText();
          final name = block['name'];
          if (name is String) {
            final input = block['input'];
            final id = block['id'];
            entries.add(
              TranscriptToolUse(
                name: name,
                input: input is Map<String, dynamic> ? input : const {},
                id: id is String ? id : null,
              ),
            );
          }
        case 'thinking':
          flushText();
          final thinking = block['thinking'];
          if (thinking is String && thinking.isNotEmpty) {
            entries.add(TranscriptThinking(thinking));
          }
      }
    }
    flushText();
    return entries;
  }
}

/// Loads Claude's exact, herdr-reported session file and caches its parsed
/// prefix. The very first load of a large file fetches only a bounded tail
/// (see `nativeTranscriptWindowBytes`); a poll thereafter transfers only
/// bytes appended since the last read, and [loadOlder] fetches earlier
/// bounded chunks on demand. Session/path/window orchestration is delegated
/// to [JsonlSessionLoader]; only Claude-specific session validation, path
/// location, and JSONL parsing remain here.
class ClaudeTranscriptLoader implements NativeTranscriptAdapter {
  ClaudeTranscriptLoader(
    this._runner, {
    ClaudeTranscriptParser? parser,
    JsonlTranscriptWindow? window,
  }) : _parser = parser ?? const ClaudeTranscriptParser(),
       _loader = JsonlSessionLoader(window: window);

  final CommandRunner _runner;
  final ClaudeTranscriptParser _parser;
  final JsonlSessionLoader _loader;

  static bool supportsAgent(AgentInfo agent) {
    final session = agent.agentSession;
    return agent.agent == 'claude' &&
        session?.agent == 'claude' &&
        session?.kind == 'id' &&
        session != null &&
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
    // The id is validated above; the only interpolated shell value remains
    // single-quoted. Limit the search to Claude's one-level project folders.
    final fileName = '$sessionId.jsonl';
    final result = await _runner.run(
      'command find "\$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -type f '
      '-name ${shQuote(fileName)} -print -quit',
    );
    if (result.exitCode != 0) {
      throw StateError('Unable to locate Claude transcript: ${result.stderr}');
    }
    final paths = result.stdout
        .split('\n')
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    if (paths.isEmpty) {
      return null;
    }
    if (paths.length != 1 ||
        !paths.single.startsWith('/') ||
        paths.single.split('/').contains('..') ||
        !paths.single.endsWith('/$fileName')) {
      throw StateError('Claude transcript was not found');
    }
    return paths.single;
  }
}
