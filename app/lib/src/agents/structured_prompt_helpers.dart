// Shared, agent-agnostic helpers for the structured-prompt workflow.
// Each agent module is responsible for its own parser and TUI state machine;
// only the mechanics that are provably identical across agents live here.

import '../herdr/ansi_text.dart';
import '../transcript/native_transcript.dart';

/// Returns the last [TranscriptToolUse] for [toolName] in [history] that has
/// no matching [TranscriptToolResult] yet, or null if every such call has been
/// answered (or none were made). The reverse scan stops at the first
/// unanswered candidate, so it correctly returns the most-recent pending call
/// even when earlier calls of the same tool are still unanswered.
TranscriptToolUse? findLastUnansweredToolUse(
  NativeTranscript history,
  String toolName,
) {
  final answeredIds = history.entries
      .whereType<TranscriptToolResult>()
      .map((r) => r.toolUseId)
      .toSet();
  for (final entry in history.entries.reversed) {
    if (entry is TranscriptToolUse &&
        entry.name == toolName &&
        entry.id != null &&
        !answeredIds.contains(entry.id)) {
      return entry;
    }
  }
  return null;
}

/// Strips ANSI escape codes from [raw] and collapses every run of whitespace
/// (spaces + newlines) to a single space, trimmed. Used to normalize pane
/// output before predicate matching so terminal wrapping doesn't break
/// substring checks.
String normalizePaneText(String raw) =>
    stripAnsi(raw).replaceAll(RegExp(r'\s+'), ' ').trim();

/// Re-reads [paneId] via [readPane] up to [maxPolls] times, applying
/// [normalizePaneText] to each result and passing it to [predicate]. Returns
/// once the predicate holds. Throws the value returned by [makeError] with
/// [failure] if [maxPolls] is exhausted without success.
///
/// [pollInterval] is the delay between successive re-reads; the first attempt
/// is immediate. Both [maxPolls] and [pollInterval] are injectable so callers
/// (submitter tests) can drive the loop synchronously with short timeouts.
Future<void> pollUntil<E extends Object>({
  required Future<String> Function(String paneId) readPane,
  required String paneId,
  required bool Function(String normalizedText) predicate,
  required E Function(String failure) makeError,
  required String failure,
  required int maxPolls,
  required Duration pollInterval,
}) async {
  for (var attempt = 0; attempt < maxPolls; attempt++) {
    if (attempt > 0) await Future<void>.delayed(pollInterval);
    if (predicate(normalizePaneText(await readPane(paneId)))) return;
  }
  throw makeError(failure);
}
