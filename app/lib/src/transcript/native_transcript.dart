import '../models/agent_info.dart';

enum TranscriptSpeaker { user, assistant }

/// One entry in a rendered transcript: a chat message, a tool invocation, or
/// a thinking block, in the order the agent produced them. Shared by every
/// agent's native transcript source (see `NativeTranscriptAdapter`); an
/// agent's own module is responsible for parsing its raw format into this
/// shape.
sealed class TranscriptEntry {
  const TranscriptEntry();
}

class TranscriptMessage extends TranscriptEntry {
  const TranscriptMessage({required this.speaker, required this.text});

  final TranscriptSpeaker speaker;
  final String text;
}

class TranscriptToolUse extends TranscriptEntry {
  const TranscriptToolUse({required this.name, required this.input, this.id});

  final String name;
  final Map<String, dynamic> input;
  final String? id;
}

class TranscriptThinking extends TranscriptEntry {
  const TranscriptThinking(this.text);

  final String text;
}

/// A marker for a tool_result block seen in a later USER record, matched to
/// its originating [TranscriptToolUse] by [toolUseId].
class TranscriptToolResult extends TranscriptEntry {
  const TranscriptToolResult(this.toolUseId);

  final String toolUseId;
}

/// One selectable option within a [StructuredPromptQuestion]. A common,
/// agent-agnostic shape — an agent's own module (e.g. `agents/claude`) is
/// responsible for parsing its native record (Claude's AskUserQuestion tool,
/// say) into this shape.
class StructuredPromptOption {
  const StructuredPromptOption({required this.label, this.description});

  final String label;
  final String? description;
}

/// One question within a [StructuredPrompt].
class StructuredPromptQuestion {
  const StructuredPromptQuestion({
    required this.question,
    required this.header,
    required this.multiSelect,
    required this.options,
  });

  final String question;
  final String header;
  final bool multiSelect;
  final List<StructuredPromptOption> options;
}

/// An agent's pending interactive structured prompt (e.g. the parsed input of
/// Claude Code's AskUserQuestion tool_use), keyed by [id] — an
/// implementation-defined identifier (a tool_use id, say) that its eventual
/// answer/acknowledgement must match.
class StructuredPrompt {
  const StructuredPrompt({required this.id, required this.questions});

  final String id;
  final List<StructuredPromptQuestion> questions;
}

/// A user's answer to one [StructuredPromptQuestion]. Single-select answers
/// have at most one selected index; a custom answer sets [customText] instead.
class StructuredPromptAnswer {
  const StructuredPromptAnswer({
    required this.selectedIndexes,
    this.customText,
  });

  final List<int> selectedIndexes;
  final String? customText;
}

/// The cap every [toolUseSummary] branch truncates its return value to, so a
/// huge or multi-line input can never grow the summary the UI keys and lays
/// out on every poll.
const _summaryMaxLength = 100;

/// A one-line summary for a tool_use entry, keyed by tool name. Every
/// accessor tolerates missing or wrong-shaped input rather than throwing, and
/// every return value is collapsed to its first line and length-capped.
String toolUseSummary(String name, Map<String, dynamic> input) {
  switch (name) {
    case 'Read':
    case 'Edit':
    case 'Write':
      return _summarize(input['file_path']);
    case 'Bash':
      return _summarize(input['command']);
    case 'Grep':
    case 'Glob':
      return _summarize(input['pattern']);
    case 'Task':
      return _summarize(input['description']);
    case 'WebFetch':
      return _summarize(input['url']);
    case 'WebSearch':
      return _summarize(input['query']);
    case 'AskUserQuestion':
      final questions = input['questions'];
      if (questions is List && questions.isNotEmpty) {
        final first = questions.first;
        if (first is Map) {
          return _summarize(first['question']);
        }
      }
      return '';
    default:
      for (final value in input.values) {
        if (value is String) return _summarize(value);
      }
      return '';
  }
}

String _summarize(dynamic value) =>
    _truncate(_firstLine(_asString(value)), _summaryMaxLength);

String _asString(dynamic value) => value is String ? value : '';

String _firstLine(String text) => text.split('\n').first;

String _truncate(String text, int maxLength) =>
    text.length <= maxLength ? text : '${text.substring(0, maxLength)}…';

class NativeTranscript {
  const NativeTranscript(this.entries);

  final List<TranscriptEntry> entries;

  /// Compat view for UI code that only renders chat messages.
  List<TranscriptMessage> get messages =>
      entries.whereType<TranscriptMessage>().toList();
}

/// A native agent-specific transcript source. More agent formats can be
/// added without coupling their parsing or storage details to the screen.
/// Resolved per agent by an `AgentAdapter`'s `createNativeHistory` factory —
/// see `NativeHistoryCapability` and `NativeTranscriptHistory`.
abstract interface class NativeTranscriptAdapter {
  Future<NativeTranscript?> load(AgentInfo agent);
}
