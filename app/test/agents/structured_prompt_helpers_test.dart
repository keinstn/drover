import 'package:drover/src/agents/structured_prompt_helpers.dart';
import 'package:drover/src/transcript/native_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TranscriptToolUse use(String id, String name) =>
      TranscriptToolUse(id: id, name: name, input: const {});

  group('lastUnansweredToolUse', () {
    test('is null when every call is answered', () {
      final history = NativeTranscript([
        use('a', 'Write'),
        const TranscriptToolResult('a'),
      ]);
      expect(lastUnansweredToolUse(history), isNull);
    });

    test('returns the unanswered call of any tool', () {
      final edit = use('b', 'Edit');
      final history = NativeTranscript([
        use('a', 'Bash'),
        const TranscriptToolResult('a'),
        edit,
      ]);
      expect(lastUnansweredToolUse(history), same(edit));
    });

    test('the most recent unanswered call wins', () {
      final latest = use('c', 'Write');
      final history = NativeTranscript([
        use('a', 'Edit'),
        use('b', 'Bash'),
        const TranscriptToolResult('b'),
        latest,
      ]);
      expect(lastUnansweredToolUse(history), same(latest));
    });
  });
}
