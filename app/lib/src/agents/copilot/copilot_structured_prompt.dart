// GitHub Copilot CLI's interactive structured prompt: detecting a pending
// `ask_user` tool_use in the native transcript and submitting a staged answer
// into the live TUI dialog.
//
// Live-observed on Copilot CLI 1.0.72 (see docs/herdr-notes.md): the event is
// `TranscriptToolUse(name:'ask_user', id:toolCallId, input:{question:String,
// choices?:List<String>})`, answered once a matching
// `TranscriptToolResult(toolCallId)` appears. Unlike Claude Code's
// AskUserQuestion, one tool call carries exactly one single-select question —
// there is no multi-question/multi-select schema to parse.

import '../../herdr/herdr_client.dart';
import '../../transcript/native_transcript.dart';
import '../agent_capabilities.dart';
import 'copilot_askuser_submitter.dart';

/// Parses a Copilot CLI `ask_user` tool_use into the shared [StructuredPrompt]
/// shape, or null if [toolUse] isn't a well-shaped `ask_user` call. A blank or
/// missing `question` is treated as malformed (and would otherwise defeat the
/// submitter's substring safety gate); a malformed individual `choices` entry
/// is skipped rather than invalidating the whole call.
StructuredPrompt? parseAskUser(TranscriptToolUse toolUse) {
  final toolUseId = toolUse.id;
  if (toolUse.name != 'ask_user' || toolUseId == null) return null;
  final question = toolUse.input['question'];
  if (question is! String || question.trim().isEmpty) return null;
  final rawChoices = toolUse.input['choices'];
  final options = <StructuredPromptOption>[];
  if (rawChoices is List) {
    for (final choice in rawChoices) {
      if (choice is! String) continue;
      options.add(StructuredPromptOption(label: choice));
    }
  }
  return StructuredPrompt(
    id: toolUseId,
    questions: [
      StructuredPromptQuestion(
        question: question,
        header: '',
        multiSelect: false,
        options: options,
      ),
    ],
  );
}

class CopilotStructuredPromptCapability implements StructuredPromptCapability {
  const CopilotStructuredPromptCapability();

  /// The last `ask_user` tool_use in [history] with no matching tool_result
  /// yet, or null if every `ask_user` call so far has been answered (or none
  /// were asked).
  @override
  StructuredPrompt? pendingPrompt(NativeTranscript history) {
    final answeredIds = history.entries
        .whereType<TranscriptToolResult>()
        .map((result) => result.toolUseId)
        .toSet();
    for (final entry in history.entries.reversed) {
      if (entry is TranscriptToolUse &&
          entry.name == 'ask_user' &&
          entry.id != null &&
          !answeredIds.contains(entry.id)) {
        return parseAskUser(entry);
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
    final submitter = CopilotAskUserSubmitter(
      readPane: (paneId) => client.readAgent(paneId),
      sendPaneText: client.sendPaneText,
      sendKeys: client.sendKeys,
    );
    return submitter.submit(paneId: paneId, prompt: prompt, answers: answers);
  }
}
