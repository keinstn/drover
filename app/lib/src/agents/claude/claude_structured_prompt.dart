// Claude Code's interactive structured prompt: detecting a pending
// AskUserQuestion tool_use in the native transcript and submitting staged
// answers into the live TUI dialog.

import '../../herdr/herdr_client.dart';
import '../../transcript/native_transcript.dart';
import '../agent_capabilities.dart';
import '../structured_prompt_helpers.dart';
import 'claude_askuser_submitter.dart';

/// Parses an AskUserQuestion tool_use's input into the common
/// [StructuredPrompt] shape. Returns null unless [toolUse] is an
/// AskUserQuestion with an id and at least one well-shaped question;
/// malformed questions/options are skipped rather than thrown.
StructuredPrompt? parseAskUserQuestion(TranscriptToolUse toolUse) {
  final toolUseId = toolUse.id;
  if (toolUse.name != 'AskUserQuestion' || toolUseId == null) return null;
  final rawQuestions = toolUse.input['questions'];
  if (rawQuestions is! List) return null;
  final questions = <StructuredPromptQuestion>[];
  for (final rawQuestion in rawQuestions) {
    if (rawQuestion is! Map) continue;
    final question = rawQuestion['question'];
    // A blank question defeats the downstream substring safety gate
    // (contains("") is always true), so treat it as malformed.
    if (question is! String || question.trim().isEmpty) continue;
    final header = rawQuestion['header'];
    final multiSelect = rawQuestion['multiSelect'];
    final rawOptions = rawQuestion['options'];
    final options = <StructuredPromptOption>[];
    if (rawOptions is List) {
      for (final rawOption in rawOptions) {
        if (rawOption is! Map) continue;
        final label = rawOption['label'];
        if (label is! String) continue;
        final description = rawOption['description'];
        options.add(
          StructuredPromptOption(
            label: label,
            description: description is String ? description : null,
          ),
        );
      }
    }
    questions.add(
      StructuredPromptQuestion(
        question: question,
        header: header is String ? header : '',
        multiSelect: multiSelect is bool ? multiSelect : false,
        options: options,
      ),
    );
  }
  if (questions.isEmpty) return null;
  return StructuredPrompt(id: toolUseId, questions: questions);
}
class ClaudeStructuredPromptCapability implements StructuredPromptCapability {
  const ClaudeStructuredPromptCapability();

  /// The last AskUserQuestion tool_use in [history] with no matching
  /// tool_result yet, or null if every AskUserQuestion so far has been
  /// answered (or none were asked).
  @override
  StructuredPrompt? pendingPrompt(NativeTranscript history) {
    final toolUse = findLastUnansweredToolUse(history, 'AskUserQuestion');
    return toolUse == null ? null : parseAskUserQuestion(toolUse);
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
