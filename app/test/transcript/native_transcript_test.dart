import 'package:drover/src/transcript/native_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NativeTranscript.messages', () {
    test('filters to only chat messages, in order', () {
      final transcript = NativeTranscript(const [
        TranscriptMessage(speaker: TranscriptSpeaker.user, text: 'Hi'),
        TranscriptToolUse(name: 'Read', input: {'file_path': '/a.dart'}),
        TranscriptThinking('pondering'),
        TranscriptToolResult('toolu_1'),
        TranscriptMessage(speaker: TranscriptSpeaker.assistant, text: 'Hello'),
      ]);

      expect(transcript.messages.map((message) => message.text), [
        'Hi',
        'Hello',
      ]);
    });
  });

  group('toolUseSummary', () {
    test('truncates a long Bash command to its first line', () {
      final command = 'a' * 110;
      final summary = toolUseSummary('Bash', {
        'command': '$command\nrest of command',
      });

      expect(summary, '${'a' * 100}…');
    });

    test('keeps a short Bash command unchanged', () {
      expect(toolUseSummary('Bash', {'command': 'ls -la'}), 'ls -la');
    });

    test('reads file_path for Read/Edit/Write', () {
      expect(toolUseSummary('Read', {'file_path': '/a.dart'}), '/a.dart');
    });

    test('reads the first question for AskUserQuestion', () {
      final summary = toolUseSummary('AskUserQuestion', {
        'questions': [
          {'question': 'Which approach?'},
          {'question': 'Second question'},
        ],
      });

      expect(summary, 'Which approach?');
    });

    test('falls back to the first string value for unknown tools', () {
      expect(
        toolUseSummary('MysteryTool', {'count': 3, 'label': 'value'}),
        'value',
      );
    });

    test('truncates an unknown tool\'s huge default-branch value', () {
      final label = 'b' * 150;
      final summary = toolUseSummary('MysteryTool', {'label': label});

      expect(summary, '${'b' * 100}…');
    });

    test('collapses a multi-line non-Bash value to its first line', () {
      final summary = toolUseSummary('Grep', {
        'pattern': 'first line\nsecond line',
      });

      expect(summary, 'first line');
    });

    test('returns empty string for wrong-shaped input', () {
      expect(toolUseSummary('Read', {'file_path': 42}), '');
      expect(toolUseSummary('Bash', {}), '');
      expect(
        toolUseSummary('AskUserQuestion', {'questions': 'not a list'}),
        '',
      );
      expect(toolUseSummary('AskUserQuestion', {'questions': []}), '');
      expect(toolUseSummary('Unknown', {}), '');
    });
  });
}
