// Selects and retains the appropriate native-history adapter for one agent
// session, resolved through the compile-time [AgentAdapter] registry rather
// than a raw agent-name lookup.

import '../herdr/command_runner.dart';
import '../models/agent_info.dart';
import '../transcript/native_transcript.dart';
import 'agent_adapter.dart';
import 'agent_registry.dart';

/// Selects and retains the appropriate native adapter for one agent session,
/// re-creating it whenever the session identity changes (a new agent, a
/// restarted session, etc.).
///
/// The registry is consulted on the very first [load] call regardless of
/// whether [sessionIdentityFor] resolves to a session-backed identity or
/// null — a future agent adapter may not require an `agent_session` at all,
/// so "no session yet" must not be confused with "not yet resolved". A
/// [resolved] flag (rather than keying off a nullable identity) tracks that
/// distinction, and the cache key folds in the agent kind so switching
/// between two different agents that both lack a session still re-resolves.
class NativeTranscriptHistory {
  NativeTranscriptHistory(
    this._runner, {
    AgentAdapter? Function(AgentInfo agent)? resolveAdapter,
  }) : _resolveAdapter = resolveAdapter ?? resolveAgentAdapter;

  final CommandRunner _runner;
  final AgentAdapter? Function(AgentInfo agent) _resolveAdapter;
  NativeTranscriptAdapter? _adapter;
  String? _identity;
  bool _resolved = false;

  Future<NativeTranscript?> load(AgentInfo agent) {
    final identity = _identityFor(agent);
    if (!_resolved || identity != _identity) {
      _resolved = true;
      _identity = identity;
      _adapter = _resolveAdapter(agent)?.createNativeHistory(_runner, agent);
    }
    return _adapter?.load(agent) ?? Future.value(null);
  }

  /// The cache key [load] keys adapter (re-)resolution on: the agent kind
  /// plus its session identity (or the empty string when there is none), so
  /// switching to a different agent kind always re-resolves even when
  /// neither the old nor the new agent has a session yet.
  String _identityFor(AgentInfo agent) =>
      '${agent.agent}|${sessionIdentityFor(agent) ?? ''}';

  /// A session-only identity: null when [agent] has no `agent_session`, so
  /// callers (e.g. `AgentScreen`) can tell whether the *same* session is
  /// still loaded across polls, independent of adapter (re-)resolution.
  static String? sessionIdentityFor(AgentInfo agent) {
    final session = agent.agentSession;
    return session == null
        ? null
        : '${session.agent}:${session.kind}:${session.value}';
  }
}
