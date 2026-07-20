import 'dart:convert';

import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:drover/src/transcript/native_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryRunner extends CommandRunner {
  MemoryRunner(this.contents);

  String contents;
  String? lookupOutput;
  final commands = <String>[];
  final readOffsets = <int>[];
  final statSizes = <int>[];
  static const path =
      '/home/dev/.claude/projects/-home-dev-project/c7c50b87-4d4c-4a92-9396-2cfa4158612d.jsonl';

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
    return CommandResult(
      exitCode: 0,
      stdout: lookupOutput ?? '$path\n',
      stderr: '',
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

AgentInfo claudeAgent({String sessionId = _sessionId}) => AgentInfo(
  paneId: 'w:p',
  workspaceId: 'w',
  tabId: 'w:t',
  agent: 'claude',
  status: AgentStatus.working,
  cwd: '/home/dev/project',
  focused: false,
  agentSession: AgentSession(
    source: 'claude',
    agent: 'claude',
    kind: 'id',
    value: sessionId,
  ),
);

void main() {
  group('ClaudeTranscriptParser', () {
    test('parses string and text blocks while ignoring non-visible blocks', () {
      const input =
          '{"type":"user","message":{"role":"user","content":"Hello"}}\n'
          '{"type":"assistant","message":{"role":"assistant","content":['
          '{"type":"thinking","thinking":"secret"},'
          '{"type":"text","text":"Hi"},'
          '{"type":"tool_use","name":"Read"}]}}\n'
          '{"type":"user","message":{"role":"user","content":['
          '{"type":"tool_result","content":"ignored"}]}}\n'
          '{"type":"tool","message":{"role":"tool","content":"ignored"}}\n';

      final messages = const ClaudeTranscriptParser().parseLines(input);

      expect(messages.map((message) => message.speaker), [
        TranscriptSpeaker.user,
        TranscriptSpeaker.assistant,
      ]);
      expect(messages.map((message) => message.text), ['Hello', 'Hi']);
    });

    test('ignores sidechain (subagent) records', () {
      const input =
          '{"type":"user","message":{"role":"user","content":"Main prompt"}}\n'
          '{"type":"user","isSidechain":true,"message":{"role":"user",'
          '"content":"Subagent prompt"}}\n'
          '{"type":"assistant","isSidechain":true,"message":{"role":"assistant",'
          '"content":[{"type":"text","text":"Subagent reply"}]}}\n'
          '{"type":"assistant","message":{"role":"assistant","content":['
          '{"type":"text","text":"Main reply"}]}}\n';

      final messages = const ClaudeTranscriptParser().parseLines(input);

      expect(messages.map((message) => message.text), [
        'Main prompt',
        'Main reply',
      ]);
    });
  });

  group('NativeTranscriptLoader', () {
    test(
      'looks up exact session once and incrementally reads appended bytes',
      () async {
        final runner = MemoryRunner(
          '{"type":"user","message":{"role":"user","content":"One"}}\n',
        );
        final loader = NativeTranscriptLoader(runner);

        var transcript = await loader.load(claudeAgent());
        expect(transcript?.messages.map((message) => message.text), ['One']);
        expect(runner.commands, [
          'find "\$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -type f '
              "-name '$_sessionId.jsonl' -print -quit",
        ]);
        expect(runner.readOffsets, [0]);

        transcript = await loader.load(claudeAgent());
        expect(transcript?.messages, hasLength(1));
        expect(runner.readOffsets, [0]);

        runner.contents +=
            '{"type":"assistant","message":{"role":"assistant","content":"Two"}}\n';
        transcript = await loader.load(claudeAgent());
        expect(transcript?.messages.map((message) => message.text), [
          'One',
          'Two',
        ]);
        expect(runner.readOffsets, [0, 58]);
        expect(runner.commands, hasLength(1));
      },
    );

    test('uses bytes read as the next offset when stat underreports', () async {
      const one = '{"type":"user","message":{"role":"user","content":"One"}}\n';
      const two =
          '{"type":"assistant","message":{"role":"assistant","content":"Two"}}\n';
      const three =
          '{"type":"user","message":{"role":"user","content":"Three"}}\n';
      final runner = MemoryRunner('$one$two');
      runner.statSizes.addAll([
        utf8.encode(one).length,
        utf8.encode('$one$two').length,
      ]);
      final loader = NativeTranscriptLoader(runner);

      var transcript = await loader.load(claudeAgent());
      expect(transcript?.messages.map((message) => message.text), [
        'One',
        'Two',
      ]);
      expect(runner.readOffsets, [0]);

      transcript = await loader.load(claudeAgent());
      expect(transcript?.messages.map((message) => message.text), [
        'One',
        'Two',
      ]);
      expect(runner.readOffsets, [0]);

      runner.contents += three;
      transcript = await loader.load(claudeAgent());
      expect(transcript?.messages.map((message) => message.text), [
        'One',
        'Two',
        'Three',
      ]);
      expect(runner.readOffsets, [0, utf8.encode('$one$two').length]);
    });

    test('does not construct a lookup for unsafe session values', () async {
      final runner = MemoryRunner('');
      final loader = NativeTranscriptLoader(runner);

      final transcript = await loader.load(claudeAgent(sessionId: '../bad'));

      expect(transcript, isNull);
      expect(runner.commands, isEmpty);
      expect(runner.readOffsets, isEmpty);
    });

    test('rejects an unsafe transcript path returned by lookup', () async {
      final runner = MemoryRunner('');
      runner.lookupOutput = '../unsafe/$_sessionId.jsonl\n';

      await expectLater(
        NativeTranscriptLoader(runner).load(claudeAgent()),
        throwsA(isA<StateError>()),
      );
      expect(runner.readOffsets, isEmpty);
    });

    test(
      'includes a final valid JSONL record without a trailing newline',
      () async {
        final runner = MemoryRunner(
          '{"type":"user","message":{"role":"user","content":"Final"}}',
        );

        final transcript = await NativeTranscriptLoader(
          runner,
        ).load(claudeAgent());

        expect(transcript?.messages.map((message) => message.text), ['Final']);
      },
    );

    test(
      'handles a newline arriving after an already parsed final record',
      () async {
        const finalRecord =
            '{"type":"user","message":{"role":"user","content":"Final"}}';
        const nextRecord =
            '{"type":"assistant","message":{"role":"assistant","content":"Next"}}';
        final runner = MemoryRunner(finalRecord);
        final loader = NativeTranscriptLoader(runner);

        await loader.load(claudeAgent());
        runner.contents += '\n';
        await loader.load(claudeAgent());
        runner.contents += nextRecord;
        final transcript = await loader.load(claudeAgent());

        expect(transcript?.messages.map((message) => message.text), [
          'Final',
          'Next',
        ]);
      },
    );

    test(
      'resets a parsed unterminated record when its transcript is replaced',
      () async {
        const oldRecord =
            '{"type":"user","message":{"role":"user","content":"Stale message that is longer than the replacement"}}';
        const newRecord =
            '{"type":"assistant","message":{"role":"assistant","content":"New"}}';
        final runner = MemoryRunner(oldRecord);
        final loader = NativeTranscriptLoader(runner);

        var transcript = await loader.load(claudeAgent());
        expect(transcript?.messages.map((message) => message.text), [
          'Stale message that is longer than the replacement',
        ]);

        runner.contents = newRecord;
        transcript = await loader.load(claudeAgent());

        expect(transcript?.messages.map((message) => message.text), ['New']);
        expect(runner.readOffsets, [0, 0]);
      },
    );
  });
}
