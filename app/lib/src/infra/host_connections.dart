import 'dart:async';

import '../herdr/herdr_client.dart';
import '../models/host_config.dart';
import 'ssh_command_runner.dart';

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
}
