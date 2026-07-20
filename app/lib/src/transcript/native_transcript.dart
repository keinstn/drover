import 'dart:convert';

import '../herdr/command_runner.dart';
import '../models/agent_info.dart';

enum TranscriptSpeaker { user, assistant }

/// One entry in a rendered transcript: a chat message, a tool invocation, or
/// a thinking block, in the order Claude produced them.
sealed class TranscriptEntry {
  const TranscriptEntry();
}

class TranscriptMessage extends TranscriptEntry {
  const TranscriptMessage({required this.speaker, required this.text});

  final TranscriptSpeaker speaker;
  final String text;
}

class TranscriptToolUse extends TranscriptEntry {
  const TranscriptToolUse({required this.name, required this.input});

  final String name;
  final Map<String, dynamic> input;
}

class TranscriptThinking extends TranscriptEntry {
  const TranscriptThinking(this.text);

  final String text;
}

/// The cap every [toolUseSummary] branch truncates its return value to, so a
/// huge or multi-line input can never grow the summary the UI keys and lays
/// out on every poll.
const _summaryMaxLength = 100;

/// A one-line summary for a tool_use entry, keyed by tool name. Every
/// accessor tolerates missing or wrong-shaped input rather than throwing, and
/// every return value is collapsed to its first line and length-capped.
String toolUseSummary(String name, Map<String, dynamic> input) {
  switch (name) {
    case 'Read':
    case 'Edit':
    case 'Write':
      return _summarize(input['file_path']);
    case 'Bash':
      return _summarize(input['command']);
    case 'Grep':
    case 'Glob':
      return _summarize(input['pattern']);
    case 'Task':
      return _summarize(input['description']);
    case 'WebFetch':
      return _summarize(input['url']);
    case 'WebSearch':
      return _summarize(input['query']);
    case 'AskUserQuestion':
      final questions = input['questions'];
      if (questions is List && questions.isNotEmpty) {
        final first = questions.first;
        if (first is Map) {
          return _summarize(first['question']);
        }
      }
      return '';
    default:
      for (final value in input.values) {
        if (value is String) return _summarize(value);
      }
      return '';
  }
}

String _summarize(dynamic value) =>
    _truncate(_firstLine(_asString(value)), _summaryMaxLength);

String _asString(dynamic value) => value is String ? value : '';

String _firstLine(String text) => text.split('\n').first;

String _truncate(String text, int maxLength) =>
    text.length <= maxLength ? text : '${text.substring(0, maxLength)}…';

class NativeTranscript {
  const NativeTranscript(this.entries);

  final List<TranscriptEntry> entries;

  /// Compat view for UI code that only renders chat messages.
  List<TranscriptMessage> get messages =>
      entries.whereType<TranscriptMessage>().toList();
}

/// A native agent-specific transcript source. More agent formats can be
/// added without coupling their parsing or storage details to the screen.
abstract interface class NativeTranscriptAdapter {
  Future<NativeTranscript?> load(AgentInfo agent);
}

class NativeTranscriptAdapterFactory {
  const NativeTranscriptAdapterFactory._();

  static NativeTranscriptAdapter? create(
    CommandRunner runner,
    AgentInfo agent,
  ) {
    return NativeTranscriptLoader.supportsAgent(agent)
        ? NativeTranscriptLoader(runner)
        : null;
  }
}

/// Selects and retains the appropriate native adapter for one agent session.
class NativeTranscriptHistory {
  NativeTranscriptHistory(this._runner);

  final CommandRunner _runner;
  NativeTranscriptAdapter? _adapter;
  String? _sessionIdentity;

  Future<NativeTranscript?> load(AgentInfo agent) {
    final identity = sessionIdentityFor(agent);
    if (identity != _sessionIdentity) {
      _sessionIdentity = identity;
      _adapter = NativeTranscriptAdapterFactory.create(_runner, agent);
    }
    return _adapter?.load(agent) ?? Future.value(null);
  }

  static String? sessionIdentityFor(AgentInfo agent) {
    final session = agent.agentSession;
    return session == null
        ? null
        : '${session.agent}:${session.kind}:${session.value}';
  }
}

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
      // type == 'user': only text is visible; tool_result blocks stay hidden.
      final text = switch (content) {
        String value => value,
        List<dynamic> blocks =>
          blocks
              .whereType<Map<String, dynamic>>()
              .where((block) => block['type'] == 'text')
              .map((block) => block['text'])
              .whereType<String>()
              .join(),
        _ => '',
      };
      if (text.isEmpty) return const [];
      final stripped = text.replaceAll(_systemReminder, '').trim();
      if (stripped.isEmpty) return const [];
      // Only anchor at the start: a prompt merely mentioning these tags
      // mid-text is not a genuine local-command/command record.
      if (stripped.startsWith('<local-command-stdout>') ||
          stripped.startsWith('<local-command-caveat>')) {
        return const [];
      }
      if (stripped.startsWith('<command-name>') ||
          stripped.startsWith('<command-message>')) {
        final commandName = _commandName.firstMatch(stripped);
        if (commandName != null) {
          final name = commandName.group(1)!;
          final args = _commandArgs.firstMatch(stripped)?.group(1);
          return [
            TranscriptMessage(
              speaker: TranscriptSpeaker.user,
              text: (args != null && args.isNotEmpty) ? '$name $args' : name,
            ),
          ];
        }
      }
      return [
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
            entries.add(
              TranscriptToolUse(
                name: name,
                input: input is Map<String, dynamic> ? input : const {},
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
/// prefix. A poll transfers only bytes appended since the last read.
class NativeTranscriptLoader implements NativeTranscriptAdapter {
  NativeTranscriptLoader(this._runner, {ClaudeTranscriptParser? parser})
    : _parser = parser ?? const ClaudeTranscriptParser();

  static final _claudeSessionId = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  final CommandRunner _runner;
  final ClaudeTranscriptParser _parser;
  String? _sessionId;
  String? _path;
  var _size = 0;
  var _remainder = '';
  var _remainderParsed = false;
  final _entries = <TranscriptEntry>[];

  static bool supportsAgent(AgentInfo agent) {
    final session = agent.agentSession;
    return agent.agent == 'claude' &&
        session?.agent == 'claude' &&
        session?.kind == 'id' &&
        session != null &&
        _claudeSessionId.hasMatch(session.value);
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
