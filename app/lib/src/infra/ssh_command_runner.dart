import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../herdr/command_runner.dart';
import '../models/host_config.dart';

/// [CommandRunner] backed by an SSH connection to a [HostConfig] host.
/// Connects lazily on first [run] and caches the client; a stale cached
/// client (closed since it was last used) is reconnected before the command
/// executes. Concurrent first-callers await the same in-flight connect
/// (via [_connecting]) rather than each opening their own SSHClient, so a
/// cold start never leaks an orphaned connection. Once a command has started
/// executing it is NEVER retried: `herdr agent send` / `pane send-keys` are
/// not idempotent, and re-sending after an SSH drop mid-execute could
/// double-type keystrokes into an agent's pane (e.g. answering the same
/// permission prompt twice).
class SshCommandRunner implements CommandRunner {
  SshCommandRunner(this._config);

  final HostConfig _config;
  SSHClient? _client;
  Future<SSHClient>? _connecting;

  Future<SSHClient> _connect() async {
    final socket = await SSHSocket.connect(
      _config.host,
      _config.port,
      timeout: const Duration(seconds: 10),
    );
    final client = SSHClient(
      socket,
      username: _config.user,
      identities: SSHKeyPair.fromPem(
        _config.privateKeyPem,
        _config.passphrase,
      ),
    );
    await client.authenticated;
    return client;
  }

  Future<SSHClient> _ensureClient() async {
    final cached = _client;
    if (cached != null && cached.isClosed) {
      await dispose();
    }
    if (_client != null) return _client!;
    if (_connecting != null) return _connecting!;

    _connecting = _connect();
    try {
      _client = await _connecting;
      return _client!;
    } finally {
      _connecting = null;
    }
  }

  Future<CommandResult> _execute(SSHClient client, String command) async {
    final session = await client.execute(command);
    final stdoutFuture = utf8.decodeStream(session.stdout);
    final stderrFuture = utf8.decodeStream(session.stderr);
    await session.done;
    return CommandResult(
      exitCode: session.exitCode ?? -1,
      stdout: await stdoutFuture,
      stderr: await stderrFuture,
    );
  }

  @override
  Future<CommandResult> run(String command) async {
    final client = await _ensureClient();
    return _execute(client, command);
  }

  @override
  Future<void> dispose() async {
    _client?.close();
    _client = null;
    _connecting = null;
  }
}
