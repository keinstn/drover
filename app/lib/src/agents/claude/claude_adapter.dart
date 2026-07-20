// The Claude Code agent adapter: wires up Claude's native transcript loader,
// interaction mode, structured-prompt (AskUserQuestion), and image-attachment
// capabilities behind the common [AgentAdapter] contract.

import '../../herdr/command_runner.dart';
import '../../models/agent_info.dart';
import '../agent_adapter.dart';
import '../agent_capabilities.dart';
import 'claude_images.dart';
import 'claude_mode.dart';
import 'claude_structured_prompt.dart';
import 'claude_transcript.dart';

class ClaudeAgentAdapter extends AgentAdapter {
  const ClaudeAgentAdapter();

  @override
  bool supports(AgentInfo agent) => agent.agent == 'claude';

  @override
  NativeHistoryCapability? createNativeHistory(
    CommandRunner runner,
    AgentInfo agent,
  ) {
    return ClaudeTranscriptLoader.supportsAgent(agent)
        ? ClaudeTranscriptLoader(runner)
        : null;
  }

  @override
  AgentModeCapability get mode => const ClaudeModeCapability();

  @override
  StructuredPromptCapability get structuredPrompt =>
      const ClaudeStructuredPromptCapability();

  @override
  ImageAttachmentCapability get images =>
      const ClaudeImageAttachmentCapability();
}
