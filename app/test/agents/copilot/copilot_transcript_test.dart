import 'dart:convert';

import 'package:drover/src/agents/copilot/copilot_transcript.dart';
import 'package:drover/src/herdr/command_runner.dart';
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
  final statSizes = <int>[];
  static const path =
      '/home/dev/.copilot/session-state/c7c50b87-4d4c-4a92-9396-2cfa4158612d/'
      'events.jsonl';

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
  Future<List<int>> readFile(String path, {int offset = 0}) async {
    readOffsets.add(offset);
    return utf8.encode(contents).sublist(offset);
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

AgentInfo copilotAgent({String sessionId = _sessionId}) => AgentInfo(
  paneId: 'w:p',
  workspaceId: 'w',
  tabId: 'w:t',
  agent: 'copilot',
  status: AgentStatus.working,
  cwd: '/home/dev/project',
  focused: false,
  agentSession: AgentSession(
    source: 'herdr:copilot',
    agent: 'copilot',
    kind: 'id',
    value: sessionId,
  ),
);

String _userEvent(String content) =>
    '{"type":"user.message","data":{"content":${jsonEncode(content)}},'
    '"id":"e1","timestamp":1,"parentId":null}';

String _assistantEvent(String content, {String? phase = 'final_answer'}) =>
    '{"type":"assistant.message","data":{"content":${jsonEncode(content)},'
    '"phase":${phase == null ? 'null' : jsonEncode(phase)}},'
    '"id":"e2","timestamp":2,"parentId":"e1"}';

String _toolStartEvent(
  String toolCallId,
  String toolName, {
  Map<String, dynamic>? arguments,
}) =>
    '{"type":"tool.execution_start","data":{"toolCallId":${jsonEncode(toolCallId)},'
    '"toolName":${jsonEncode(toolName)},"arguments":${jsonEncode(arguments ?? {})}},'
    '"id":"e3","timestamp":3,"parentId":"e2"}';

String _toolCompleteEvent(String toolCallId, {bool success = true}) =>
    '{"type":"tool.execution_complete","data":{"toolCallId":${jsonEncode(toolCallId)},'
    '"success":$success,"result":{"content":"ok","detailedContent":"ok"}},'
    '"id":"e4","timestamp":4,"parentId":"e3"}';

void main() {
  group('CopilotTranscriptParser', () {
    test('parses a user.message event', () {
      final input = '${_userEvent('Hello')}\n';

      final messages = const CopilotTranscriptParser()
          .parseLines(input)
          .whereType<TranscriptMessage>();

      expect(messages, hasLength(1));
      expect(messages.single.speaker, TranscriptSpeaker.user);
      expect(messages.single.text, 'Hello');
    });

    test(
      'parses visible assistant.message phases (final_answer, commentary)',
      () {
        final input =
            '${_assistantEvent('Here is the answer', phase: 'final_answer')}\n'
            '${_assistantEvent('Working on it', phase: 'commentary')}\n';

        final messages = const CopilotTranscriptParser()
            .parseLines(input)
            .whereType<TranscriptMessage>();

        expect(messages.map((m) => m.speaker), [
          TranscriptSpeaker.assistant,
          TranscriptSpeaker.assistant,
        ]);
        expect(messages.map((m) => m.text), [
          'Here is the answer',
          'Working on it',
        ]);
      },
    );

    test(
      'never renders an assistant.message with the intermediate null phase, '
      'even when its content looks non-empty (opaque/encrypted reasoning)',
      () {
        final input = '${_assistantEvent('ciphertext-blob', phase: null)}\n';

        final entries = const CopilotTranscriptParser().parseLines(input);

        expect(entries, isEmpty);
      },
    );

    test('skips an assistant.message with an unrecognized phase value', () {
      final input = '${_assistantEvent('text', phase: 'something-else')}\n';

      final entries = const CopilotTranscriptParser().parseLines(input);

      expect(entries, isEmpty);
    });

    test(
      'drops a user.message or visible assistant.message with blank content',
      () {
        final input =
            '${_userEvent('   ')}\n'
            '${_assistantEvent('', phase: 'final_answer')}\n';

        final entries = const CopilotTranscriptParser().parseLines(input);

        expect(entries, isEmpty);
      },
    );

    test('maps tool.execution_start to a TranscriptToolUse', () {
      final input =
          '${_toolStartEvent('call_1', 'bash', arguments: {'command': 'ls'})}\n';

      final entries = const CopilotTranscriptParser().parseLines(input);

      expect(entries, hasLength(1));
      final toolUse = entries.single as TranscriptToolUse;
      expect(toolUse.id, 'call_1');
      expect(toolUse.name, 'bash');
      expect(toolUse.input, {'command': 'ls'});
    });

    test(
      'defaults tool.execution_start arguments to an empty map when missing',
      () {
        const input =
            '{"type":"tool.execution_start","data":{"toolCallId":"call_1",'
            '"toolName":"bash"},"id":"e3","timestamp":3,"parentId":"e2"}\n';

        final entries = const CopilotTranscriptParser().parseLines(input);

        final toolUse = entries.single as TranscriptToolUse;
        expect(toolUse.input, isEmpty);
      },
    );

    test('skips a tool.execution_start missing toolCallId or toolName', () {
      const missingId =
          '{"type":"tool.execution_start","data":{"toolName":"bash"}}\n';
      const missingName =
          '{"type":"tool.execution_start","data":{"toolCallId":"call_1"}}\n';

      expect(const CopilotTranscriptParser().parseLines(missingId), isEmpty);
      expect(const CopilotTranscriptParser().parseLines(missingName), isEmpty);
    });

    test(
      'maps tool.execution_complete to a TranscriptToolResult keyed by toolCallId',
      () {
        final input = '${_toolCompleteEvent('call_1')}\n';

        final entries = const CopilotTranscriptParser().parseLines(input);

        expect(entries, hasLength(1));
        expect((entries.single as TranscriptToolResult).toolUseId, 'call_1');
      },
    );

    test('skips a tool.execution_complete missing toolCallId', () {
      const input =
          '{"type":"tool.execution_complete","data":{"success":true}}\n';

      expect(const CopilotTranscriptParser().parseLines(input), isEmpty);
    });

    test('ignores noisy hook/session/usage events', () {
      const input =
          '{"type":"session.start","data":{}}\n'
          '{"type":"hook.pre_tool_use","data":{"foo":"bar"}}\n'
          '{"type":"usage.report","data":{"tokens":123}}\n';

      final entries = const CopilotTranscriptParser().parseLines(input);

      expect(entries, isEmpty);
    });

    test('ignores an event with no data map', () {
      const input = '{"type":"user.message"}\n';

      expect(const CopilotTranscriptParser().parseLines(input), isEmpty);
    });

    test('skips a malformed (non-JSON) line without breaking history', () {
      final input =
          '${_userEvent('Before')}\n'
          'not json at all\n'
          '${_userEvent('After')}\n';

      final messages = const CopilotTranscriptParser()
          .parseLines(input)
          .whereType<TranscriptMessage>();

      expect(messages.map((m) => m.text), ['Before', 'After']);
    });

    test('skips a line whose top-level JSON value is not a map', () {
      const input = '[1,2,3]\n"just a string"\n';

      expect(const CopilotTranscriptParser().parseLines(input), isEmpty);
    });

    test('preserves event order across a full user/assistant/tool turn', () {
      final input =
          '${_userEvent('List the files')}\n'
          '${_toolStartEvent('call_1', 'bash', arguments: {'command': 'ls'})}\n'
          '${_toolCompleteEvent('call_1')}\n'
          '${_assistantEvent('Done', phase: 'final_answer')}\n';

      final entries = const CopilotTranscriptParser().parseLines(input);

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

  group('CopilotTranscriptLoader.supportsAgent', () {
    test('true for a copilot agent with a valid session id', () {
      expect(CopilotTranscriptLoader.supportsAgent(copilotAgent()), isTrue);
    });

    test('false for a non-copilot agent kind', () {
      final agent = copilotAgent();
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

      expect(CopilotTranscriptLoader.supportsAgent(other), isFalse);
    });

    test('false without an agent_session', () {
      final agent = AgentInfo(
        paneId: 'w:p',
        workspaceId: 'w',
        tabId: 'w:t',
        agent: 'copilot',
        status: AgentStatus.idle,
        cwd: '/home/dev/project',
        focused: false,
      );

      expect(CopilotTranscriptLoader.supportsAgent(agent), isFalse);
    });

    test('false for a session whose kind is not "id"', () {
      const session = AgentSession(
        source: 'herdr:copilot',
        agent: 'copilot',
        kind: 'name',
        value: _sessionId,
      );
      final agent = AgentInfo(
        paneId: 'w:p',
        workspaceId: 'w',
        tabId: 'w:t',
        agent: 'copilot',
        status: AgentStatus.idle,
        cwd: '/home/dev/project',
        focused: false,
        agentSession: session,
      );

      expect(CopilotTranscriptLoader.supportsAgent(agent), isFalse);
    });

    test('false for a malformed session id', () {
      expect(
        CopilotTranscriptLoader.supportsAgent(
          copilotAgent(sessionId: 'not-a-uuid'),
        ),
        isFalse,
      );
    });
  });

  group('CopilotTranscriptLoader', () {
    test('locates the exact session path once and incrementally reads appended '
        'bytes', () async {
      final runner = MemoryRunner('${_userEvent('One')}\n');
      final loader = CopilotTranscriptLoader(runner);

      var transcript = await loader.load(copilotAgent());
      expect(transcript?.messages.map((m) => m.text), ['One']);
      expect(runner.commands, [
        'sh -lc \'p="\${COPILOT_HOME:-\$HOME/.copilot}/session-state/'
            '$_sessionId/events.jsonl"; if [ -f "\$p" ]; then command '
            'printf "%s" "\$p"; fi\'',
      ]);
      expect(runner.readOffsets, [0]);

      transcript = await loader.load(copilotAgent());
      expect(transcript?.messages, hasLength(1));
      expect(runner.readOffsets, [0]);

      runner.contents += '${_assistantEvent('Two')}\n';
      transcript = await loader.load(copilotAgent());
      expect(transcript?.messages.map((m) => m.text), ['One', 'Two']);
      expect(runner.readOffsets, hasLength(2));
      // Only one lookup command across every poll — the resolved path is
      // cached for the life of the session.
      expect(runner.commands, hasLength(1));
    });

    test('honors COPILOT_HOME in the lookup command it sends', () async {
      final runner = MemoryRunner('');
      await CopilotTranscriptLoader(runner).load(copilotAgent());

      expect(runner.commands.single, startsWith('sh -lc '));
      expect(
        runner.commands.single,
        contains(r'${COPILOT_HOME:-$HOME/.copilot}'),
      );
      expect(
        runner.commands.single,
        contains('session-state/$_sessionId/events.jsonl'),
      );
    });

    test(
      'does not construct a lookup for unsafe/invalid session values',
      () async {
        final runner = MemoryRunner('');
        final loader = CopilotTranscriptLoader(runner);

        final transcript = await loader.load(copilotAgent(sessionId: '../bad'));

        expect(transcript, isNull);
        expect(runner.commands, isEmpty);
        expect(runner.readOffsets, isEmpty);
      },
    );

    test(
      'returns null (missing-file fallback) when the session file does not exist yet',
      () async {
        final runner = MemoryRunner('');
        runner.lookupOutput = '';

        final transcript = await CopilotTranscriptLoader(
          runner,
        ).load(copilotAgent());

        expect(transcript, isNull);
        expect(runner.readOffsets, isEmpty);
      },
    );

    test('throws when the transcript lookup command genuinely fails', () async {
      final runner = MemoryRunner('');
      runner.lookupExitCode = 1;
      runner.lookupError = 'permission denied';

      await expectLater(
        CopilotTranscriptLoader(runner).load(copilotAgent()),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Unable to locate Copilot transcript'),
          ),
        ),
      );
      expect(runner.readOffsets, isEmpty);
    });

    test('rejects an unsafe transcript path returned by lookup', () async {
      final runner = MemoryRunner('');
      runner.lookupOutput = '../unsafe/$_sessionId/events.jsonl';

      await expectLater(
        CopilotTranscriptLoader(runner).load(copilotAgent()),
        throwsA(isA<StateError>()),
      );
      expect(runner.readOffsets, isEmpty);
    });

    test(
      'rejects an absolute path containing a ".." traversal segment',
      () async {
        final runner = MemoryRunner('');
        runner.lookupOutput =
            '/home/dev/.copilot/session-state/../$_sessionId/events.jsonl';

        await expectLater(
          CopilotTranscriptLoader(runner).load(copilotAgent()),
          throwsA(isA<StateError>()),
        );
        expect(runner.readOffsets, isEmpty);
      },
    );

    test(
      'rejects a path that does not end with the expected session suffix',
      () async {
        final runner = MemoryRunner('');
        runner.lookupOutput =
            '/home/dev/.copilot/session-state/wrong/events.jsonl';

        await expectLater(
          CopilotTranscriptLoader(runner).load(copilotAgent()),
          throwsA(isA<StateError>()),
        );
        expect(runner.readOffsets, isEmpty);
      },
    );

    test(
      'includes a final valid JSONL record without a trailing newline',
      () async {
        final runner = MemoryRunner(_userEvent('Final'));

        final transcript = await CopilotTranscriptLoader(
          runner,
        ).load(copilotAgent());

        expect(transcript?.messages.map((m) => m.text), ['Final']);
      },
    );

    test('does not duplicate an unterminated record on a repeat poll with no '
        'new bytes', () async {
      final runner = MemoryRunner(_userEvent('Final'));
      final loader = CopilotTranscriptLoader(runner);

      var transcript = await loader.load(copilotAgent());
      expect(transcript?.messages, hasLength(1));

      transcript = await loader.load(copilotAgent());
      expect(transcript?.messages, hasLength(1));
    });

    test(
      'handles a newline arriving after an already parsed final record',
      () async {
        final finalRecord = _userEvent('Final');
        final nextRecord = _assistantEvent('Next');
        final runner = MemoryRunner(finalRecord);
        final loader = CopilotTranscriptLoader(runner);

        await loader.load(copilotAgent());
        runner.contents += '\n';
        await loader.load(copilotAgent());
        runner.contents += nextRecord;
        final transcript = await loader.load(copilotAgent());

        expect(transcript?.messages.map((m) => m.text), ['Final', 'Next']);
      },
    );

    test(
      'skips a malformed appended line without breaking prior history',
      () async {
        final runner = MemoryRunner('${_userEvent('One')}\n');
        final loader = CopilotTranscriptLoader(runner);

        await loader.load(copilotAgent());
        runner.contents += 'garbage not json\n${_userEvent('Two')}\n';
        final transcript = await loader.load(copilotAgent());

        expect(transcript?.messages.map((m) => m.text), ['One', 'Two']);
      },
    );

    test('resets parsed state when the file is truncated (e.g. session '
        'restart)', () async {
      final oldRecord = _userEvent(
        'Stale message that is longer than the replacement',
      );
      final newRecord = _assistantEvent('New');
      final runner = MemoryRunner(oldRecord);
      final loader = CopilotTranscriptLoader(runner);

      var transcript = await loader.load(copilotAgent());
      expect(transcript?.messages.map((m) => m.text), [
        'Stale message that is longer than the replacement',
      ]);

      runner.contents = newRecord;
      transcript = await loader.load(copilotAgent());

      expect(transcript?.messages.map((m) => m.text), ['New']);
      expect(runner.readOffsets, [0, 0]);
    });

    test('resets and re-locates when the agent session id switches (e.g. a '
        'new pane/session)', () async {
      final runner = MemoryRunner('${_userEvent('From session A')}\n');
      final loader = CopilotTranscriptLoader(runner);

      var transcript = await loader.load(copilotAgent());
      expect(transcript?.messages.map((m) => m.text), ['From session A']);
      expect(runner.commands, hasLength(1));

      runner.contents = '${_userEvent('From session B')}\n';
      runner.lookupOutput =
          '/home/dev/.copilot/session-state/$_otherSessionId/events.jsonl';
      transcript = await loader.load(copilotAgent(sessionId: _otherSessionId));

      expect(transcript?.messages.map((m) => m.text), ['From session B']);
      // A fresh session id re-triggers the lookup rather than reusing the
      // previous session's cached path.
      expect(runner.commands, hasLength(2));
    });
  });
}
