import 'dart:convert';

import '../herdr/command_runner.dart';
import '../models/agent_info.dart';

enum TranscriptSpeaker { user, assistant }

class TranscriptMessage {
  const TranscriptMessage({required this.speaker, required this.text});

  final TranscriptSpeaker speaker;
  final String text;
}

class NativeTranscript {
  const NativeTranscript(this.messages);

  final List<TranscriptMessage> messages;
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

  List<TranscriptMessage> parseLines(String input) {
    final messages = <TranscriptMessage>[];
    for (final line in const LineSplitter().convert(input)) {
      final message = parseLine(line);
      if (message != null) {
        messages.add(message);
      }
    }
    return messages;
  }

  TranscriptMessage? parseLine(String line) {
    try {
      final record = jsonDecode(line);
      if (record is! Map<String, dynamic>) return null;
      final type = record['type'];
      final message = record['message'];
      if ((type != 'user' && type != 'assistant') ||
          record['isSidechain'] == true ||
          message is! Map<String, dynamic> ||
          message['role'] != type) {
        return null;
      }
      final content = message['content'];
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
      if (text.isEmpty) return null;
      return TranscriptMessage(
        speaker: type == 'user'
            ? TranscriptSpeaker.user
            : TranscriptSpeaker.assistant,
        text: text,
      );
    } on FormatException {
      return null;
    }
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
  final _messages = <TranscriptMessage>[];

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
      return NativeTranscript(List.unmodifiable(_messages));
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
      final message = _parser.parseLine(input);
      if (message != null && !_remainderParsed) {
        _messages.add(message);
        _remainderParsed = true;
      }
    } else {
      _messages.addAll(_parser.parseLines(input.substring(0, lastNewline)));
      _remainder = input.substring(lastNewline + 1);
      _remainderParsed = false;
      final message = _parser.parseLine(_remainder);
      if (message != null) {
        _messages.add(message);
        _remainderParsed = true;
      }
    }
    return NativeTranscript(List.unmodifiable(_messages));
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
    _messages.clear();
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
