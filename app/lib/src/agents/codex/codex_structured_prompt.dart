// Codex CLI's interactive structured prompt: detecting a pending
// request_user_input function_call in the native transcript and submitting
// staged answers into the live TUI dialog.
//
// Observed on Codex CLI 0.144.6: the event is a `response_item` record with
// payload.type='function_call', name='request_user_input', call_id, and
// arguments as a JSON-encoded string:
//   {questions:[{id:String, header:String, question:String,
//                options:[{label:String, description?:String}, ...]}, ...]}
// Answered once a function_call_output record with the same call_id appears
// (modelled as TranscriptToolResult(call_id)).

import '../../herdr/herdr_client.dart';
import '../../transcript/native_transcript.dart';
import '../agent_capabilities.dart';
import '../structured_prompt_helpers.dart';
import 'codex_request_user_input_submitter.dart';

/// Parses a Codex CLI `request_user_input` tool_use input into the shared
/// [StructuredPrompt] shape. Returns null unless [toolUse] is a
/// `request_user_input` call with a non-null id and a well-shaped questions
/// array. Unlike Claude's parser, a single malformed question or option
/// invalidates the entire call rather than being skipped: the submitter drives
/// navigation by question index, so partial reinterpretation would corrupt
/// the answer order.
StructuredPrompt? parseRequestUserInput(TranscriptToolUse toolUse) {
  final toolUseId = toolUse.id;
  // A blank id is as unsafe as a null one — it cannot be deterministically
  // matched back to a tool_result.
  if (toolUse.name != 'request_user_input' ||
      toolUseId == null ||
      toolUseId.trim().isEmpty) {
    return null;
  }
  final rawQuestions = toolUse.input['questions'];
  if (rawQuestions is! List || rawQuestions.isEmpty) return null;
  final questions = <StructuredPromptQuestion>[];
  for (final rawQuestion in rawQuestions) {
    if (rawQuestion is! Map) return null;
    final id = rawQuestion['id'];
    // A blank id cannot serve as a safe identifier for deterministic matching.
    if (id is! String || id.trim().isEmpty) return null;
    final question = rawQuestion['question'];
    // A blank question defeats the substring safety gate in the submitter
    // (_showsQuestion uses contains), so treat it as malformed.
    if (question is! String || question.trim().isEmpty) return null;
    final rawOptions = rawQuestion['options'];
    // Missing or empty options lists leave no safe navigation target.
    if (rawOptions is! List || rawOptions.isEmpty) return null;
    final options = <StructuredPromptOption>[];
    for (final rawOption in rawOptions) {
      if (rawOption is! Map) return null;
      final label = rawOption['label'];
      // A blank label cannot be safely matched in the selection marker
      // ('› N. <label>'), so treat it as malformed.
      if (label is! String || label.trim().isEmpty) return null;
      final description = rawOption['description'];
      options.add(
        StructuredPromptOption(
          label: label,
          description: description is String ? description : null,
        ),
      );
    }
    final header = rawQuestion['header'];
    questions.add(
      StructuredPromptQuestion(
        question: question,
        header: header is String ? header : '',
        multiSelect: false,
        options: options,
      ),
    );
  }
  return StructuredPrompt(id: toolUseId, questions: questions);
}

class CodexStructuredPromptCapability implements StructuredPromptCapability {
  const CodexStructuredPromptCapability();

  /// The last `request_user_input` tool_use in [history] with no matching
  /// tool_result yet, or null if every call so far has been answered (or none
  /// were asked).
  @override
  StructuredPrompt? pendingPrompt(NativeTranscript history) {
    final toolUse = findLastUnansweredToolUse(history, 'request_user_input');
    return toolUse == null ? null : parseRequestUserInput(toolUse);
  }

  @override
  Future<void> submit({
    required HerdrClient client,
    required String paneId,
    required StructuredPrompt prompt,
    required List<StructuredPromptAnswer> answers,
  }) {
    final submitter = RequestUserInputSubmitter(
      readPane: (paneId) => client.readAgent(paneId),
      sendPaneText: client.sendPaneText,
      sendKeys: client.sendKeys,
    );
    return submitter.submit(paneId: paneId, prompt: prompt, answers: answers);
  }
}
