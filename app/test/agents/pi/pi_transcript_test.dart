import 'dart:convert';

import 'package:drover/src/agents/pi/pi_transcript.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:drover/src/transcript/native_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records every [run] command so a test can prove pi's `kind:'path'` session
/// needs no lookup at all, and serves file bytes straight from [contents].
class MemoryRunner extends CommandRunner {
  MemoryRunner(this.contents);

  String contents;
  final commands = <String>[];
  final readOffsets = <int>[];
  final statPaths = <String>[];
  final readPaths = <String>[];

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<RemoteFileStat> statFile(String path) async {
    statPaths.add(path);
    return RemoteFileStat(size: utf8.encode(contents).length);
  }

  @override
  Future<List<int>> readFile(String path, {int offset = 0, int? length}) async {
    readPaths.add(path);
    readOffsets.add(offset);
    final bytes = utf8.encode(contents);
    final end = length == null
        ? bytes.length
        : (offset + length).clamp(0, bytes.length);
    return bytes.sublist(offset, end);
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

/// A [MemoryRunner] whose `statFile` fails until [statWorks] is set — the
/// pruned/rotated/unreadable-session case.
class UnstatableRunner extends MemoryRunner {
  UnstatableRunner(super.contents);

  bool statWorks = false;

  @override
  Future<RemoteFileStat> statFile(String path) {
    statPaths.add(path);
    if (!statWorks) {
      return Future.error(StateError('No such file: $path'));
    }
    return super.statFile(path);
  }
}

const _sessionPath = '/home/dev/.pi/sessions/01932f4e-7c23-session.jsonl';

AgentInfo piAgent({
  String agent = 'pi',
  String sessionAgent = 'pi',
  String kind = 'path',
  String value = _sessionPath,
  bool withSession = true,
}) => AgentInfo(
  paneId: 'w:p',
  workspaceId: 'w',
  tabId: 'w:t',
  agent: agent,
  status: AgentStatus.working,
  cwd: '/home/dev/project',
  focused: false,
  agentSession: withSession
      ? AgentSession(
          source: 'herdr:pi',
          agent: sessionAgent,
          kind: kind,
          value: value,
        )
      : null,
);

String _message(String role, String content) =>
    '{"type":"message","message":{"role":${jsonEncode(role)},'
    '"content":$content}}';

String _text(String text) => '{"type":"text","text":${jsonEncode(text)}}';

String _thinking(String text) =>
    '{"type":"thinking","thinking":${jsonEncode(text)}}';

String _toolCall(String id, String name, String arguments) =>
    '{"type":"toolCall","id":${jsonEncode(id)},"name":${jsonEncode(name)},'
    '"arguments":$arguments}';

String _toolResult(String callId) =>
    '{"type":"message","message":{"role":"toolResult",'
    '"toolCallId":${jsonEncode(callId)},"toolName":"bash",'
    '"content":[{"type":"text","text":"ok"}],"isError":false}}';

void main() {
  group('PiTranscriptParser', () {
    test('parses a user text message', () {
      final input = '${_message('user', '[${_text('Hello')}]')}\n';

      final entries = const PiTranscriptParser().parseLines(input);

      expect(entries, hasLength(1));
      final msg = entries.single as TranscriptMessage;
      expect(msg.speaker, TranscriptSpeaker.user);
      expect(msg.text, 'Hello');
    });

    test('parses an assistant text message', () {
      final input = '${_message('assistant', '[${_text('World')}]')}\n';

      final entries = const PiTranscriptParser().parseLines(input);

      expect(entries, hasLength(1));
      final msg = entries.single as TranscriptMessage;
      expect(msg.speaker, TranscriptSpeaker.assistant);
      expect(msg.text, 'World');
    });

    test('trims whitespace and skips blank text blocks', () {
      final input =
          '${_message('user', '[${_text('  trimmed  ')}]')}\n'
          '${_message('assistant', '[${_text('   ')}]')}\n';

      final entries = const PiTranscriptParser().parseLines(input);

      expect(entries, hasLength(1));
      expect((entries.single as TranscriptMessage).text, 'trimmed');
    });

    test('parses an assistant thinking block', () {
      final input =
          '${_message('assistant', '[${_thinking('let me think')}]')}\n';

      final entries = const PiTranscriptParser().parseLines(input);

      expect(entries, hasLength(1));
      expect((entries.single as TranscriptThinking).text, 'let me think');
    });

    test('parses a toolCall block into TranscriptToolUse, using arguments '
        'as-is (already a decoded object)', () {
      final input =
          '${_message('assistant', '[${_toolCall('call_7ccaf', 'bash', '{"command":"ls -la"}')}]')}\n';

      final entries = const PiTranscriptParser().parseLines(input);

      expect(entries, hasLength(1));
      final toolUse = entries.single as TranscriptToolUse;
      expect(toolUse.id, 'call_7ccaf');
      expect(toolUse.name, 'bash');
      expect(toolUse.input, {'command': 'ls -la'});
    });

    test('emits every block of a thinking,toolCall,toolCall assistant '
        'message, in order', () {
      final input =
          '${_message('assistant', '['
              '${_thinking('planning')},'
              '${_toolCall('call_a', 'bash', '{"command":"ls"}')},'
              '${_toolCall('call_b', 'read', '{"path":"/etc/hosts"}')}'
              ']')}\n';

      final entries = const PiTranscriptParser().parseLines(input);

      expect(entries, hasLength(3));
      expect((entries[0] as TranscriptThinking).text, 'planning');
      expect((entries[1] as TranscriptToolUse).id, 'call_a');
      expect((entries[1] as TranscriptToolUse).name, 'bash');
      expect((entries[2] as TranscriptToolUse).id, 'call_b');
      expect((entries[2] as TranscriptToolUse).name, 'read');
    });

    test('emits every block of a thinking,text,toolCall assistant message, '
        'in order', () {
      final input =
          '${_message('assistant', '['
              '${_thinking('hmm')},'
              '${_text('Running it now')},'
              '${_toolCall('call_c', 'bash', '{"command":"pwd"}')}'
              ']')}\n';

      final entries = const PiTranscriptParser().parseLines(input);

      expect(entries, hasLength(3));
      expect(entries[0], isA<TranscriptThinking>());
      expect((entries[1] as TranscriptMessage).text, 'Running it now');
      expect((entries[2] as TranscriptToolUse).id, 'call_c');
    });

    test('toolCall with non-object arguments becomes an empty input map', () {
      final input =
          '${_message('assistant', '[${_toolCall('call_d', 'bash', '[1,2,3]')}]')}\n';

      final entries = const PiTranscriptParser().parseLines(input);

      expect((entries.single as TranscriptToolUse).input, isEmpty);
    });

    test('skips a toolCall block missing its name', () {
      final input =
          '${_message('assistant', '[{"type":"toolCall","id":"call_e","arguments":{}}]')}\n';

      expect(const PiTranscriptParser().parseLines(input), isEmpty);
    });

    test('parses a toolResult record into TranscriptToolResult with the '
        'matching toolCallId', () {
      final input = '${_toolResult('call_7ccaf')}\n';

      final entries = const PiTranscriptParser().parseLines(input);

      expect(entries, hasLength(1));
      expect((entries.single as TranscriptToolResult).toolUseId, 'call_7ccaf');
    });

    test('does not render toolResult content or image blocks', () {
      const input =
          '{"type":"message","message":{"role":"toolResult",'
          '"toolCallId":"call_img","toolName":"screenshot","isError":false,'
          '"content":[{"type":"image","data":"base64…"},'
          '{"type":"text","text":"long output that must not appear"}]}}\n';

      final entries = const PiTranscriptParser().parseLines(input);

      expect(entries, hasLength(1));
      expect(entries.single, isA<TranscriptToolResult>());
    });

    test('skips a toolResult missing toolCallId', () {
      const input =
          '{"type":"message","message":{"role":"toolResult",'
          '"toolName":"bash","content":[]}}\n';

      expect(const PiTranscriptParser().parseLines(input), isEmpty);
    });

    test('ignores custom, model_change, session and thinking_level_change '
        'records', () {
      const input =
          '{"type":"custom","customType":"web-search-results","results":[]}\n'
          '{"type":"model_change","model":"pi-1"}\n'
          '{"type":"session","id":"abc"}\n'
          '{"type":"thinking_level_change","level":"high"}\n';

      expect(const PiTranscriptParser().parseLines(input), isEmpty);
    });

    test('ignores a bashExecution message (user-run !command)', () {
      const input =
          '{"type":"message","message":{"role":"bashExecution",'
          '"command":"ls","output":"a\\nb"}}\n';

      expect(const PiTranscriptParser().parseLines(input), isEmpty);
    });

    test('an assistant message with empty content produces nothing', () {
      final input = '${_message('assistant', '[]')}\n';

      expect(const PiTranscriptParser().parseLines(input), isEmpty);
    });

    test('skips a message whose content is not a list', () {
      const input =
          '{"type":"message","message":{"role":"user","content":"plain"}}\n';

      expect(const PiTranscriptParser().parseLines(input), isEmpty);
    });

    test('skips a message record with a non-map message payload', () {
      const input = '{"type":"message","message":"not a map"}\n';

      expect(const PiTranscriptParser().parseLines(input), isEmpty);
    });

    test('skips a malformed (non-JSON) line without breaking history', () {
      final input =
          '${_message('user', '[${_text('Before')}]')}\n'
          'not json at all\n'
          '${_message('assistant', '[${_text('After')}]')}\n';

      final messages = const PiTranscriptParser()
          .parseLines(input)
          .whereType<TranscriptMessage>();

      expect(messages.map((m) => m.text), ['Before', 'After']);
    });

    test('skips a line whose top-level JSON value is not a map', () {
      const input = '[1,2,3]\n"just a string"\n';

      expect(const PiTranscriptParser().parseLines(input), isEmpty);
    });

    test('preserves entry order across a full user/tool/assistant turn', () {
      final input =
          '${_message('user', '[${_text('List the files')}]')}\n'
          '${_message('assistant', '[${_toolCall('call_1', 'bash', '{"command":"ls"}')}]')}\n'
          '${_toolResult('call_1')}\n'
          '${_message('assistant', '[${_text('Done')}]')}\n';

      final entries = const PiTranscriptParser().parseLines(input);

      expect(entries, hasLength(4));
      expect((entries[0] as TranscriptMessage).speaker, TranscriptSpeaker.user);
      expect(entries[1], isA<TranscriptToolUse>());
      expect(entries[2], isA<TranscriptToolResult>());
      expect(
        (entries[3] as TranscriptMessage).speaker,
        TranscriptSpeaker.assistant,
      );
    });
  });

