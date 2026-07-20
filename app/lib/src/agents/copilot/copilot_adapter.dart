// The GitHub Copilot CLI agent adapter: wires up Copilot's native transcript
// loader, interaction-mode, structured-prompt (ask_user), and
// image-attachment capabilities behind the common [AgentAdapter] contract.

import '../../herdr/command_runner.dart';
import '../../models/agent_info.dart';
import '../agent_adapter.dart';
import '../agent_capabilities.dart';
import 'copilot_images.dart';
import 'copilot_mode.dart';
import 'copilot_structured_prompt.dart';
import 'copilot_transcript.dart';

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
}
