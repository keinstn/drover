// The GitHub Copilot CLI agent adapter: wires up Copilot's native transcript
// loader, interaction-mode, structured-prompt (ask_user), and
// image-attachment capabilities behind the common [AgentAdapter] contract.

import '../../herdr/command_runner.dart';
import '../../herdr/herdr_client.dart';
import '../../models/agent_info.dart';
import '../agent_adapter.dart';
import '../agent_capabilities.dart';
import 'copilot_images.dart';
import 'copilot_mode.dart';
import 'copilot_structured_prompt.dart';
import 'copilot_transcript.dart';

/// Terminal focus-reporting (DEC mode 1004) escapes: herdr sends "focus lost"
/// to any pane that isn't the currently-focused one, and the Copilot CLI
/// discards typed input while it believes it is unfocused. Bracketing a
/// prompt with a synthetic focus-gained/focus-lost pair makes Copilot accept
/// and submit it even when its pane is a backgrounded split — harmless when
/// the pane is actually focused, so no background-state detection is needed.
///
/// TEMPORARY workaround for ogulcancelik/herdr#1698; remove once herdr stops
/// reporting focus-lost to backgrounded panes (or Copilot stops discarding
/// input while "unfocused").
const _focusGained = '\x1b[I';
const _focusLost = '\x1b[O';

class CopilotAgentAdapter extends AgentAdapter {
  const CopilotAgentAdapter();

  @override
  bool supports(AgentInfo agent) => agent.agent == 'copilot';

  @override
  NativeHistoryCapability? createNativeHistory(
    CommandRunner runner,
    AgentInfo agent,
  ) {
    return CopilotTranscriptLoader.supportsAgent(agent)
        ? CopilotTranscriptLoader(runner)
        : null;
  }

  @override
  AgentModeCapability get mode => const CopilotModeCapability();

  @override
  StructuredPromptCapability get structuredPrompt =>
      const CopilotStructuredPromptCapability();

  @override
  ImageAttachmentCapability get images =>
      const CopilotImageAttachmentCapability();

  @override
  Future<void> deliverPrompt(
    HerdrClient client,
    String paneId,
    String text,
  ) async {
    await client.sendPaneText(paneId, _focusGained);
    await client.prompt(paneId, text);
    await client.sendPaneText(paneId, _focusLost);
  }
}
