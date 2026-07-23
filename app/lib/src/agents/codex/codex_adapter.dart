// The Codex CLI agent adapter: wires up Codex's native transcript loader,
// interaction-mode, image-attachment, and structured-prompt capabilities
// behind the common [AgentAdapter] contract.

import '../../herdr/command_runner.dart';
import '../../herdr/host_platform.dart';
import '../../models/agent_info.dart';
import '../agent_adapter.dart';
import '../agent_capabilities.dart';
import 'codex_images.dart';
import 'codex_mode.dart';
import 'codex_structured_prompt.dart';
import 'codex_transcript.dart';

class CodexAgentAdapter extends AgentAdapter {
  const CodexAgentAdapter();

  @override
  bool supports(AgentInfo agent) => agent.agent == 'codex';

  @override
  NativeHistoryCapability? createNativeHistory(
    CommandRunner runner,
    HostPlatform platform,
    AgentInfo agent,
  ) {
    return CodexTranscriptLoader.supportsAgent(agent)
        ? CodexTranscriptLoader(runner, platform: platform)
        : null;
  }

  @override
  AgentModeCapability get mode => const CodexModeCapability();

  @override
  StructuredPromptCapability get structuredPrompt =>
      const CodexStructuredPromptCapability();

  @override
  ImageAttachmentCapability get images =>
      const CodexImageAttachmentCapability();
}
