// Compile-time capability contracts an [AgentAdapter] may optionally
// implement. Every capability here is optional: an agent that doesn't
// support it simply leaves the corresponding [AgentAdapter] getter/factory
// null, and the shared UI in AgentScreen falls back to its generic pane-text
// behavior instead of throwing.

import '../herdr/herdr_client.dart';
import '../image/image_input.dart';
import '../models/agent_info.dart';
import '../transcript/native_transcript.dart';

/// The agent's current interaction mode, as shown on a TUI's mode line and
/// cycled by an [AgentModeCapability]. Not every agent exposes a mode; the UI
/// hides mode controls when the resolved [AgentModeCapability] is null (or
/// returns null from [AgentModeCapability.parseMode]) for the current agent.
enum AgentMode {
  normal('normal'),
  autoAccept('auto-accept'),
  plan('plan'),
  bypass('bypass');

  const AgentMode(this.label);

  final String label;
}

/// Reads and cycles an agent's interaction mode. Optional: only agents whose
/// TUI exposes a cyclable mode (e.g. Claude Code's shift+tab modes) implement
/// this.
abstract interface class AgentModeCapability {
  /// Reads the current [AgentMode] from the agent's plain (ANSI-stripped)
  /// pane text, or null if no mode line is present.
  AgentMode? parseMode(String paneText);

  /// Cycles to the next mode by sending whatever keystroke(s) the agent's TUI
  /// expects for [paneId] over [client].
  Future<void> cycleMode(HerdrClient client, String paneId);
}

/// Loads and caches an agent's native, structured transcript history (as
/// opposed to the generic ANSI pane-text fallback). Implementations may
/// retain per-session state (e.g. a byte offset into a session file); one
/// instance is created per agent session — see the session-identity cache in
/// `NativeTranscriptHistory`.
///
/// This is the same shape as [NativeTranscriptAdapter]; the alias keeps the
/// capability naming consistent with the other contracts in this file.
typedef NativeHistoryCapability = NativeTranscriptAdapter;

/// Thrown by a [StructuredPromptCapability.submit] implementation when the
/// live dialog isn't in an expected state. A common marker so AgentScreen can
/// show [message] without depending on any concrete agent's error type.
abstract interface class StructuredPromptSubmitError implements Exception {
  String get message;
}

/// Detects and submits answers to an agent's interactive structured prompt
/// (e.g. Claude Code's AskUserQuestion tool) surfaced through its native
/// transcript history. Optional: agents with no such prompt UI leave this
/// null, and AgentScreen's generic numbered-prompt fallback (parsed from pane
/// text) is used instead.
abstract interface class StructuredPromptCapability {
  /// The last prompt in [history] awaiting an answer, or null if none is
  /// pending.
  StructuredPrompt? pendingPrompt(NativeTranscript history);

  /// Submits [answers] for [prompt] into the live dialog on [paneId] over
  /// [client]. Throws a [StructuredPromptSubmitError] (or another exception)
  /// on failure, leaving the caller's UI state unchanged so it can retry.
  Future<void> submit({
    required HerdrClient client,
    required String paneId,
    required StructuredPrompt prompt,
    required List<StructuredPromptAnswer> answers,
  });
}

/// Sends staged images to the agent as part of a prompt. Optional: agents
/// with no attachment convention leave this null, hiding the composer's
/// attach-image affordance entirely.
abstract interface class ImageAttachmentCapability {
  /// Uploads [images] and prompts [agent] to read them, optionally preceded
  /// by [caption]. Returns the remote paths in upload order. [timestampMs] is
  /// injectable only so tests get a deterministic filename.
  Future<List<String>> send(
    HerdrClient client,
    AgentInfo agent, {
    required List<PickedImage> images,
    String caption = '',
    int? timestampMs,
  });
}
