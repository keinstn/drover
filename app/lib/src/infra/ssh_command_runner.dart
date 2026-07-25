import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../herdr/command_runner.dart';
import '../models/host_config.dart';
import '../models/remote_dir_entry.dart';
import '../utils/mutex.dart';

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

/// Decodes a remote output stream as UTF-8, replacing malformed sequences
/// instead of throwing: a Japanese-locale Windows host's cmd.exe emits CP932
/// error text, which strict UTF-8 decoding rejects with a FormatException.
Future<String> decodeRemoteOutput(Stream<Uint8List> stream) =>
    const Utf8Decoder(allowMalformed: true).bind(stream).join();

enum HostKeyDecision { accept, learn, reject }

/// Decides how to treat an observed host-key [observed] fingerprint given the
/// [pinned] one. Null [pinned] = trust-on-first-use (learn it); otherwise
/// accept only an exact match and reject anything else.
HostKeyDecision decideHostKey(String? pinned, String observed) {
  if (pinned == null) return HostKeyDecision.learn;
  return pinned == observed ? HostKeyDecision.accept : HostKeyDecision.reject;
}

/// Thrown when a reconnect presents a different host key than the one trusted
/// on first connection — the trust-on-first-use pin no longer matches, which
/// may signal a man-in-the-middle. Its [toString] names both fingerprints.
class SshHostKeyMismatchException implements Exception {
  SshHostKeyMismatchException({required this.expected, required this.observed});
  final String expected;
  final String observed;
  @override
  String toString() =>
      'Host key verification failed: the server presented a different key '
      'than the one trusted on first connection.\n'
      'Expected: $expected\nReceived: $observed';
}

/// Runs [body], and if it throws [SSHChannelOpenError] or [TimeoutException]
/// calls [dropClient] before rethrowing — both mean the shared connection is
/// now unusable and must not be reused:
/// - [SSHChannelOpenError]: a channel open was refused (e.g. the server hit
///   its per-connection session limit). The TCP connection stays open, so
///   without dropping it every later call would keep reusing this wedged
///   client and fail identically.
/// - [TimeoutException]: the command exceeded its bound (see
///   [SshCommandRunner._execTimeout]) — dartssh2 gave no other signal that
///   the connection had died.
///
/// Dropping the client is safe in both cases: neither means [body]'s command
/// was ever confirmed to run, so this never risks re-sending a non-idempotent
/// `agent send` / `send-keys` — [body] itself is never retried here, only the
/// stale connection is discarded so the NEXT unrelated call reconnects fresh.
/// Any other exception (the command's own failure) passes through untouched:
/// the connection itself is still fine.
Future<T> runDroppingWedgedClient<T>(
  Future<T> Function() body,
  Future<void> Function() dropClient,
) async {
  try {
    return await body();
  } on SSHChannelOpenError {
    await dropClient();
    rethrow;
  } on TimeoutException {
    await dropClient();
    rethrow;
  }
}

