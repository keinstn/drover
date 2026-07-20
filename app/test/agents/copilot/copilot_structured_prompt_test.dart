import 'package:drover/src/agents/copilot/copilot_structured_prompt.dart';
import 'package:drover/src/transcript/native_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseAskUser', () {
    test('parses a question with string choices', () {
      final toolUse = TranscriptToolUse(
        name: 'ask_user',
        id: 'call_1',
        input: {
          'question': 'Which approach?',
          'choices': ['Ship it', 'Keep iterating'],
        },
      );

      final prompt = parseAskUser(toolUse);

      expect(prompt, isNotNull);
      expect(prompt!.id, 'call_1');
      expect(prompt.questions, hasLength(1));
      final question = prompt.questions.single;
      expect(question.question, 'Which approach?');
      expect(question.header, '');
      expect(question.multiSelect, isFalse);
      expect(question.options.map((o) => o.label), [
        'Ship it',
        'Keep iterating',
      ]);
    });

    test('parses a question with no choices as an empty-options question', () {
      final toolUse = TranscriptToolUse(
        name: 'ask_user',
        id: 'call_1',
        input: {'question': 'What is the project name?'},
      );

      final prompt = parseAskUser(toolUse);

      expect(prompt, isNotNull);
      expect(prompt!.questions.single.options, isEmpty);
      expect(prompt.questions.single.multiSelect, isFalse);
    });

    test('returns null for the wrong tool name', () {
      final toolUse = TranscriptToolUse(
        name: 'Bash',
        id: 'call_1',
        input: {'question': 'Which approach?'},
      );

      expect(parseAskUser(toolUse), isNull);
    });

    test('returns null when the tool_use has no id', () {
      final toolUse = TranscriptToolUse(
        name: 'ask_user',
        input: {'question': 'Which approach?'},
      );

      expect(parseAskUser(toolUse), isNull);
    });

    test('returns null when question is missing or the wrong shape', () {
      expect(
        parseAskUser(
          TranscriptToolUse(name: 'ask_user', id: 'call_1', input: {}),
        ),
        isNull,
      );
      expect(
        parseAskUser(
          TranscriptToolUse(
            name: 'ask_user',
            id: 'call_1',
            input: {'question': 42},
          ),
        ),
        isNull,
      );
    });

    test('returns null for a blank or whitespace-only question', () {
      expect(
        parseAskUser(
          TranscriptToolUse(
            name: 'ask_user',
            id: 'call_1',
            input: {'question': ''},
          ),
        ),
        isNull,
      );
      expect(
        parseAskUser(
          TranscriptToolUse(
            name: 'ask_user',
            id: 'call_1',
            input: {'question': '   '},
          ),
        ),
        isNull,
      );
    });

    test('skips malformed choice entries but keeps well-shaped ones', () {
      final toolUse = TranscriptToolUse(
        name: 'ask_user',
        id: 'call_1',
        input: {
          'question': 'Which approach?',
          'choices': ['Ship it', 42, null, true, 'Keep iterating'],
        },
      );

      final prompt = parseAskUser(toolUse);

      expect(prompt!.questions.single.options.map((o) => o.label), [
        'Ship it',
        'Keep iterating',
      ]);
    });

    test('treats a non-list choices field as no choices', () {
      final toolUse = TranscriptToolUse(
        name: 'ask_user',
        id: 'call_1',
        input: {'question': 'Which approach?', 'choices': 'not a list'},
      );

      final prompt = parseAskUser(toolUse);

      expect(prompt!.questions.single.options, isEmpty);
    });
  });

  group('CopilotStructuredPromptCapability.pendingPrompt', () {
    const capability = CopilotStructuredPromptCapability();

    test('returns the ask_user prompt with no matching tool_result', () {
      final transcript = NativeTranscript([
        TranscriptToolUse(
          name: 'ask_user',
          id: 'call_1',
          input: {'question': 'Which approach?'},
        ),
      ]);

      final prompt = capability.pendingPrompt(transcript);

      expect(prompt, isNotNull);
      expect(prompt!.id, 'call_1');
    });

    test('returns null once a matching tool_result has arrived', () {
      final transcript = NativeTranscript([
        TranscriptToolUse(
          name: 'ask_user',
          id: 'call_1',
          input: {'question': 'Which approach?'},
        ),
        const TranscriptToolResult('call_1'),
      ]);

      expect(capability.pendingPrompt(transcript), isNull);
    });

    test('picks the last unanswered ask_user call among several', () {
      final transcript = NativeTranscript([
        TranscriptToolUse(
          name: 'ask_user',
          id: 'call_1',
          input: {'question': 'First?'},
        ),
        const TranscriptToolResult('call_1'),
        TranscriptToolUse(
          name: 'ask_user',
          id: 'call_2',
          input: {'question': 'Second?'},
        ),
        TranscriptToolUse(
          name: 'ask_user',
          id: 'call_3',
          input: {'question': 'Third?'},
        ),
      ]);

      final prompt = capability.pendingPrompt(transcript);

      expect(prompt!.id, 'call_3');
    });

    test('returns null when there is no ask_user tool_use', () {
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
            name: 'ask_user',
            id: 'call_1',
            input: {'question': '   '},
          ),
        ]);

        expect(capability.pendingPrompt(transcript), isNull);
      },
    );

    test('ignores an unrelated tool_use (e.g. a plain tool call)', () {
      final transcript = NativeTranscript([
        TranscriptToolUse(name: 'Bash', id: 'call_1', input: {'command': 'ls'}),
      ]);

      expect(capability.pendingPrompt(transcript), isNull);
    });
  });
}
