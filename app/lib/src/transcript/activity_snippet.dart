import '../../l10n/app_localizations.dart';
import 'native_transcript.dart';

/// A one-line "what is this agent doing right now" snippet, derived from the
/// most recent displayable entry of [transcript] (walking from the end):
///
///  - [TranscriptToolUse] → the tool name plus its [toolUseSummary]
///    (e.g. `Edit herd_screen.dart`), matching how the tool_use chip reads;
///  - [TranscriptMessage] → the first line of the message text (either
///    speaker);
///  - [TranscriptThinking] → a localized "thinking" placeholder;
///  - [TranscriptToolResult] → skipped (a tool result carries no readable
///    activity of its own; the tool_use that spawned it does).
///
/// Returns null when [transcript] is null or has no usable entry, so callers
/// can fall back to other metadata.
String? activitySnippet(NativeTranscript? transcript, AppLocalizations l10n) {
  if (transcript == null) return null;
  for (final entry in transcript.entries.reversed) {
    switch (entry) {
      case TranscriptToolUse(:final name, :final input):
        final summary = toolUseSummary(name, input);
        return summary.isEmpty ? name : '$name $summary';
      case TranscriptMessage(:final text):
        final firstLine = text.split('\n').first.trim();
        if (firstLine.isNotEmpty) return firstLine;
      case TranscriptThinking():
        return l10n.herdSnippetThinking;
      case TranscriptToolResult():
        continue;
    }
  }
  return null;
}
