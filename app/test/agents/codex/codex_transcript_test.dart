import 'dart:convert';

import 'package:drover/src/agents/codex/codex_transcript.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/host_platform.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:drover/src/transcript/native_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryRunner extends CommandRunner {
  MemoryRunner(this.contents);

  String contents;
  String? lookupOutput;
  var lookupExitCode = 0;
  String lookupError = '';
  final commands = <String>[];
  final readOffsets = <int>[];
  final readLengths = <int?>[];
  final statSizes = <int>[];
  static const path =
      '/home/dev/.codex/sessions/2024/03/15/'
      'rollout-abc123-c7c50b87-4d4c-4a92-9396-2cfa4158612d.jsonl';

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
    return CommandResult(
      exitCode: lookupExitCode,
      stdout: lookupOutput ?? path,
      stderr: lookupError,
    );
  }

  @override
  Future<RemoteFileStat> statFile(String path) async => RemoteFileStat(
    size: statSizes.isNotEmpty
        ? statSizes.removeAt(0)
        : utf8.encode(contents).length,
  );

  @override
  Future<List<int>> readFile(String path, {int offset = 0, int? length}) async {
    readOffsets.add(offset);
    readLengths.add(length);
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

const _sessionId = 'c7c50b87-4d4c-4a92-9396-2cfa4158612d';
const _otherSessionId = '11111111-2222-4333-8444-555555555555';

AgentInfo codexAgent({String sessionId = _sessionId}) => AgentInfo(
  paneId: 'w:p',
  workspaceId: 'w',
  tabId: 'w:t',
  agent: 'codex',
  status: AgentStatus.working,
  cwd: '/home/dev/project',
  focused: false,
  agentSession: AgentSession(
    source: 'herdr:codex',
    agent: 'codex',
    kind: 'id',
    value: sessionId,
  ),
);

String _userMsg(String message) =>
    '{"timestamp":1,"type":"event_msg","payload":{"type":"user_message",'
    '"message":${jsonEncode(message)}}}';

String _agentMsg(String message) =>
    '{"timestamp":2,"type":"event_msg","payload":{"type":"agent_message",'
    '"message":${jsonEncode(message)}}}';

String _functionCall(String callId, String name, {String? arguments}) =>
    '{"timestamp":3,"type":"response_item","payload":{"type":"function_call",'
    '"name":${jsonEncode(name)},"call_id":${jsonEncode(callId)},'
    '"arguments":${jsonEncode(arguments ?? '{}')}}}';

String _customToolCall(String callId, String name, {String? input}) {
  final inputField = input != null ? ',"input":${jsonEncode(input)}' : '';
  return '{"timestamp":4,"type":"response_item","payload":{"type":"custom_tool_call",'
      '"name":${jsonEncode(name)},"call_id":${jsonEncode(callId)}$inputField}}';
}

String _functionCallOutput(String callId) =>
    '{"timestamp":5,"type":"response_item","payload":{"type":"function_call_output",'
    '"call_id":${jsonEncode(callId)},"output":"ok"}}';

String _customToolCallOutput(String callId) =>
    '{"timestamp":6,"type":"response_item","payload":{"type":"custom_tool_call_output",'
    '"call_id":${jsonEncode(callId)},"output":"done"}}';

String _responseItemAssistantMsg(String content) =>
    '{"timestamp":7,"type":"response_item","payload":{"type":"message",'
    '"role":"assistant","content":${jsonEncode(content)}}}';

void main() {
  group('CodexTranscriptParser', () {
    test('parses an event_msg user_message', () {
      final input = '${_userMsg('Hello')}\n';

      final entries = const CodexTranscriptParser().parseLines(input);

      expect(entries, hasLength(1));
      final msg = entries.single as TranscriptMessage;
      expect(msg.speaker, TranscriptSpeaker.user);
      expect(msg.text, 'Hello');
    });

    test('parses an event_msg agent_message', () {
      final input = '${_agentMsg('World')}\n';

      final entries = const CodexTranscriptParser().parseLines(input);

      expect(entries, hasLength(1));
      final msg = entries.single as TranscriptMessage;
      expect(msg.speaker, TranscriptSpeaker.assistant);
      expect(msg.text, 'World');
    });

    test('trims whitespace from message text', () {
      final input =
          '${_userMsg('  trimmed  ')}\n${_agentMsg('\n also trimmed \n')}\n';

      final messages = const CodexTranscriptParser()
          .parseLines(input)
          .whereType<TranscriptMessage>();

      expect(messages.map((m) => m.text), ['trimmed', 'also trimmed']);
    });

    test('skips blank user_message and agent_message', () {
      final input = '${_userMsg('')}\n${_agentMsg('   ')}\n';

      expect(const CodexTranscriptParser().parseLines(input), isEmpty);
    });

    test('does not render response_item assistant_message (would duplicate '
        'event_msg display text)', () {
      final input = '${_responseItemAssistantMsg('duplicate text')}\n';

      expect(const CodexTranscriptParser().parseLines(input), isEmpty);
    });

    test('event_msg agent_message and response_item assistant_message in the '
        'same line sequence: only one entry from event_msg', () {
      final input =
          '${_agentMsg('The answer is 42')}\n'
          '${_responseItemAssistantMsg('The answer is 42')}\n';

      final messages = const CodexTranscriptParser()
          .parseLines(input)
          .whereType<TranscriptMessage>();

      expect(messages, hasLength(1));
      expect(messages.single.text, 'The answer is 42');
    });

    test('ignores reasoning and other response_item types', () {
      const reasoning =
          '{"timestamp":1,"type":"response_item","payload":{"type":"reasoning",'
          '"summary":[],"encrypted_content":"abc123"}}';
      const worldState =
          '{"timestamp":2,"type":"response_item","payload":{"type":"world_state",'
          '"content":"..."}}';

      final input = '$reasoning\n$worldState\n';

      expect(const CodexTranscriptParser().parseLines(input), isEmpty);
    });

    test('ignores lifecycle/token/noise record types', () {
      const input =
          '{"timestamp":1,"type":"session_started","payload":{"model":"codex-mini"}}\n'
          '{"timestamp":2,"type":"token_usage","payload":{"total":123}}\n'
          '{"timestamp":3,"type":"agent_turn_start","payload":{}}\n';

      expect(const CodexTranscriptParser().parseLines(input), isEmpty);
    });

    test('parses response_item function_call into TranscriptToolUse', () {
      final input =
          '${_functionCall('call_1', 'bash', arguments: '{"command":"ls"}')}\n';

      final entries = const CodexTranscriptParser().parseLines(input);

      expect(entries, hasLength(1));
      final toolUse = entries.single as TranscriptToolUse;
      expect(toolUse.id, 'call_1');
      expect(toolUse.name, 'bash');
      expect(toolUse.input, {'command': 'ls'});
    });

    test(
      'function_call with malformed JSON arguments becomes empty input map',
      () {
        const input =
            '{"timestamp":1,"type":"response_item","payload":{"type":"function_call",'
            '"name":"bash","call_id":"call_1","arguments":"not json"}}';

        final entries = const CodexTranscriptParser().parseLines('$input\n');

        final toolUse = entries.single as TranscriptToolUse;
        expect(toolUse.input, isEmpty);
      },
    );

    test('function_call with non-object JSON arguments (array) becomes empty '
        'input map', () {
      const input =
          '{"timestamp":1,"type":"response_item","payload":{"type":"function_call",'
          '"name":"bash","call_id":"call_1","arguments":"[1,2,3]"}}';

      final entries = const CodexTranscriptParser().parseLines('$input\n');

      final toolUse = entries.single as TranscriptToolUse;
      expect(toolUse.input, isEmpty);
    });

    test('function_call with missing arguments becomes empty input map', () {
      const input =
          '{"timestamp":1,"type":"response_item","payload":{"type":"function_call",'
          '"name":"bash","call_id":"call_1"}}';

      final entries = const CodexTranscriptParser().parseLines('$input\n');

      final toolUse = entries.single as TranscriptToolUse;
      expect(toolUse.input, isEmpty);
    });

    test(
      'function_call preserves parsed arguments (e.g. request_user_input)',
      () {
        final input =
            '${_functionCall('call_rui', 'request_user_input', arguments: '{"prompt":"Continue?","choices":["yes","no"]}')}\n';

        final entries = const CodexTranscriptParser().parseLines(input);

        final toolUse = entries.single as TranscriptToolUse;
        expect(toolUse.name, 'request_user_input');
        expect(toolUse.id, 'call_rui');
        expect(toolUse.input, {
          'prompt': 'Continue?',
          'choices': ['yes', 'no'],
        });
      },
    );

    test('parses response_item custom_tool_call into TranscriptToolUse with '
        'input wrapped as {input: <string>}', () {
      final input =
          '${_customToolCall('call_2', 'run_in_shell', input: 'echo hi')}\n';

      final entries = const CodexTranscriptParser().parseLines(input);

      expect(entries, hasLength(1));
      final toolUse = entries.single as TranscriptToolUse;
      expect(toolUse.id, 'call_2');
      expect(toolUse.name, 'run_in_shell');
      expect(toolUse.input, {'input': 'echo hi'});
    });

    test('custom_tool_call without input field becomes empty input map', () {
      final input = '${_customToolCall('call_3', 'no_input_tool')}\n';

      final entries = const CodexTranscriptParser().parseLines(input);

      final toolUse = entries.single as TranscriptToolUse;
      expect(toolUse.input, isEmpty);
    });

    test('parses function_call_output into TranscriptToolResult', () {
      final input = '${_functionCallOutput('call_1')}\n';

      final entries = const CodexTranscriptParser().parseLines(input);

      expect(entries, hasLength(1));
      expect((entries.single as TranscriptToolResult).toolUseId, 'call_1');
    });

    test('parses custom_tool_call_output into TranscriptToolResult', () {
      final input = '${_customToolCallOutput('call_2')}\n';

      final entries = const CodexTranscriptParser().parseLines(input);

      expect(entries, hasLength(1));
      expect((entries.single as TranscriptToolResult).toolUseId, 'call_2');
    });

    test('does not render tool output content', () {
      const withOutput =
          '{"timestamp":1,"type":"response_item","payload":{"type":"function_call_output",'
          '"call_id":"call_1","output":"some long output text that should not appear"}}';

      final entries = const CodexTranscriptParser().parseLines('$withOutput\n');

      expect(entries, hasLength(1));
      expect(entries.single, isA<TranscriptToolResult>());
      expect(entries.single, isNot(isA<TranscriptMessage>()));
    });

    test('skips function_call_output missing call_id', () {
      const input =
          '{"timestamp":1,"type":"response_item","payload":{"type":"function_call_output",'
          '"output":"ok"}}\n';

      expect(const CodexTranscriptParser().parseLines(input), isEmpty);
    });

    test('skips custom_tool_call_output missing call_id', () {
      const input =
          '{"timestamp":1,"type":"response_item","payload":{"type":"custom_tool_call_output",'
          '"output":"done"}}\n';

      expect(const CodexTranscriptParser().parseLines(input), isEmpty);
    });

    test('skips a malformed (non-JSON) line without breaking history', () {
      final input =
          '${_userMsg('Before')}\n'
          'not json at all\n'
          '${_agentMsg('After')}\n';

      final messages = const CodexTranscriptParser()
          .parseLines(input)
          .whereType<TranscriptMessage>();

      expect(messages.map((m) => m.text), ['Before', 'After']);
    });

    test('skips a line whose top-level JSON value is not a map', () {
      const input = '[1,2,3]\n"just a string"\n';

      expect(const CodexTranscriptParser().parseLines(input), isEmpty);
    });

    test('skips event_msg with a non-map payload', () {
      const input =
          '{"timestamp":1,"type":"event_msg","payload":"not a map"}\n';

      expect(const CodexTranscriptParser().parseLines(input), isEmpty);
    });

    test('skips event_msg where message is not a string', () {
      const input =
          '{"timestamp":1,"type":"event_msg","payload":{"type":"user_message",'
          '"message":{"nested":"object"}}}\n';

      expect(const CodexTranscriptParser().parseLines(input), isEmpty);
    });

    test('skips function_call missing name', () {
      const input =
          '{"timestamp":1,"type":"response_item","payload":{"type":"function_call",'
          '"call_id":"call_1","arguments":"{}"}}\n';

      expect(const CodexTranscriptParser().parseLines(input), isEmpty);
    });

    test('skips custom_tool_call missing name', () {
      const input =
          '{"timestamp":1,"type":"response_item","payload":{"type":"custom_tool_call",'
          '"call_id":"call_2","input":"hi"}}\n';

      expect(const CodexTranscriptParser().parseLines(input), isEmpty);
    });

    test('preserves entry order across a full user/tool/assistant turn', () {
      final input =
          '${_userMsg('List the files')}\n'
          '${_functionCall('call_1', 'bash', arguments: '{"command":"ls"}')}\n'
          '${_functionCallOutput('call_1')}\n'
          '${_agentMsg('Done')}\n';

      final entries = const CodexTranscriptParser().parseLines(input);

      expect(entries, hasLength(4));
      expect(entries[0], isA<TranscriptMessage>());
      expect((entries[0] as TranscriptMessage).speaker, TranscriptSpeaker.user);
      expect(entries[1], isA<TranscriptToolUse>());
      expect(entries[2], isA<TranscriptToolResult>());
      expect(entries[3], isA<TranscriptMessage>());
      expect(
        (entries[3] as TranscriptMessage).speaker,
        TranscriptSpeaker.assistant,
      );
    });
  });

  group('CodexTranscriptLoader.supportsAgent', () {
    test('true for a codex agent with a valid session id', () {
      expect(CodexTranscriptLoader.supportsAgent(codexAgent()), isTrue);
    });

    test('false for a non-codex agent kind', () {
      final agent = codexAgent();
      final other = AgentInfo(
        paneId: agent.paneId,
        workspaceId: agent.workspaceId,
        tabId: agent.tabId,
        agent: 'claude',
        status: agent.status,
        cwd: agent.cwd,
        focused: agent.focused,
        agentSession: agent.agentSession,
      );

      expect(CodexTranscriptLoader.supportsAgent(other), isFalse);
    });

    test('false without an agent_session', () {
      final agent = AgentInfo(
        paneId: 'w:p',
        workspaceId: 'w',
        tabId: 'w:t',
        agent: 'codex',
        status: AgentStatus.idle,
        cwd: '/home/dev/project',
        focused: false,
      );

      expect(CodexTranscriptLoader.supportsAgent(agent), isFalse);
    });

    test('false for a session whose agent does not match', () {
      final session = const AgentSession(
        source: 'herdr:codex',
        agent: 'claude',
        kind: 'id',
        value: _sessionId,
      );
      final agent = AgentInfo(
        paneId: 'w:p',
        workspaceId: 'w',
        tabId: 'w:t',
        agent: 'codex',
        status: AgentStatus.idle,
        cwd: '/home/dev/project',
        focused: false,
        agentSession: session,
      );

      expect(CodexTranscriptLoader.supportsAgent(agent), isFalse);
    });

    test('false for a session whose kind is not "id"', () {
      const session = AgentSession(
        source: 'herdr:codex',
        agent: 'codex',
        kind: 'name',
        value: _sessionId,
      );
      final agent = AgentInfo(
        paneId: 'w:p',
        workspaceId: 'w',
        tabId: 'w:t',
        agent: 'codex',
        status: AgentStatus.idle,
        cwd: '/home/dev/project',
        focused: false,
        agentSession: session,
      );

      expect(CodexTranscriptLoader.supportsAgent(agent), isFalse);
    });

    test('false for a malformed session id', () {
      expect(
        CodexTranscriptLoader.supportsAgent(
          codexAgent(sessionId: 'not-a-uuid'),
        ),
        isFalse,
      );
    });
  });

  group('CodexTranscriptLoader', () {
    test(
      'locates the exact session path once and incrementally reads appended bytes',
      () async {
        final runner = MemoryRunner('${_userMsg('One')}\n');
        final loader = CodexTranscriptLoader(runner);

        var transcript = await loader.load(codexAgent());
        expect(transcript?.messages.map((m) => m.text), ['One']);
        expect(runner.commands, hasLength(1));
        expect(runner.commands.single, startsWith('sh -lc '));
        expect(runner.readOffsets, [0]);

        transcript = await loader.load(codexAgent());
        expect(transcript?.messages, hasLength(1));
        expect(runner.readOffsets, [0]);

        runner.contents += '${_agentMsg('Two')}\n';
        transcript = await loader.load(codexAgent());
        expect(transcript?.messages.map((m) => m.text), ['One', 'Two']);
        expect(runner.readOffsets, hasLength(2));
        // Path is cached; lookup command is issued only once per session.
        expect(runner.commands, hasLength(1));
      },
    );

    test('honors CODEX_HOME in the lookup command it sends', () async {
      final runner = MemoryRunner('');
      await CodexTranscriptLoader(runner).load(codexAgent());

      expect(runner.commands.single, startsWith('sh -lc '));
      expect(runner.commands.single, contains(r'${CODEX_HOME:-$HOME/.codex}'));
      expect(runner.commands.single, contains('sessions'));
      expect(runner.commands.single, contains(_sessionId));
    });

    test('lookup command uses bounded find (mindepth 4 maxdepth 4) under '
        'sessions root only', () async {
      final runner = MemoryRunner('');
      await CodexTranscriptLoader(runner).load(codexAgent());

      expect(runner.commands.single, contains('sessions'));
      expect(runner.commands.single, contains('-mindepth 4'));
      expect(runner.commands.single, contains('-maxdepth 4'));
      expect(runner.commands.single, contains('-print -quit'));
    });

    test(
      'does not construct a lookup for unsafe/invalid session values',
      () async {
        final runner = MemoryRunner('');
        final loader = CodexTranscriptLoader(runner);

        final transcript = await loader.load(codexAgent(sessionId: '../bad'));

        expect(transcript, isNull);
        expect(runner.commands, isEmpty);
        expect(runner.readOffsets, isEmpty);
      },
    );

    test('returns null (missing-file fallback) when the session file does not '
        'exist yet', () async {
      final runner = MemoryRunner('');
      runner.lookupOutput = '';

      final transcript = await CodexTranscriptLoader(runner).load(codexAgent());

      expect(transcript, isNull);
      expect(runner.readOffsets, isEmpty);
    });

    test('throws when the transcript lookup command genuinely fails', () async {
      final runner = MemoryRunner('');
      runner.lookupExitCode = 1;
      runner.lookupError = 'permission denied';

      await expectLater(
        CodexTranscriptLoader(runner).load(codexAgent()),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Unable to locate Codex transcript'),
          ),
        ),
      );
      expect(runner.readOffsets, isEmpty);
    });

    test('rejects an unsafe transcript path returned by lookup', () async {
      final runner = MemoryRunner('');
      runner.lookupOutput =
          '../unsafe/sessions/2024/03/15/rollout-abc-$_sessionId.jsonl';

      await expectLater(
        CodexTranscriptLoader(runner).load(codexAgent()),
        throwsA(isA<StateError>()),
      );
      expect(runner.readOffsets, isEmpty);
    });

    test(
      'rejects an absolute path containing a ".." traversal segment',
      () async {
        final runner = MemoryRunner('');
        runner.lookupOutput =
            '/home/dev/.codex/sessions/../2024/03/15/rollout-abc-$_sessionId.jsonl';

        await expectLater(
          CodexTranscriptLoader(runner).load(codexAgent()),
          throwsA(isA<StateError>()),
        );
        expect(runner.readOffsets, isEmpty);
      },
    );

    test(
      'rejects a path that does not end with the expected session id suffix',
      () async {
        final runner = MemoryRunner('');
        runner.lookupOutput =
            '/home/dev/.codex/sessions/2024/03/15/rollout-wrong-other-id.jsonl';

        await expectLater(
          CodexTranscriptLoader(runner).load(codexAgent()),
          throwsA(isA<StateError>()),
        );
        expect(runner.readOffsets, isEmpty);
      },
    );

    test(
      'includes a final valid JSONL record without a trailing newline',
      () async {
        final runner = MemoryRunner(_userMsg('Final'));

        final transcript = await CodexTranscriptLoader(
          runner,
        ).load(codexAgent());

        expect(transcript?.messages.map((m) => m.text), ['Final']);
      },
    );

    test('does not duplicate an unterminated record on a repeat poll with no '
        'new bytes', () async {
      final runner = MemoryRunner(_userMsg('Final'));
      final loader = CodexTranscriptLoader(runner);

      var transcript = await loader.load(codexAgent());
      expect(transcript?.messages, hasLength(1));

      transcript = await loader.load(codexAgent());
      expect(transcript?.messages, hasLength(1));
    });

    test(
      'resets parsed state when the file is truncated (e.g. session restart)',
      () async {
        final oldRecord = _userMsg(
          'Stale message that is longer than the replacement',
        );
        final newRecord = _agentMsg('New');
        final runner = MemoryRunner(oldRecord);
        final loader = CodexTranscriptLoader(runner);

        var transcript = await loader.load(codexAgent());
        expect(transcript?.messages.map((m) => m.text), [
          'Stale message that is longer than the replacement',
        ]);

        runner.contents = newRecord;
        transcript = await loader.load(codexAgent());

        expect(transcript?.messages.map((m) => m.text), ['New']);
        expect(runner.readOffsets, [0, 0]);
      },
    );

    test('resets and re-locates when the agent session id switches', () async {
      final runner = MemoryRunner('${_userMsg('From session A')}\n');
      final loader = CodexTranscriptLoader(runner);

      var transcript = await loader.load(codexAgent());
      expect(transcript?.messages.map((m) => m.text), ['From session A']);
      expect(runner.commands, hasLength(1));

      runner.contents = '${_userMsg('From session B')}\n';
      runner.lookupOutput =
          '/home/dev/.codex/sessions/2024/03/15/'
          'rollout-abc123-$_otherSessionId.jsonl';
      transcript = await loader.load(codexAgent(sessionId: _otherSessionId));

      expect(transcript?.messages.map((m) => m.text), ['From session B']);
      // A fresh session id re-triggers the lookup.
      expect(runner.commands, hasLength(2));
    });

    test(
      'skips a malformed appended line without breaking prior history',
      () async {
        final runner = MemoryRunner('${_userMsg('One')}\n');
        final loader = CodexTranscriptLoader(runner);

        await loader.load(codexAgent());
        runner.contents += 'garbage not json\n${_userMsg('Two')}\n';
        final transcript = await loader.load(codexAgent());

        expect(transcript?.messages.map((m) => m.text), ['One', 'Two']);
      },
    );

    test('loads via the PowerShell locator and normalized /C: path on a '
        'Windows host', () async {
      final runner = MemoryRunner('${_userMsg('One')}\n');
      runner.lookupOutput =
          '/C:/Users/x/.codex/sessions/2026/01/13/'
          'rollout-abc123-$_sessionId.jsonl';
      final loader = CodexTranscriptLoader(
        runner,
        platform: const WindowsHostPlatform(),
      );

      final transcript = await loader.load(codexAgent());

      expect(
        runner.commands.single,
        startsWith(
          'powershell.exe -NoProfile -NonInteractive -EncodedCommand ',
        ),
      );
      // A nonempty transcript proves the normalized `/C:/...` path passed
      // the path validators and flowed into the SFTP stat/read path.
      expect(transcript?.messages.map((m) => m.text), ['One']);
    });
  });

  group('CodexTranscriptLoader bounded window', () {
    const lineCount = 12;
    final lines = List.generate(
      lineCount,
      (i) => _userMsg('entry-${i.toString().padLeft(3, '0')}'),
    );
    final lineBytes = utf8.encode('${lines.first}\n').length;
    final contents = '${lines.join('\n')}\n';
    final totalSize = utf8.encode(contents).length;
    // Window just under 4 lines so a tail/older read never lands on a line
    // boundary and always has a genuine partial leading record to discard.
    final windowBytes = lineBytes * 4 - 1;

    test(
      'initial load fetches only the tail window and reports hasOlderHistory',
      () async {
        final runner = MemoryRunner(contents);
        final loader = CodexTranscriptLoader(
          runner,
          window: JsonlTranscriptWindow(windowBytes: windowBytes),
        );

        final transcript = await loader.load(codexAgent());

        expect(transcript, isNotNull);
        // Three entries fit cleanly in a window that covers 4 lines minus 1
        // byte (the partial leading record is discarded): entries 9–11.
        expect(transcript!.messages, isNotEmpty);
        expect(transcript.messages.last.text, 'entry-011');
        expect(loader.hasOlderHistory, isTrue);
        // Only one read was needed to get the tail.
        expect(runner.readOffsets.last, greaterThan(0));
      },
    );

    test('loadOlder fetches an earlier chunk and prepends it', () async {
      final runner = MemoryRunner(contents);
      final loader = CodexTranscriptLoader(
        runner,
        window: JsonlTranscriptWindow(windowBytes: windowBytes),
      );

      final first = await loader.load(codexAgent());
      final older = await loader.loadOlder(codexAgent());

      expect(older, isNotNull);
      // The prepended older chunk should extend the history further back.
      expect(older!.messages.length, greaterThan(first!.messages.length));
      expect(older.messages.first.text, startsWith('entry-0'));
    });

    test(
      'hasOlderHistory becomes false once the window reaches byte 0',
      () async {
        final runner = MemoryRunner(contents);
        final loader = CodexTranscriptLoader(
          runner,
          window: JsonlTranscriptWindow(windowBytes: totalSize + 1),
        );

        await loader.load(codexAgent());

        expect(loader.hasOlderHistory, isFalse);
      },
    );
  });
}
