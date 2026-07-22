// The compile-time registry of known agent adapters, consulted in order to
// resolve one [AgentInfo] to the adapter that supports it.

import '../models/agent_info.dart';
import 'agent_adapter.dart';
import 'claude/claude_adapter.dart';
import 'codex/codex_adapter.dart';
import 'copilot/copilot_adapter.dart';

/// Every known [AgentAdapter], in resolution order. Add a new agent's
/// adapter here to register it — no other wiring is required.
const _adapters = <AgentAdapter>[
  ClaudeAgentAdapter(),
  CopilotAgentAdapter(),
  CodexAgentAdapter(),
];

/// Resolves the [AgentAdapter] that supports [agent] by [AgentAdapter.supports],
/// or null if none does. An unrecognized agent falls back entirely to
/// AgentScreen's generic pane-text behavior.
AgentAdapter? resolveAgentAdapter(AgentInfo agent) {
  for (final adapter in _adapters) {
    if (adapter.supports(agent)) return adapter;
  }
  return null;
}
