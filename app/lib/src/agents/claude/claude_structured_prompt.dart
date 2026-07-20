// Claude Code's interactive structured prompt: detecting a pending
// AskUserQuestion tool_use in the native transcript and submitting staged
// answers into the live TUI dialog.

import '../../herdr/herdr_client.dart';
import '../../transcript/native_transcript.dart';
import '../agent_capabilities.dart';
import 'claude_askuser_submitter.dart';
import 'claude_transcript.dart' show parseAskUserQuestion;

class ClaudeStructuredPromptCapability implements StructuredPromptCapability {
  const ClaudeStructuredPromptCapability();

  /// The last AskUserQuestion tool_use in [history] with no matching
  /// tool_result yet, or null if every AskUserQuestion so far has been
  /// answered (or none were asked).
  @override
  StructuredPrompt? pendingPrompt(NativeTranscript history) {
    final answeredIds = history.entries
        .whereType<TranscriptToolResult>()
        .map((result) => result.toolUseId)
        .toSet();
    for (final entry in history.entries.reversed) {
      if (entry is TranscriptToolUse &&
          entry.name == 'AskUserQuestion' &&
          entry.id != null &&
          !answeredIds.contains(entry.id)) {
        return parseAskUserQuestion(entry);
      }
    }
    return null;
  }

  @override
  Future<void> submit({
    required HerdrClient client,
    required String paneId,
    required StructuredPrompt prompt,
    required List<StructuredPromptAnswer> answers,
  }) {
    final submitter = AskUserQuestionSubmitter(
      readPane: (paneId) => client.readAgent(paneId),
      sendPaneText: client.sendPaneText,
      sendKeys: client.sendKeys,
    );
    return submitter.submit(paneId: paneId, prompt: prompt, answers: answers);
  }
}
