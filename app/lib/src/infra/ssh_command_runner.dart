import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../herdr/command_runner.dart';
import '../models/host_config.dart';
import '../models/remote_dir_entry.dart';

/// Composes a diagnostic message from an SSH auth failure and any notices the
/// server sent during the attempt (userauth banner or keyboard-interactive
/// text) — e.g. a Tailscale SSH "visit this URL to authenticate" message,
/// which dartssh2 otherwise drops, leaving only an opaque
/// "Connection closed before authentication".
String describeSshAuthFailure(Object error, List<String> notices) {
  final seen = <String>{};
  final extra = <String>[];
  for (final n in notices) {
    final t = n.trim();
    if (t.isEmpty || !seen.add(t)) continue;
    extra.add(t);
  }
  if (extra.isEmpty) return error.toString();
  return '$error\n${extra.join('\n')}';
}

/// Thrown when the SSH connection fails during authentication, carrying any
/// server-sent notices (see [describeSshAuthFailure]). Its [toString] is the
/// composed message verbatim (no prefix) because [HerdrClient] re-wraps it.
class SshAuthException implements Exception {
  SshAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

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
  final _authNotices = <String>[];

  Future<SSHClient> _connect() async {
    _authNotices.clear();
    final socket = await SSHSocket.connect(
      _config.host,
      _config.port,
      timeout: const Duration(seconds: 10),
    );
    final client = SSHClient(
      socket,
      username: _config.user,
      identities: SSHKeyPair.fromPem(_config.privateKeyPem, _config.passphrase),
      onUserauthBanner: _authNotices.add,
      onUserInfoRequest: (req) {
        _authNotices
          ..add(req.name)
          ..add(req.instruction);
        return null;
      },
    );
    try {
      await client.authenticated;
    } on SSHAuthError catch (e) {
      throw SshAuthException(describeSshAuthFailure(e, _authNotices));
    }
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
  Future<void> uploadFile(String remotePath, List<int> bytes) async {
    final client = await _ensureClient();
    final sftp = await client.sftp();
    try {
      final file = await sftp.open(
        remotePath,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      try {
        await file.writeBytes(Uint8List.fromList(bytes));
      } finally {
        await file.close();
      }
    } finally {
      sftp.close();
    }
  }

  @override
  Future<List<RemoteDirEntry>> listDirectory(String path) async {
    final client = await _ensureClient();
    final sftp = await client.sftp();
    try {
      final names = await sftp.listdir(path);
      return names
          .where((n) => n.filename != '.' && n.filename != '..')
          .map(
            (n) => RemoteDirEntry(
              name: n.filename,
              isDirectory: n.attr.isDirectory,
            ),
          )
          .toList();
    } finally {
      sftp.close();
    }
  }

  @override
  Future<String> resolvePath(String path) async {
    final client = await _ensureClient();
    final sftp = await client.sftp();
    try {
      return await sftp.absolute(path);
    } finally {
      sftp.close();
    }
  }

  @override
  Future<RemoteFileStat> statFile(String path) async {
    final client = await _ensureClient();
    final sftp = await client.sftp();
    try {
      final attrs = await sftp.stat(path);
      final size = attrs.size;
      if (size == null) throw StateError('Remote file size is unavailable');
      return RemoteFileStat(size: size);
    } finally {
      sftp.close();
    }
  }

  @override
  Future<List<int>> readFile(String path, {int offset = 0}) async {
    final client = await _ensureClient();
    final sftp = await client.sftp();
    try {
      final file = await sftp.open(path);
      try {
        return await file.readBytes(offset: offset);
      } finally {
        await file.close();
      }
    } finally {
      sftp.close();
    }
  }

  @override
  Future<void> dispose() async {
    _client?.close();
    _client = null;
    _connecting = null;
  }
}
