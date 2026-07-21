// The compile-time adapter contract for one agent kind, and the shared
// registry that resolves an [AgentInfo] to its adapter by [supports] rather
// than a raw agent-name lookup.

import '../herdr/command_runner.dart';
import '../herdr/herdr_client.dart';
import '../models/agent_info.dart';
import 'agent_capabilities.dart';

/// Declares which optional capabilities (native history, mode, structured
/// prompts, image attachments) one agent kind supports. Every capability
/// defaults to unsupported (null); an adapter only overrides the ones its
/// agent actually implements. Agents with no adapter at all — or whose
/// adapter leaves a capability null — fall back to the shared generic
/// behavior (pane-text transcript, numbered-prompt parsing) in AgentScreen.
abstract class AgentAdapter {
  const AgentAdapter();

  /// Whether this adapter handles [agent].
  bool supports(AgentInfo agent);

  /// Creates a fresh native-history loader for [agent] on [runner], or null
  /// if this adapter has no native transcript source for [agent]. Called
  /// once per agent session by `NativeTranscriptHistory`, which retains the
  /// result across polls.
  NativeHistoryCapability? createNativeHistory(
    CommandRunner runner,
    AgentInfo agent,
  ) => null;

  /// Reads and cycles this agent's interaction mode, or null if it has none.
  AgentModeCapability? get mode => null;

  /// Detects and submits this agent's interactive structured prompts, or
  /// null if it has none.
  StructuredPromptCapability? get structuredPrompt => null;

  /// Sends staged images to this agent, or null if it has no attachment
  /// convention.
  ImageAttachmentCapability? get images => null;

  /// Delivers a plain text prompt to [paneId]. Defaults to the generic
  /// [HerdrClient.prompt]; an adapter overrides this only when its agent needs
  /// special delivery handling.
  Future<void> deliverPrompt(HerdrClient client, String paneId, String text) =>
      client.prompt(paneId, text);
}
