import 'dart:convert';

import 'package:drover/src/agents/claude/claude_structured_prompt.dart';
import 'package:drover/src/agents/claude/claude_transcript.dart';
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
  final readLengths = <int?>[];
  final statSizes = <int>[];
  static const path =
      '/home/dev/.claude/projects/-home-dev-project/c7c50b87-4d4c-4a92-9396-2cfa4158612d.jsonl';

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
    return CommandResult(
      exitCode: lookupExitCode,
      stdout: lookupOutput ?? '$path\n',
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

      final messages = const ClaudeTranscriptParser()
          .parseLines(input)
          .whereType<TranscriptMessage>();

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

      final messages = const ClaudeTranscriptParser()
          .parseLines(input)
          .whereType<TranscriptMessage>();

      expect(messages.map((message) => message.text), [
        'Main prompt',
        'Main reply',
      ]);
    });

    test('ignores isMeta records', () {
      const input =
          '{"type":"user","isMeta":true,"message":{"role":"user",'
          '"content":"Meta prompt"}}\n'
          '{"type":"user","message":{"role":"user","content":"Real prompt"}}\n';

      final messages = const ClaudeTranscriptParser()
          .parseLines(input)
          .whereType<TranscriptMessage>();

      expect(messages.map((message) => message.text), ['Real prompt']);
    });

    test('strips system-reminder blocks but keeps surrounding text', () {
      final input =
          '{"type":"user","message":{"role":"user","content":'
          '${jsonEncode('Before <system-reminder>hidden\nstuff</system-reminder> After')}'
          '}}\n';

      final messages = const ClaudeTranscriptParser()
          .parseLines(input)
          .whereType<TranscriptMessage>();

      expect(messages.map((message) => message.text), ['Before  After']);
    });

    test('skips a message that is only a system-reminder', () {
      final input =
          '{"type":"assistant","message":{"role":"assistant","content":['
          '{"type":"text","text":'
          '${jsonEncode('<system-reminder>hidden</system-reminder>')}}]}}\n';

      final entries = const ClaudeTranscriptParser().parseLines(input);

      expect(entries, isEmpty);
    });

    test('ignores local-command-stdout records', () {
      final input =
          '{"type":"user","message":{"role":"user","content":'
          '${jsonEncode('<local-command-stdout>ok</local-command-stdout>')}'
          '}}\n'
          '{"type":"user","message":{"role":"user","content":'
          '${jsonEncode('<local-command-caveat>note</local-command-caveat>')}'
          '}}\n'
          '{"type":"user","message":{"role":"user","content":"Real prompt"}}\n';

      final messages = const ClaudeTranscriptParser()
          .parseLines(input)
          .whereType<TranscriptMessage>();

      expect(messages.map((message) => message.text), ['Real prompt']);
    });

    test('renders a command-name record as the slash command', () {
      final input =
          '{"type":"user","message":{"role":"user","content":'
          '${jsonEncode('<command-message>model</command-message>'
          '<command-name>/model</command-name>')}'
          '}}\n';

      final messages = const ClaudeTranscriptParser()
          .parseLines(input)
          .whereType<TranscriptMessage>();

      expect(messages.map((message) => message.text), ['/model']);
    });

    test('renders a command-name record with args', () {
      final input =
          '{"type":"user","message":{"role":"user","content":'
          '${jsonEncode('<command-name>/model</command-name>'
          '<command-args>opus</command-args>')}'
          '}}\n';

      final messages = const ClaudeTranscriptParser()
          .parseLines(input)
          .whereType<TranscriptMessage>();

      expect(messages.map((message) => message.text), ['/model opus']);
    });

    test('keeps a user prompt that merely mentions command-name mid-text', () {
      final input =
          '{"type":"user","message":{"role":"user","content":'
          '${jsonEncode('How do I use <command-name>/model</command-name>?')}'
          '}}\n';

      final messages = const ClaudeTranscriptParser()
          .parseLines(input)
          .whereType<TranscriptMessage>();

      expect(messages.map((message) => message.text), [
        'How do I use <command-name>/model</command-name>?',
      ]);
    });

    test(
      'keeps a user prompt that merely quotes local-command-stdout mid-text',
      () {
        final input =
            '{"type":"user","message":{"role":"user","content":'
            '${jsonEncode('What does <local-command-stdout>ok</local-command-stdout> mean?')}'
            '}}\n';

        final messages = const ClaudeTranscriptParser()
            .parseLines(input)
            .whereType<TranscriptMessage>();

        expect(messages.map((message) => message.text), [
          'What does <local-command-stdout>ok</local-command-stdout> mean?',
        ]);
      },
    );

    test('emits text, tool_use, and thinking entries in content order', () {
      const input =
          '{"type":"assistant","message":{"role":"assistant","content":['
          '{"type":"text","text":"Before"},'
          '{"type":"tool_use","name":"Read","input":{"file_path":"/a.dart"}},'
          '{"type":"thinking","thinking":"pondering"},'
          '{"type":"text","text":"After"}]}}\n';

      final entries = const ClaudeTranscriptParser().parseLines(input);

      expect(entries, hasLength(4));
      final message0 = entries[0] as TranscriptMessage;
      expect(message0.speaker, TranscriptSpeaker.assistant);
      expect(message0.text, 'Before');
      final toolUse = entries[1] as TranscriptToolUse;
      expect(toolUse.name, 'Read');
      expect(toolUse.input, {'file_path': '/a.dart'});
      final thinking = entries[2] as TranscriptThinking;
      expect(thinking.text, 'pondering');
      final message1 = entries[3] as TranscriptMessage;
      expect(message1.text, 'After');
    });

    test('defaults tool_use input to an empty map when missing', () {
      const input =
          '{"type":"assistant","message":{"role":"assistant","content":['
          '{"type":"tool_use","name":"Bash"}]}}\n';

      final entries = const ClaudeTranscriptParser().parseLines(input);

      expect(entries, hasLength(1));
      final toolUse = entries.single as TranscriptToolUse;
      expect(toolUse.name, 'Bash');
      expect(toolUse.input, isEmpty);
    });

    test('keeps a record whose content is only tool_use blocks', () {
      const input =
          '{"type":"assistant","message":{"role":"assistant","content":['
          '{"type":"tool_use","name":"Read","input":{"file_path":"/a.dart"}}]}}\n';

      final entries = const ClaudeTranscriptParser().parseLines(input);

      expect(entries, hasLength(1));
      expect(entries.single, isA<TranscriptToolUse>());
    });

    test('captures the tool_use id', () {
      const input =
          '{"type":"assistant","message":{"role":"assistant","content":['
          '{"type":"tool_use","id":"toolu_1","name":"Read","input":{}}]}}\n';

      final entries = const ClaudeTranscriptParser().parseLines(input);

      final toolUse = entries.single as TranscriptToolUse;
      expect(toolUse.id, 'toolu_1');
    });

    test('leaves the tool_use id null when the block has none', () {
      const input =
          '{"type":"assistant","message":{"role":"assistant","content":['
          '{"type":"tool_use","name":"Read","input":{}}]}}\n';

      final entries = const ClaudeTranscriptParser().parseLines(input);

      expect((entries.single as TranscriptToolUse).id, isNull);
    });

    test(
      'emits a tool_result marker alongside text in the same user record',
      () {
        const input =
            '{"type":"user","message":{"role":"user","content":['
            '{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"},'
            '{"type":"text","text":"Continuing"}]}}\n';

        final entries = const ClaudeTranscriptParser().parseLines(input);

        expect(entries, hasLength(2));
        final toolResult = entries[0] as TranscriptToolResult;
        expect(toolResult.toolUseId, 'toolu_1');
        final message = entries[1] as TranscriptMessage;
        expect(message.text, 'Continuing');
      },
    );

    test(
      'emits a tool_result marker for a user record with no visible text',
      () {
        const input =
            '{"type":"user","message":{"role":"user","content":['
            '{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}}\n';

        final entries = const ClaudeTranscriptParser().parseLines(input);

        expect(entries, hasLength(1));
        expect((entries.single as TranscriptToolResult).toolUseId, 'toolu_1');
      },
    );

    test('excludes tool_result markers from the messages getter', () {
      const input =
          '{"type":"user","message":{"role":"user","content":['
          '{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"},'
          '{"type":"text","text":"Continuing"}]}}\n';

      final entries = const ClaudeTranscriptParser().parseLines(input);
      final transcript = NativeTranscript(entries);

      expect(transcript.messages.map((message) => message.text), [
        'Continuing',
      ]);
    });
  });

  group('parseAskUserQuestion', () {
    test('parses multiple questions with options and descriptions', () {
      final toolUse = TranscriptToolUse(
        name: 'AskUserQuestion',
        id: 'toolu_1',
        input: {
          'questions': [
            {
              'question': 'Which approach?',
              'header': 'Approach',
              'multiSelect': false,
              'options': [
                {'label': 'A', 'description': 'First option'},
                {'label': 'B'},
              ],
            },
            {
              'question': 'Which files?',
              'header': 'Files',
              'multiSelect': true,
              'options': [
                {'label': 'a.dart'},
              ],
            },
          ],
        },
      );

      final prompt = parseAskUserQuestion(toolUse);

      expect(prompt, isNotNull);
      expect(prompt!.id, 'toolu_1');
      expect(prompt.questions, hasLength(2));
      final first = prompt.questions[0];
      expect(first.question, 'Which approach?');
      expect(first.header, 'Approach');
      expect(first.multiSelect, isFalse);
      expect(first.options, hasLength(2));
      expect(first.options[0].label, 'A');
      expect(first.options[0].description, 'First option');
      expect(first.options[1].label, 'B');
      expect(first.options[1].description, isNull);
      final second = prompt.questions[1];
      expect(second.multiSelect, isTrue);
      expect(second.options.single.label, 'a.dart');
    });

    test('defaults header to empty and multiSelect to false when missing', () {
      final toolUse = TranscriptToolUse(
        name: 'AskUserQuestion',
        id: 'toolu_1',
        input: {
          'questions': [
            {'question': 'Which approach?'},
          ],
        },
      );

      final prompt = parseAskUserQuestion(toolUse);

      expect(prompt!.questions.single.header, '');
      expect(prompt.questions.single.multiSelect, isFalse);
      expect(prompt.questions.single.options, isEmpty);
    });

    test('returns null for the wrong tool name', () {
      final toolUse = TranscriptToolUse(
        name: 'Read',
        id: 'toolu_1',
        input: {
          'questions': [
            {'question': 'Which approach?'},
          ],
        },
      );

      expect(parseAskUserQuestion(toolUse), isNull);
    });

    test('returns null when the tool_use has no id', () {
      final toolUse = TranscriptToolUse(
        name: 'AskUserQuestion',
        input: {
          'questions': [
            {'question': 'Which approach?'},
          ],
        },
      );

      expect(parseAskUserQuestion(toolUse), isNull);
    });

    test('returns null when questions is missing or the wrong shape', () {
      expect(
        parseAskUserQuestion(
          TranscriptToolUse(name: 'AskUserQuestion', id: 'toolu_1', input: {}),
        ),
        isNull,
      );
      expect(
        parseAskUserQuestion(
          TranscriptToolUse(
            name: 'AskUserQuestion',
            id: 'toolu_1',
            input: {'questions': 'not a list'},
          ),
        ),
        isNull,
      );
    });

    test('skips a malformed question but keeps well-shaped ones', () {
      final toolUse = TranscriptToolUse(
        name: 'AskUserQuestion',
        id: 'toolu_1',
        input: {
          'questions': [
            {'header': 'No question field'},
            {'question': 'Which approach?'},
          ],
        },
      );

      final prompt = parseAskUserQuestion(toolUse);

      expect(prompt!.questions, hasLength(1));
      expect(prompt.questions.single.question, 'Which approach?');
    });

    test('returns null when every question is malformed', () {
      final toolUse = TranscriptToolUse(
        name: 'AskUserQuestion',
        id: 'toolu_1',
        input: {
          'questions': [
            {'header': 'No question field'},
          ],
        },
      );

      expect(parseAskUserQuestion(toolUse), isNull);
    });

    test('skips a blank or whitespace-only question', () {
      final toolUse = TranscriptToolUse(
        name: 'AskUserQuestion',
        id: 'toolu_1',
        input: {
          'questions': [
            {'question': ''},
            {'question': '   '},
            {'question': 'Which approach?'},
          ],
        },
      );

      final prompt = parseAskUserQuestion(toolUse);

      expect(prompt!.questions, hasLength(1));
      expect(prompt.questions.single.question, 'Which approach?');
    });

    test('returns null when the only question is blank', () {
      final toolUse = TranscriptToolUse(
        name: 'AskUserQuestion',
        id: 'toolu_1',
        input: {
          'questions': [
            {'question': '   '},
          ],
        },
      );

      expect(parseAskUserQuestion(toolUse), isNull);
    });

    test('skips a malformed option but keeps well-shaped ones', () {
      final toolUse = TranscriptToolUse(
        name: 'AskUserQuestion',
        id: 'toolu_1',
        input: {
          'questions': [
            {
              'question': 'Which approach?',
              'options': [
                {'description': 'No label field'},
                {'label': 'A'},
              ],
            },
          ],
        },
      );

      final prompt = parseAskUserQuestion(toolUse);

      expect(prompt!.questions.single.options, hasLength(1));
      expect(prompt.questions.single.options.single.label, 'A');
    });
  });

  group('ClaudeStructuredPromptCapability.pendingPrompt', () {
    const capability = ClaudeStructuredPromptCapability();

    test('returns the AskUserQuestion prompt with no matching tool_result', () {
      final transcript = NativeTranscript([
        TranscriptToolUse(
          name: 'AskUserQuestion',
          id: 'toolu_1',
          input: {
            'questions': [
              {'question': 'Which approach?'},
            ],
          },
        ),
      ]);

      final prompt = capability.pendingPrompt(transcript);

      expect(prompt, isNotNull);
      expect(prompt!.id, 'toolu_1');
    });

    test('returns null once a matching tool_result has arrived', () {
      final transcript = NativeTranscript([
        TranscriptToolUse(
          name: 'AskUserQuestion',
          id: 'toolu_1',
          input: {
            'questions': [
              {'question': 'Which approach?'},
            ],
          },
        ),
        const TranscriptToolResult('toolu_1'),
      ]);

      expect(capability.pendingPrompt(transcript), isNull);
    });

    test('picks the last unanswered AskUserQuestion among several', () {
      final transcript = NativeTranscript([
        TranscriptToolUse(
          name: 'AskUserQuestion',
          id: 'toolu_1',
          input: {
            'questions': [
              {'question': 'First?'},
            ],
          },
        ),
        const TranscriptToolResult('toolu_1'),
        TranscriptToolUse(
          name: 'AskUserQuestion',
          id: 'toolu_2',
          input: {
            'questions': [
              {'question': 'Second?'},
            ],
          },
        ),
        TranscriptToolUse(
          name: 'AskUserQuestion',
          id: 'toolu_3',
          input: {
            'questions': [
              {'question': 'Third?'},
            ],
          },
        ),
      ]);

      final prompt = capability.pendingPrompt(transcript);

      expect(prompt!.id, 'toolu_3');
    });

    test('returns null when there is no AskUserQuestion tool_use', () {
      final transcript = NativeTranscript([
        const TranscriptMessage(speaker: TranscriptSpeaker.user, text: 'Hello'),
      ]);

      expect(capability.pendingPrompt(transcript), isNull);
    });

    test(
      'returns null when the pending tool_use has only a blank question',
      () {
        final transcript = NativeTranscript([
          TranscriptToolUse(
            name: 'AskUserQuestion',
            id: 'toolu_1',
            input: {
              'questions': [
                {'question': '   '},
              ],
            },
          ),
        ]);

        expect(capability.pendingPrompt(transcript), isNull);
      },
    );
  });

  group('ClaudeTranscriptLoader', () {
    test(
      'looks up exact session once and incrementally reads appended bytes',
      () async {
        final runner = MemoryRunner(
          '{"type":"user","message":{"role":"user","content":"One"}}\n',
        );
        final loader = ClaudeTranscriptLoader(runner);

        var transcript = await loader.load(claudeAgent());
        expect(transcript?.messages.map((message) => message.text), ['One']);
        expect(runner.commands, [
          'command find "\$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -type f '
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
      final loader = ClaudeTranscriptLoader(runner);

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

    test(
      'appends every entry parsed from one line, across two polls',
      () async {
        const first =
            '{"type":"assistant","message":{"role":"assistant","content":['
            '{"type":"text","text":"Before"},'
            '{"type":"tool_use","name":"Read","input":{"file_path":"/a.dart"}}'
            ']}}\n';
        final runner = MemoryRunner(first);
        final loader = ClaudeTranscriptLoader(runner);

        var transcript = await loader.load(claudeAgent());
        expect(transcript?.entries, hasLength(2));
        expect(transcript?.entries[0], isA<TranscriptMessage>());
        expect(transcript?.entries[1], isA<TranscriptToolUse>());

        runner.contents +=
            '{"type":"user","message":{"role":"user","content":"After"}}\n';
        transcript = await loader.load(claudeAgent());
        expect(transcript?.entries, hasLength(3));
        expect(transcript?.messages.map((message) => message.text), [
          'Before',
          'After',
        ]);
      },
    );

    test(
      'does not duplicate a multi-entry unterminated record on repeat poll',
      () async {
        const record =
            '{"type":"assistant","message":{"role":"assistant","content":['
            '{"type":"tool_use","name":"Read","input":{"file_path":"/a.dart"}},'
            '{"type":"thinking","thinking":"pondering"}]}}';
        final runner = MemoryRunner(record);
        final loader = ClaudeTranscriptLoader(runner);

        var transcript = await loader.load(claudeAgent());
        expect(transcript?.entries, hasLength(2));

        transcript = await loader.load(claudeAgent());
        expect(transcript?.entries, hasLength(2));
      },
    );

    test('does not construct a lookup for unsafe session values', () async {
      final runner = MemoryRunner('');
      final loader = ClaudeTranscriptLoader(runner);

      final transcript = await loader.load(claudeAgent(sessionId: '../bad'));

      expect(transcript, isNull);
      expect(runner.commands, isEmpty);
      expect(runner.readOffsets, isEmpty);
    });

    test(
      'returns null when transcript lookup succeeds but finds no path yet',
      () async {
        final runner = MemoryRunner('');
        runner.lookupOutput = '';

        final transcript = await ClaudeTranscriptLoader(
          runner,
        ).load(claudeAgent());

        expect(transcript, isNull);
        expect(runner.readOffsets, isEmpty);
      },
    );

    test('throws when transcript lookup command fails', () async {
      final runner = MemoryRunner('');
      runner.lookupExitCode = 1;
      runner.lookupError = 'permission denied';

      await expectLater(
        ClaudeTranscriptLoader(runner).load(claudeAgent()),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Unable to locate Claude transcript'),
          ),
        ),
      );
      expect(runner.readOffsets, isEmpty);
    });

    test('rejects an unsafe transcript path returned by lookup', () async {
      final runner = MemoryRunner('');
      runner.lookupOutput = '../unsafe/$_sessionId.jsonl\n';

      await expectLater(
        ClaudeTranscriptLoader(runner).load(claudeAgent()),
        throwsA(isA<StateError>()),
      );
      expect(runner.readOffsets, isEmpty);
    });

    test('rejects multiple transcript paths returned by lookup', () async {
      final runner = MemoryRunner('');
      runner.lookupOutput =
          '${MemoryRunner.path}\n/home/dev/.claude/projects/other/$_sessionId.jsonl\n';

      await expectLater(
        ClaudeTranscriptLoader(runner).load(claudeAgent()),
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

        final transcript = await ClaudeTranscriptLoader(
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
        final loader = ClaudeTranscriptLoader(runner);

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
        final loader = ClaudeTranscriptLoader(runner);

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

    test(
      'resets and re-locates when the agent session id switches '
      '(e.g. a new pane/session)',
      () async {
        final runner = MemoryRunner(
          '{"type":"user","message":{"role":"user","content":"From session A"}}\n',
        );
        final loader = ClaudeTranscriptLoader(runner);

        var transcript = await loader.load(claudeAgent());
        expect(transcript?.messages.map((message) => message.text), [
          'From session A',
        ]);
        expect(runner.commands, hasLength(1));

        runner.contents =
            '{"type":"user","message":{"role":"user","content":"From session B"}}\n';
        runner.lookupOutput =
            '/home/dev/.claude/projects/-home-dev-project/'
            '$_otherSessionId.jsonl\n';
        transcript = await loader.load(claudeAgent(sessionId: _otherSessionId));

        expect(transcript?.messages.map((message) => message.text), [
          'From session B',
        ]);
        // A fresh session id re-triggers the lookup rather than reusing the
        // previous session's cached path.
        expect(runner.commands, hasLength(2));
      },
    );
  });

  group('ClaudeTranscriptLoader bounded window', () {
    // A small custom window (a few uniform-length lines wide) forces the
    // bounded tail/older-chunk paths deterministically, without needing a
    // multi-hundred-KiB fixture to exceed the real 512 KiB default.
    String uniformLine(int i) => jsonEncode({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': 'entry-${i.toString().padLeft(3, '0')}',
      },
    });

    const lineCount = 12;
    final lines = List.generate(lineCount, uniformLine);
    final lineBytes = utf8.encode('${lines.first}\n').length;
    final contents = '${lines.join('\n')}\n';
    final totalSize = utf8.encode(contents).length;
    // Just under 4 lines wide, so a tail/older read never lands exactly on a
    // line boundary and always has a genuine partial leading record to
    // discard.
    final windowBytes = lineBytes * 4 - (lineBytes ~/ 2);

    String textOf(String line) =>
        ((jsonDecode(line) as Map<String, dynamic>)['message']
                as Map<String, dynamic>)['content']
            as String;

    List<String> expectedFrom(int firstIndex) =>
        lines.sublist(firstIndex).map(textOf).toList();

    test('bounds the very first read of a large file to a tail window, '
        'discarding only the partial leading record', () async {
      final runner = MemoryRunner(contents);
      final loader = ClaudeTranscriptLoader(
        runner,
        window: JsonlTranscriptWindow(windowBytes: windowBytes),
      );

      final transcript = await loader.load(claudeAgent());

      // Exactly one bounded read: the offset skips straight to the tail,
      // never the whole file from 0.
      expect(runner.readOffsets, hasLength(1));
      final offset = runner.readOffsets.single;
      expect(offset, totalSize - windowBytes);
      expect(offset, greaterThan(0));
      expect(runner.readLengths.single, windowBytes);

      final firstIncluded = (offset ~/ lineBytes) + 1;
      expect(
        transcript?.messages.map((message) => message.text),
        expectedFrom(firstIncluded),
      );
    });

    test('append-only polling after the initial bounded tail transfers only '
        'newly-written bytes', () async {
      final runner = MemoryRunner(contents);
      final loader = ClaudeTranscriptLoader(
        runner,
        window: JsonlTranscriptWindow(windowBytes: windowBytes),
      );

      await loader.load(claudeAgent());
      expect(runner.readOffsets, hasLength(1));

      final appendedLine = uniformLine(lineCount);
      runner.contents += '$appendedLine\n';
      final transcript = await loader.load(claudeAgent());

      // The second read starts exactly at the previously-known EOF and is
      // unbounded (reads to the new EOF) — never re-fetching earlier bytes.
      expect(runner.readOffsets, [totalSize - windowBytes, totalSize]);
      expect(runner.readLengths.last, isNull);
      expect(transcript?.messages.last.text, textOf(appendedLine));
    });

    test(
      'loadOlder prepends the next bounded chunk in chronological order',
      () async {
        final runner = MemoryRunner(contents);
        final loader = ClaudeTranscriptLoader(
          runner,
          window: JsonlTranscriptWindow(windowBytes: windowBytes),
        );

        await loader.load(claudeAgent());
        expect(loader.hasOlderHistory, isTrue);

        final transcript = await loader.loadOlder(claudeAgent());

        expect(runner.readOffsets, hasLength(2));
        final olderOffset = runner.readOffsets[1];
        expect(olderOffset, lessThan(runner.readOffsets[0]));
        final firstIncluded = (olderOffset ~/ lineBytes) + 1;
        expect(
          transcript?.messages.map((message) => message.text),
          expectedFrom(firstIncluded),
        );
      },
    );

    test(
      'loadOlder is a no-op once the beginning of history is reached',
      () async {
        final runner = MemoryRunner(contents);
        final loader = ClaudeTranscriptLoader(
          runner,
          window: JsonlTranscriptWindow(windowBytes: windowBytes),
        );

        await loader.load(claudeAgent());
        NativeTranscript? last;
        var guard = 0;
        while (loader.hasOlderHistory && guard < lineCount + 2) {
          last = await loader.loadOlder(claudeAgent());
          guard++;
        }

        expect(loader.hasOlderHistory, isFalse);
        expect(last?.messages.map((message) => message.text), expectedFrom(0));

        final callsBeforeNoOp = runner.readOffsets.length;
        final noOpResult = await loader.loadOlder(claudeAgent());

        expect(noOpResult, isNull);
        expect(runner.readOffsets, hasLength(callsBeforeNoOp));
      },
    );

    test('resets the window when the file is truncated (e.g. a replaced '
        'session file)', () async {
      final runner = MemoryRunner(contents);
      final loader = ClaudeTranscriptLoader(
        runner,
        window: JsonlTranscriptWindow(windowBytes: windowBytes),
      );

      await loader.load(claudeAgent());

      const replacement =
          '{"type":"user","message":{"role":"user","content":"Replaced"}}\n';
      runner.contents = replacement;
      final transcript = await loader.load(claudeAgent());

      expect(transcript?.messages.map((message) => message.text), ['Replaced']);
      expect(loader.hasOlderHistory, isFalse);
    });

    test(
      'still loads a small file in full from offset 0 (window unused)',
      () async {
        final small = '${lines.take(3).join('\n')}\n';
        final smallSize = utf8.encode(small).length;
        final runner = MemoryRunner(small);
        final loader = ClaudeTranscriptLoader(
          runner,
          window: JsonlTranscriptWindow(windowBytes: smallSize),
        );

        final transcript = await loader.load(claudeAgent());

        expect(runner.readOffsets, [0]);
        expect(runner.readLengths, [null]);
        expect(
          transcript?.messages.map((message) => message.text),
          expectedFrom(0).take(3),
        );
        expect(loader.hasOlderHistory, isFalse);
      },
    );
  });
}
