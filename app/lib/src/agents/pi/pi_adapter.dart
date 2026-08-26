// The pi agent adapter: wires up pi's native transcript loader behind the
// common [AgentAdapter] contract.

import '../../herdr/command_runner.dart';
import '../../herdr/host_platform.dart';
import '../../models/agent_info.dart';
import '../agent_adapter.dart';
import '../agent_capabilities.dart';
import 'pi_transcript.dart';

/// Native history is pi's only capability for now.
///
/// [mode] stays null because pi has no built-in cyclable interaction mode
/// (plan mode is a third-party extension), which hides the mode control.
/// [structuredPrompt] stays null because pi's `ask_question` prompt UI is
/// deliberately out of scope for this phase, so AgentScreen's generic
/// numbered-prompt pane-text fallback applies. [images] stays null because
/// pi's `@path` attachment convention is unverified in the TUI composer,
/// which hides the attach-image affordance. Only [structuredPrompt] has a
/// fallback; the other two are simply absent — see `agent_capabilities.dart`.
class PiAgentAdapter extends AgentAdapter {
  const PiAgentAdapter();

  @override
  bool supports(AgentInfo agent) => agent.agent == 'pi';

  @override
  NativeHistoryCapability? createNativeHistory(
    CommandRunner runner,
    HostPlatform platform,
    AgentInfo agent,
  ) {
    // [platform] is unused: herdr reports pi's session as `kind:'path'`, so
    // the loader validates that path instead of running an OS-specific
    // lookup command.
    return PiTranscriptLoader.supportsAgent(agent)
        ? PiTranscriptLoader(runner)
        : null;
  }
}