/// Runs [body] bounded by [timeout], and if it does not finish in time calls
/// [closeClient] before rethrowing the [TimeoutException]: a wait that
/// outlived its bound leaves the connection in an indeterminate state — for
/// [SshCommandRunner._connect] a possibly half-authenticated [SSHClient] — so
/// it must be torn down rather than left dangling.
///
/// The [TimeoutException] is deliberately rethrown bare rather than re-typed
/// as an [SshAuthException]: `HerdrClient` wraps it into a cause-bearing
/// `HerdrException('transport', ...)`, which `classifyError` reads as
/// "host connection" — the right message for a network stall. An
/// [SshAuthException] would instead tell the user to check their key.
///
/// Any other failure passes through untouched and [closeClient] is NOT called:
/// those are the caller's own error paths (in [SshCommandRunner._connect], the
/// host-key mismatch and auth-failure handling), which already decide what to
/// tear down.
Future<T> runClosingStalledClient<T>(
  Future<T> Function() body,
  Future<void> Function() closeClient, {
  required Duration timeout,
}) async {
  try {
    return await body().timeout(timeout);
  } on TimeoutException {
    await closeClient();
    rethrow;
  }
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
/// permission prompt twice). Channel-using operations are serialized via
/// [_mutex] so only one channel is ever open at a time on the shared
/// connection.
class SshCommandRunner implements CommandRunner {
  SshCommandRunner(this._config, {this.onHostKeyLearned, Duration? authTimeout})
    : _authTimeout = authTimeout ?? _defaultAuthTimeout;

  final HostConfig _config;

  /// Invoked after a successful connect that learned a host key for the first
  /// time (no fingerprint was pinned), so the caller can persist it.
  final Future<void> Function(String fingerprint)? onHostKeyLearned;

  /// Bound on the auth handshake — see [_defaultAuthTimeout] for the why.
  /// Injectable so a test can stall a real handshake without waiting the
  /// default out on the wall clock; production always takes the default.
  final Duration _authTimeout;

  SSHClient? _client;
  Future<SSHClient>? _connecting;
  final _authNotices = <String>[];
  final _mutex = Mutex();

  late String? _pinnedFingerprint = _config.hostKeyFingerprint;
  String? _learnedThisConnect;
  SshHostKeyMismatchException? _mismatch;

  FutureOr<bool> _verifyHostKey(String type, Uint8List fingerprint) {
    final observed = utf8.decode(fingerprint);
    switch (decideHostKey(_pinnedFingerprint, observed)) {
      case HostKeyDecision.accept:
        return true;
      case HostKeyDecision.learn:
        _learnedThisConnect = observed;
        return true;
      case HostKeyDecision.reject:
        _mismatch = SshHostKeyMismatchException(
          expected: _pinnedFingerprint!,
          observed: observed,
        );
        return false;
    }
  }

  /// Bounds the SSH-level auth handshake that follows a connected TCP socket.
  /// dartssh2 does not bound `client.authenticated` unless asked, so a network
  /// path that dies in exactly that window — socket up, negotiation stalled —
  /// would otherwise wait indefinitely (the same class of gap as
  /// [_execTimeout], on the connect path instead of the exec path). A healthy
  /// handshake is sub-second; 10s matches the `SSHSocket.connect` bound in
  /// [_connect], so neither of the connect path's two network waits can exceed
  /// 10s. (That bounds the waits, not [_connect] as a whole: the synchronous
  /// `SSHKeyPair.fromPem` KDF and the [onHostKeyLearned] storage write are
  /// still unbounded, and run under the same held [_mutex].)
  ///
  /// dartssh2's own opt-in `authTimeout` constructor argument is deliberately
  /// not used: it fails the handshake with an `SSHAuthAbortError`, which is an
  /// [SSHAuthError] and so would land in the clause below and be reported as
  /// a key/passphrase problem. One [runClosingStalledClient] bound also covers
  /// both windows dartssh2 splits between `handshakeTimeout` and `authTimeout`.
  static const _defaultAuthTimeout = Duration(seconds: 10);

  Future<SSHClient> _connect() async {
    _authNotices.clear();
    _learnedThisConnect = null;
    _mismatch = null;
    final socket = await SSHSocket.connect(
      _config.host,
      _config.port,
      timeout: const Duration(seconds: 10),
    );
    final client = SSHClient(
      socket,
      username: _config.user,
      identities: SSHKeyPair.fromPem(_config.privateKeyPem, _config.passphrase),
      onVerifyHostKey: _verifyHostKey,
      onUserauthBanner: _authNotices.add,
      onUserInfoRequest: (req) {
        _authNotices
          ..add(req.name)
          ..add(req.instruction);
        return null;
      },
    );
    try {
      await runClosingStalledClient(
        () => client.authenticated,
        () async => client.close(),
        timeout: _authTimeout,
      );
    } on SSHAuthError catch (e) {
      if (_mismatch != null) {
        client.close();
        throw _mismatch!;
      }
      throw SshAuthException(describeSshAuthFailure(e, _authNotices));
    } catch (_) {
      // Also where [_authTimeout]'s TimeoutException lands (it is not an
      // [SSHAuthError], so the clause above cannot shadow it): a host-key
      // mismatch still wins, and anything else propagates unchanged —
      // [runClosingStalledClient] has already closed the client on timeout.
      if (_mismatch != null) {
        client.close();
        throw _mismatch!;
      }
      rethrow;
    }
    final learned = _learnedThisConnect;
    if (learned != null) {
      _pinnedFingerprint = learned; // verify future reconnects on this runner
      _learnedThisConnect = null;
      await onHostKeyLearned?.call(learned);
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

  /// Bounds a single command's channel-open + exec wait. dartssh2 has no
  /// built-in timeout on `execute()`/`session.done`: a network path that dies
  /// mid-command otherwise waits indefinitely for dartssh2's own internal
  /// dead-connection detection, which is not guaranteed to happen promptly (a
  /// real-device repro of a VPN drop mid-session observed a ~17s stall with
  /// zero signal, and because this runs under [_mutex] it blocks every other
  /// operation on this connection — including a user-initiated retry — for
  /// the whole stall). 15s is well above observed real-world command latency
  /// (~150-200ms) and the same order of magnitude as [_connect]'s socket
  /// timeout below.
  static const _execTimeout = Duration(seconds: 15);

  Future<CommandResult> _execute(
    SSHClient client,
    String command, {
    String? stdin,
  }) {
    return Future(() async {
      final session = await client.execute(command);
      if (stdin != null) {
        session.stdin.add(utf8.encode(stdin));
        await session.stdin.close();
      }
      final stdoutFuture = decodeRemoteOutput(session.stdout);
      final stderrFuture = decodeRemoteOutput(session.stderr);
      await session.done;
      return CommandResult(
        exitCode: session.exitCode ?? -1,
        stdout: await stdoutFuture,
        stderr: await stderrFuture,
      );
    }).timeout(_execTimeout);
  }

  /// Runs [body] with the shared client, serialized on [_mutex] so at most one
  /// channel is ever open at a time.
  Future<T> _withClient<T>(Future<T> Function(SSHClient client) body) {
    return _mutex.run(() async {
      final client = await _ensureClient();
      return runDroppingWedgedClient(() => body(client), dispose);
    });
  }

  @override
  Future<CommandResult> run(String command) =>
      _withClient((client) => _execute(client, command));

  @override
  Future<CommandResult> runWithStdin(String command, String stdin) =>
      _withClient((client) => _execute(client, command, stdin: stdin));

  @override
  Future<void> uploadFile(String remotePath, List<int> bytes) {
    return _withClient((client) async {
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
        await sftp.close();
      }
    });
  }

  @override
  Future<List<RemoteDirEntry>> listDirectory(String path) {
    return _withClient((client) async {
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
        await sftp.close();
      }
    });
  }

  @override
  Future<String> resolvePath(String path) {
    return _withClient((client) async {
      final sftp = await client.sftp();
      try {
        return await sftp.absolute(path);
      } finally {
        await sftp.close();
      }
    });
  }

  @override
  Future<RemoteFileStat> statFile(String path) {
    return _withClient((client) async {
      final sftp = await client.sftp();
      try {
        final attrs = await sftp.stat(path);
        final size = attrs.size;
        if (size == null) throw StateError('Remote file size is unavailable');
        return RemoteFileStat(size: size);
      } finally {
        await sftp.close();
      }
    });
  }

  @override
  Future<List<int>> readFile(String path, {int offset = 0, int? length}) {
    return _withClient((client) async {
      final sftp = await client.sftp();
      try {
        final file = await sftp.open(path);
        try {
          return await file.readBytes(offset: offset, length: length);
        } finally {
          await file.close();
        }
      } finally {
        await sftp.close();
      }
    });
  }

  @override
  Future<void> dispose() async {
    _client?.close();
    _client = null;
    _connecting = null;
  }
}
