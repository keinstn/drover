// Selects and retains the appropriate native-history adapter for one agent
// session, resolved through the compile-time [AgentAdapter] registry rather
// than a raw agent-name lookup.

import '../herdr/command_runner.dart';
import '../models/agent_info.dart';
import '../transcript/native_transcript.dart';
import '../utils/mutex.dart';
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
///
/// One instance is typically shared (via `HerdScreen`'s per-pane cache)
/// across successive `AgentScreen` instances for the same pane, so a
/// screen-level "single flight" guard alone can't prevent two overlapping
/// mutations: an old screen's still-in-flight (unawaited) load can outlive
/// its `dispose()` and race a new screen instance's own load/loadOlder
/// against the very same adapter/window state. [_mutex] serializes every
/// [load] and [loadOlder] call (including the identity resolution/recheck
/// that decides whether to (re-)create the adapter) at this shared object,
/// so correctness never depends on any one screen's lifecycle.
class NativeTranscriptHistory {
  NativeTranscriptHistory(
    this._runner, {
    AgentAdapter? Function(AgentInfo agent)? resolveAdapter,
  }) : _resolveAdapter = resolveAdapter ?? resolveAgentAdapter;

  final CommandRunner _runner;
  final AgentAdapter? Function(AgentInfo agent) _resolveAdapter;
  final _mutex = Mutex();
  NativeTranscriptAdapter? _adapter;
  String? _identity;
  bool _resolved = false;

  Future<NativeTranscript?> load(AgentInfo agent) {
    return _mutex.run(() {
      final identity = _identityFor(agent);
      if (!_resolved || identity != _identity) {
        _resolved = true;
        _identity = identity;
        _adapter = _resolveAdapter(agent)?.createNativeHistory(_runner, agent);
      }
      return _adapter?.load(agent) ?? Future.value(null);
    });
  }

  /// Whether the currently-resolved adapter has an older, not-yet-loaded
  /// chunk of history before what [load] has fetched so far. False until an
  /// adapter has been resolved and completed an initial [load], and false
  /// once the beginning of its history has been reached. A plain read of the
  /// currently-resolved adapter's state (not gated on [_mutex]) — Dart's
  /// single-threaded execution means it always sees either the pre- or
  /// post-mutation snapshot, never a torn one, and every mutation it might
  /// observe went through the same serialized [load]/[loadOlder] path.
  bool get hasOlderHistory => _adapter?.hasOlderHistory ?? false;

  /// Fetches and prepends the next older bounded chunk from the
  /// currently-resolved adapter, or null if there is nothing older to load
  /// (also true if no adapter has been resolved yet for [agent]). Unlike
  /// [load], this never (re-)resolves the adapter — pull-to-load-more only
  /// ever pages further into whatever history the last [load] established.
  /// Serialized against every other [load]/[loadOlder] call via [_mutex] —
  /// see the class doc.
  Future<NativeTranscript?> loadOlder(AgentInfo agent) {
    return _mutex.run(() {
      if (!_resolved || _identityFor(agent) != _identity) {
        return Future.value(null);
      }
      return _adapter?.loadOlder(agent) ?? Future.value(null);
    });
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
