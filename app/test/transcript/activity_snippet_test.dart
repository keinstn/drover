import 'package:drover/l10n/app_localizations_en.dart';
import 'package:drover/src/screens/herd_screen.dart' show formatElapsed;
import 'package:drover/src/transcript/activity_snippet.dart';
import 'package:drover/src/transcript/native_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final l10n = AppLocalizationsEn();

  group('activitySnippet', () {
    test('returns null for a null transcript', () {
      expect(activitySnippet(null, l10n), isNull);
    });

    test('returns null when there is no usable entry', () {
      expect(activitySnippet(const NativeTranscript([]), l10n), isNull);
      expect(
        activitySnippet(
          const NativeTranscript([TranscriptToolResult('id-1')]),
          l10n,
        ),
        isNull,
      );
    });

    test('summarizes a tool_use with its name and argument', () {
      final transcript = NativeTranscript([
        const TranscriptToolUse(
          name: 'Read',
          input: {'file_path': 'herd_screen.dart'},
        ),
      ]);
      expect(activitySnippet(transcript, l10n), 'Read herd_screen.dart');
    });

    test('falls back to just the tool name when the summary is empty', () {
      final transcript = NativeTranscript([
        const TranscriptToolUse(name: 'Read', input: {}),
      ]);
      expect(activitySnippet(transcript, l10n), 'Read');
    });

    test('uses the first line of a message', () {
      final transcript = NativeTranscript([
        const TranscriptMessage(
          speaker: TranscriptSpeaker.assistant,
          text: 'First line\nsecond line',
        ),
      ]);
      expect(activitySnippet(transcript, l10n), 'First line');
    });

    test('renders a thinking placeholder for a thinking entry', () {
      final transcript = NativeTranscript([const TranscriptThinking('hmm')]);
      expect(activitySnippet(transcript, l10n), l10n.herdSnippetThinking);
    });

    test('the last displayable entry wins', () {
      final transcript = NativeTranscript([
        const TranscriptMessage(
          speaker: TranscriptSpeaker.user,
          text: 'earlier',
        ),
        const TranscriptToolUse(
          name: 'Edit',
          input: {'file_path': 'app_theme.dart'},
        ),
      ]);
      expect(activitySnippet(transcript, l10n), 'Edit app_theme.dart');
    });

    test('skips a trailing tool_result and uses the entry before it', () {
      final transcript = NativeTranscript([
        const TranscriptMessage(
          speaker: TranscriptSpeaker.assistant,
          text: 'done thinking',
        ),
        const TranscriptToolResult('id-9'),
      ]);
      expect(activitySnippet(transcript, l10n), 'done thinking');
    });
  });

  group('formatElapsed', () {
    test('under a minute reads "now"', () {
      expect(
        formatElapsed(const Duration(seconds: 59), l10n),
        l10n.herdElapsedNow,
      );
    });

    test('at one minute switches to minutes', () {
      expect(
        formatElapsed(const Duration(seconds: 60), l10n),
        l10n.herdElapsedMinutes(1),
      );
    });

    test('just under an hour still reads minutes', () {
      expect(
        formatElapsed(const Duration(minutes: 59), l10n),
        l10n.herdElapsedMinutes(59),
      );
    });

    test('at one hour switches to hours', () {
      expect(
        formatElapsed(const Duration(minutes: 60), l10n),
        l10n.herdElapsedHours(1),
      );
    });
  });
}