  group('PiTranscriptLoader.supportsAgent', () {
    test('true for a pi agent with a valid kind:path session', () {
      expect(PiTranscriptLoader.supportsAgent(piAgent()), isTrue);
    });

    test('false without an agent_session', () {
      expect(
        PiTranscriptLoader.supportsAgent(piAgent(withSession: false)),
        isFalse,
      );
    });

    test('false for a session whose kind is "id"', () {
      expect(PiTranscriptLoader.supportsAgent(piAgent(kind: 'id')), isFalse);
    });

    test('false for a non-pi agent kind', () {
      expect(
        PiTranscriptLoader.supportsAgent(piAgent(agent: 'codex')),
        isFalse,
      );
    });

    test('false for a session whose agent does not match', () {
      expect(
        PiTranscriptLoader.supportsAgent(piAgent(sessionAgent: 'codex')),
        isFalse,
      );
    });

    test('false for a relative path', () {
      expect(
        PiTranscriptLoader.supportsAgent(
          piAgent(value: '.pi/sessions/a.jsonl'),
        ),
        isFalse,
      );
    });

    test('false for a path containing a ".." traversal segment', () {
      expect(
        PiTranscriptLoader.supportsAgent(
          piAgent(value: '/home/dev/.pi/../../etc/shadow.jsonl'),
        ),
        isFalse,
      );
    });

    test('false for a path that does not end with .jsonl', () {
      expect(
        PiTranscriptLoader.supportsAgent(
          piAgent(value: '/home/dev/.pi/sessions/a.log'),
        ),
        isFalse,
      );
    });
  });

