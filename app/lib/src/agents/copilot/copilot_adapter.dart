// The GitHub Copilot CLI agent adapter: wires up Copilot's interaction-mode
// and image-attachment capabilities behind the common [AgentAdapter]
// contract. Native transcript history and structured prompts are not
// implemented for Copilot yet — those capabilities are left at the
// [AgentAdapter] defaults (null), so AgentScreen falls back to its generic
// pane-text/numbered-prompt behavior for them.

import '../../models/agent_info.dart';
import '../agent_adapter.dart';
import '../agent_capabilities.dart';
import 'copilot_images.dart';
import 'copilot_mode.dart';

class CopilotAgentAdapter extends AgentAdapter {
  const CopilotAgentAdapter();

  @override
  bool supports(AgentInfo agent) => agent.agent == 'copilot';

  @override
  AgentModeCapability get mode => const CopilotModeCapability();

  @override
  ImageAttachmentCapability get images =>
      const CopilotImageAttachmentCapability();
}
