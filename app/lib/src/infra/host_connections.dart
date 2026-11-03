import 'dart:async';

import '../herdr/command_runner.dart';
import '../herdr/hc_client.dart';
import '../herdr/herdr_backend.dart';
import '../herdr/herdr_client.dart';
import '../herdr/host_platform.dart';
import '../models/host_config.dart';
import 'best_effort.dart';
import 'ssh_command_runner.dart';

/// The client for [host]'s backend: [HcClient] for Herdr 2, else herdr 1's
/// [HerdrClient]. Every client main.dart builds goes through here.
HerdrClient buildHerdrClient(HostConfig host, CommandRunner runner) {
  Future<HostPlatform> platform() => HostPlatform.detect(runner);
  return host.backend == HerdrBackend.hc
      ? HcClient(runner, herdrBin: host.herdrBin, platform: platform)
      : HerdrClient(runner, herdrBin: host.herdrBin, platform: platform);
}

/// Whether a failed herdr 1 connection test means the `herdr` binary itself
/// is missing, as opposed to an SSH/auth/host-key/timeout failure. Those
/// surface as a transport [HerdrException] with the runner's error as its
/// [HerdrException.cause]; a missing binary is the shell's own non-zero exit
/// (127, "not found", "No such file"), which [HerdrClient] reports with no
/// cause.
bool isHerdrBinaryMissing(Object error) =>
    error is HerdrException &&
    error.code == 'transport' &&
    error.cause == null &&
    RegExp(r'exit 127\b|not found|No such file').hasMatch(error.message);

/// Whether the host has Herdr 2's `hc` at its default `~/.local/bin/hc` (the
/// bin a switch to Herdr 2 would use) and no herdr 1 `herdr` anywhere — on the
/// login PATH or in `~/.local/bin`. Unix only: Herdr 2 on Windows hosts is
/// deferred, so a Windows host is never reported hc-only.
Future<bool> hostHasOnlyHc(CommandRunner runner) async {
  final platform = await HostPlatform.detect(runner);
  if (platform is! UnixHostPlatform) return false;
  final onPath = await runner.run(
    platform.detectAgentsCommand(const ['herdr']),
  );
  if (onPath.stdout.split('\n').any((l) => l.trim() == 'herdr')) return false;
  final local = await runner.run(
    "sh -c 'for b in herdr hc; do "
    "[ -x \"\$HOME/.local/bin/\$b\" ] && echo \"\$b\"; done'",
  );
  final found = local.stdout.split('\n').map((l) => l.trim()).toSet();
  return found.contains('hc') && !found.contains('herdr');
}

/// One live connection to one host: the config it was built from plus the
/// runner/client pair speaking to it. Built by the factory main.dart injects
/// into [HostConnectionRegistry].
class HostConnection {
  const HostConnection({
    required this.config,
    required this.runner,
    required this.client,
  });

  final HostConfig config;
  final SshCommandRunner runner;
  final HerdrClient client;
}

/// Caches one [HostConnection] per host id, building lazily on first
/// [obtain]. No mutex needed: the map mutations are synchronous, so Dart's
/// event loop keeps them atomic; the only async part (dispose) happens after
/// removal.
class HostConnectionRegistry {
  HostConnectionRegistry(this._build);

  final HostConnection Function(HostConfig) _build;
  final _connections = <String, HostConnection>{};

  /// Returns the cached connection for [host], building it on first request.
  /// [HostConfig.hostId] must be non-null (every persisted host has one).
  ///
  /// A cached connection whose config no longer matches [host] (per
  /// [HostConfig.sameConnection]) is evicted and rebuilt: a poll racing a
  /// host edit can cache a connection built from the pre-edit config, and
  /// validating here makes the registry self-healing.
  HostConnection obtain(HostConfig host) {
    final hostId = host.hostId;
    if (hostId == null) {
      throw ArgumentError.value(host, 'host', 'hostId must not be null');
    }
    final cached = _connections[hostId];
    if (cached != null && !cached.config.sameConnection(host)) {
      final removed = _connections.remove(hostId)!;
      unawaited(removed.runner.dispose());
    }
    return _connections.putIfAbsent(hostId, () => _build(host));
  }

  /// The cached connection for [hostId], or null if none has been built.
  HostConnection? get(String hostId) => _connections[hostId];

  /// Removes the connection for [hostId] and disposes its runner; no-op if
  /// absent. Used when a host is deleted or its config edited — the next
  /// [obtain] rebuilds with the new config. Removal happens synchronously
  /// before the dispose, so a concurrent [obtain] builds a fresh connection
  /// instead of returning the dying one.
  Future<void> evict(String hostId) async {
    final removed = _connections.remove(hostId);
    if (removed == null) return;
    await removed.runner.dispose();
  }

  /// Evicts every connection (app teardown).
  Future<void> disposeAll() async {
    for (final hostId in _connections.keys.toList()) {
      await evict(hostId);
    }
  }

  /// Invalidates every cached connection's SSH client — closes the socket
  /// but keeps the [HostConnection] (and its [SshCommandRunner] instance) in
  /// the map. Used after an OS-level network change, where every cached
  /// client is equally stale regardless of host.
  ///
  /// Deliberately NOT [evict]/[disposeAll]: those remove the map entry and
  /// let the next [obtain] rebuild a new [HostConnection]/[SshCommandRunner]
  /// pair. `main.dart`'s `_hostRevisions` mechanism treats a rebuilt
  /// connection as a new host "generation" and bumps that host's revision,
  /// which makes the herd screen drop its whole per-host bucket — losing
  /// cached transcript-window state and flickering the agent list back to
  /// loading. `NativeTranscriptHistory` also captures the [SshCommandRunner]
  /// *instance* directly (see `herd_screen.dart`'s `_nativeHistoryFor`), so
  /// swapping the instance would orphan it mid-use. Invalidating the socket
  /// in place — same instance, next call reconnects fresh — avoids all of
  /// that.
  Future<void> invalidateAll() async {
    // Snapshot first, matching disposeAll's `.toList()` above: this method
    // awaits mid-loop, and iterating the map's live values view directly
    // would throw ConcurrentModificationError if obtain()/evict() mutated
    // the map during that await.
    for (final connection in _connections.values.toList()) {
      // Isolate each host's failure (most plausibly SSHClient.close()
      // throwing on exactly this path, where sockets have just died) so one
      // bad host doesn't leave every host after it in the map still stale.
      await runBestEffort(
        connection.runner.invalidateConnection,
        context: 'invalidate connection for ${connection.config.hostId}',
      );
    }
  }
}
