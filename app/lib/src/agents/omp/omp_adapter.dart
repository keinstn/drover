// The omp ("Oh My Pi") agent adapter: wires up omp's native transcript loader
// behind the common [AgentAdapter] contract.

import '../../herdr/command_runner.dart';
import '../../herdr/host_platform.dart';
import '../../models/agent_info.dart';
import '../agent_adapter.dart';
import '../agent_capabilities.dart';
// omp is pi's successor and its herdr integration emits the same `kind:'path'`
// session pointing at the same JSONL record format, so the pi loader serves
// both — bound to `'omp'` here instead of being copied.
import '../pi/pi_transcript.dart';

/// Native history is omp's only capability, for the same three reasons pi has
/// none of the others.
///
/// [mode] stays null because shift+tab in omp cycles the *thinking level*,
/// not an interaction mode — there is no mode line to parse, so the mode
/// control stays hidden. [structuredPrompt] stays null because omp's built-in
/// `ask` tool renders an arrow-key dialog (`Enter select · n note · ↑/↓ move ·
/// Esc cancel`) rather than a numbered list, so drover's generic
/// numbered-prompt pane-text fallback does not detect it either — it has to be
/// answered with arrow keys in the live terminal. [images] stays null because
/// omp takes attachments as `@path` args, unverified in the TUI composer.
class OmpAgentAdapter extends AgentAdapter {
  const OmpAgentAdapter();

  @override
  bool supports(AgentInfo agent) => agent.agent == 'omp';

  @override
  NativeHistoryCapability? createNativeHistory(
    CommandRunner runner,
    HostPlatform platform,
    AgentInfo agent,
  ) {
    // [platform] is unused: like pi, herdr reports omp's session as
    // `kind:'path'`, so the loader validates that path instead of running an
    // OS-specific lookup command.
    return PiTranscriptLoader.supportsAgent(agent, agentName: 'omp')
        ? PiTranscriptLoader(runner, agentName: 'omp')
        : null;
  }
}