  group('PiTranscriptLoader', () {
    test('reads the reported path directly, issuing no lookup command, and '
        'appends newly-written bytes on a later load', () async {
      final runner = MemoryRunner('${_message('user', '[${_text('One')}]')}\n');
      final loader = PiTranscriptLoader(runner);

      var transcript = await loader.load(piAgent());
      expect(transcript?.messages.map((m) => m.text), ['One']);
      // The whole point of kind:'path': no remote location *command* at all,
      // just `_locate`'s readability probe (hence two stats on this first
      // load) plus the window's own stat.
      expect(runner.commands, isEmpty);
      expect(runner.statPaths, [_sessionPath, _sessionPath]);
      expect(runner.readPaths, [_sessionPath]);
      expect(runner.readOffsets, [0]);

      runner.contents += '${_message('assistant', '[${_text('Two')}]')}\n';
      transcript = await loader.load(piAgent());

      expect(transcript?.messages.map((m) => m.text), ['One', 'Two']);
      expect(runner.readOffsets, hasLength(2));
      expect(runner.readOffsets.last, greaterThan(0));
      expect(runner.commands, isEmpty);
    });

    test(
      'returns null instead of throwing when the session file cannot be '
      'statted, and recovers once it can',
      () async {
        // Unlike its three siblings, pi has no lookup command to signal
        // "not there"; the stat probe in `_locate` is what lets AgentScreen
        // fall back to pane-text history instead of showing a retry banner
        // re-armed on every poll.
        final runner = UnstatableRunner(_message('user', '[${_text('hi')}]'));
        final loader = PiTranscriptLoader(runner);

        expect(await loader.load(piAgent()), isNull);
        expect(runner.readPaths, isEmpty);

        // A later poll retries the probe rather than caching the failure.
        runner.statWorks = true;
        final transcript = await loader.load(piAgent());
        expect(transcript, isNotNull);
        expect(
          transcript!.entries.whereType<TranscriptMessage>().single.text,
          'hi',
        );
      },
    );

    test('returns null and reads nothing for an unsupported session', () async {
      final runner = MemoryRunner('');

      final transcript = await PiTranscriptLoader(
        runner,
      ).load(piAgent(value: '../unsafe.jsonl'));

      expect(transcript, isNull);
      expect(runner.commands, isEmpty);
      expect(runner.readOffsets, isEmpty);
    });

    test('resets and re-reads when the session path switches', () async {
      final runner = MemoryRunner(
        '${_message('user', '[${_text('From session A')}]')}\n',
      );
      final loader = PiTranscriptLoader(runner);

      var transcript = await loader.load(piAgent());
      expect(transcript?.messages.map((m) => m.text), ['From session A']);

      runner.contents = '${_message('user', '[${_text('From session B')}]')}\n';
      transcript = await loader.load(
        piAgent(value: '/home/dev/.pi/sessions/other.jsonl'),
      );

      expect(transcript?.messages.map((m) => m.text), ['From session B']);
      expect(runner.readPaths.last, '/home/dev/.pi/sessions/other.jsonl');
      expect(runner.commands, isEmpty);
    });

    test('includes a final valid record without a trailing newline', () async {
      final runner = MemoryRunner(_message('user', '[${_text('Final')}]'));

      final transcript = await PiTranscriptLoader(runner).load(piAgent());

      expect(transcript?.messages.map((m) => m.text), ['Final']);
    });
  });

  group('PiTranscriptLoader bounded window', () {
    const lineCount = 12;
    final lines = List.generate(
      lineCount,
      (i) => _message(
        'user',
        '[${_text('entry-${i.toString().padLeft(3, '0')}')}]',
      ),
    );
    final lineBytes = utf8.encode('${lines.first}\n').length;
    final contents = '${lines.join('\n')}\n';
    final windowBytes = lineBytes * 4 - 1;

    test('initial load fetches only the tail window, then loadOlder prepends '
        'an earlier chunk', () async {
      final runner = MemoryRunner(contents);
      final loader = PiTranscriptLoader(
        runner,
        window: JsonlTranscriptWindow(windowBytes: windowBytes),
      );

      final first = await loader.load(piAgent());
      expect(first!.messages, isNotEmpty);
      expect(first.messages.last.text, 'entry-011');
      expect(loader.hasOlderHistory, isTrue);
      expect(runner.readOffsets.last, greaterThan(0));

      final older = await loader.loadOlder(piAgent());

      expect(older!.messages.length, greaterThan(first.messages.length));
      expect(older.messages.first.text, startsWith('entry-0'));
    });
  });
}
