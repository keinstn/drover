// Selects and retains the appropriate native-history adapter for one agent
// session, resolved through the compile-time [AgentAdapter] registry rather
// than a raw agent-name lookup.

import 'dart:async';

import '../herdr/command_runner.dart';
import '../herdr/host_platform.dart';
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
  /// [platform] assembles OS-specific transcript-location commands for the
  /// SSH target. The host OS is a runtime property of that target, so
  /// production passes `HerdrClient.hostPlatform` (a [Future] is accepted so
  /// construction can stay synchronous); the Unix default preserves behavior
  /// for tests and previews. The `..ignore()` prevents an unhandled-async-
  /// error crash if detection fails before any load runs — later awaits
  /// still receive the error.
  NativeTranscriptHistory(
    this._runner, {
    AgentAdapter? Function(AgentInfo agent)? resolveAdapter,
    FutureOr<HostPlatform> platform = const UnixHostPlatform(),
  }) : _resolveAdapter = resolveAdapter ?? resolveAgentAdapter,
       _platform = Future<HostPlatform>.value(platform)..ignore();

  final CommandRunner _runner;
  final Future<HostPlatform> _platform;
  final AgentAdapter? Function(AgentInfo agent) _resolveAdapter;
  final _mutex = Mutex();
  NativeTranscriptAdapter? _adapter;
  String? _identity;
  bool _resolved = false;
  NativeTranscript? _latest;

  /// The most recently loaded/merged transcript, or null before any [load]
  /// has returned one. Captured inside the [_mutex]-serialized [load] and
  /// [loadOlder] paths, so a caller reading it never sees a torn snapshot.
  /// Lets `HerdScreen` derive a best-effort activity snippet for an already-
  /// opened pane from cache, without itself loading native history on the
  /// poll (which would contend for the single serialized SSH channel).
  NativeTranscript? get latest => _latest;

  Future<NativeTranscript?> load(AgentInfo agent) {
    return _mutex.run(() async {
      final identity = _identityFor(agent);
      if (!_resolved || identity != _identity) {
        final platform = await _platform;
        _resolved = true;
        _identity = identity;
        _adapter = _resolveAdapter(
          agent,
        )?.createNativeHistory(_runner, platform, agent);
        // A new session identity invalidates the cached snapshot: [latest]
        // must never serve the previous session's transcript.
        _latest = null;
      }
      final result = await (_adapter?.load(agent) ?? Future.value(null));
      if (result != null) _latest = result;
      return result;
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
    return _mutex.run(() async {
      if (!_resolved || _identityFor(agent) != _identity) {
        return null;
      }
      final result = await (_adapter?.loadOlder(agent) ?? Future.value(null));
      if (result != null) _latest = result;
      return result;
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
