import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:drover/src/infra/ssh_command_runner.dart';
import 'package:drover/src/models/host_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// A throwaway, publicly-published ed25519 key: verbatim
/// `test/fixtures/ssh-ed25519/id_ed25519` from the dartssh2 2.22.3 package.
/// It exists only so `SSHKeyPair.fromPem` — which `_connect` calls before the
/// auth wait — has something parseable; it authenticates nothing anywhere.
const _testPrivateKeyPem = '''
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACBZnnnYZjFQ7Zt0gMyJ2YYmDINTucLFWY81/Wuv2aOIpAAAAKBQ6gOSUOoD
kgAAAAtzc2gtZWQyNTUxOQAAACBZnnnYZjFQ7Zt0gMyJ2YYmDINTucLFWY81/Wuv2aOIpA
AAAEAP8fq0hjlR3jhL7pg+26PSaMiC1V/RrinVbo/4eBMRNFmeedhmMVDtm3SAzInZhiYM
g1O5wsVZjzX9a6/Zo4ikAAAAGWpmb3V0dHNAVVNBSkZPVVRUU00ubG9jYWwBAgME
-----END OPENSSH PRIVATE KEY-----
''';

void main() {
  group('decodeRemoteOutput', () {
    test('round-trips valid UTF-8 unchanged', () async {
      final text = 'herdr ok これは正常な出力です';
      final stream = Stream<Uint8List>.fromIterable([
        Uint8List.fromList(utf8.encode(text)),
      ]);
      expect(await decodeRemoteOutput(stream), text);
    });

    test('replaces CP932 bytes with U+FFFD instead of throwing', () async {
      // "これ" encoded in Shift-JIS (CP932), as a Japanese-locale cmd.exe
      // emits — invalid as UTF-8.
      final stream = Stream<Uint8List>.fromIterable([
        Uint8List.fromList([0x82, 0xb1, 0x82, 0xea]),
      ]);
      final decoded = await decodeRemoteOutput(stream);
      expect(decoded, contains('�'));
    });
  });

  group('describeSshAuthFailure', () {
    test('returns the error unchanged when there are no notices', () {
      final error = Exception('boom');
      expect(describeSshAuthFailure(error, []), error.toString());
    });

    test('appends a Tailscale-style notice on its own line', () {
      final error = Exception('Connection closed before authentication');
      final result = describeSshAuthFailure(error, [
        'To authenticate, visit: https://login.tailscale.com/a/abc123',
      ]);
      expect(result, startsWith(error.toString()));
      expect(result, contains('https://login.tailscale.com/a/abc123'));
    });

    test(
      'drops whitespace-only notices and de-duplicates while preserving order',
      () {
        final error = 'auth failed';
        final result = describeSshAuthFailure(error, [
          '  ',
          'first notice',
          '',
          'second notice',
          'first notice',
        ]);
        expect(result, 'auth failed\nfirst notice\nsecond notice');
      },
    );
  });

  group('decideHostKey', () {
    test('learns when nothing is pinned', () {
      expect(decideHostKey(null, 'SHA256:abc'), HostKeyDecision.learn);
    });

    test('accepts an exact match', () {
      expect(decideHostKey('SHA256:abc', 'SHA256:abc'), HostKeyDecision.accept);
    });

    test('rejects a different fingerprint', () {
      expect(decideHostKey('SHA256:abc', 'SHA256:xyz'), HostKeyDecision.reject);
    });
  });

  group('runDroppingWedgedClient', () {
    test('returns the body result and never drops on success', () async {
      var dropped = false;
      final result = await runDroppingWedgedClient(
        () async => 'ok',
        () async => dropped = true,
      );
      expect(result, 'ok');
      expect(dropped, isFalse);
    });

    test('drops the client and rethrows on SSHChannelOpenError', () async {
      var dropped = false;
      await expectLater(
        runDroppingWedgedClient(
          () async => throw SSHChannelOpenError(1, 'no such channel'),
          () async => dropped = true,
        ),
        throwsA(isA<SSHChannelOpenError>()),
      );
      expect(dropped, isTrue);
    });

    test('drops the client and rethrows on TimeoutException', () async {
      var dropped = false;
      await expectLater(
        runDroppingWedgedClient(
          () async => throw TimeoutException('exec timed out'),
          () async => dropped = true,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(dropped, isTrue);
    });

    test(
      'does NOT drop the client for an unrelated failure (the command '
      'ran and reported its own error — the connection is still fine)',
      () async {
        var dropped = false;
        await expectLater(
          runDroppingWedgedClient(
            () async => throw StateError('command failed'),
            () async => dropped = true,
          ),
          throwsA(isA<StateError>()),
        );
        expect(dropped, isFalse);
      },
    );
  });

  group('runClosingStalledClient', () {
    test('returns the body result and never closes on success', () async {
      var closed = false;
      final result = await runClosingStalledClient(
        () async => 'ok',
        () async => closed = true,
        timeout: const Duration(seconds: 10),
      );
      expect(result, 'ok');
      expect(closed, isFalse);
    });

    test(
      'closes the client and rethrows when the wait outlives its bound',
      () async {
        var closed = false;
        // Never completes, so the bound is what fires — no race with a source
        // completion landing first.
        final stalled = Completer<void>();
        await expectLater(
          runClosingStalledClient(
            () => stalled.future,
            () async => closed = true,
            timeout: const Duration(milliseconds: 10),
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(closed, isTrue);
      },
    );

    test(
      'does NOT close the client for a non-timeout failure (the caller owns '
      'those paths — e.g. _connect\'s auth / host-key mismatch handling)',
      () async {
        var closed = false;
        await expectLater(
          runClosingStalledClient(
            () async => throw SSHAuthFailError('bad key'),
            () async => closed = true,
            timeout: const Duration(seconds: 10),
          ),
          throwsA(isA<SSHAuthError>()),
        );
        expect(closed, isFalse);
      },
    );
  });

  // A plain [ServerSocket] that accepts the TCP connection and then stays
  // silent — never sending an SSH version banner — reproduces the exact stall
  // SshCommandRunner's auth-handshake bound guards against, through the real
  // dartssh2 client. This is NOT the fake SSH server issue #118 ruled out:
  // nothing here speaks the protocol or completes a handshake.
  group('SshCommandRunner auth-handshake bound', () {
    late ServerSocket server;
    late Completer<void> clientDisconnected;

    setUp(() async {
      clientDisconnected = Completer<void>();
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) {
        void markDisconnected() {
          if (!clientDisconnected.isCompleted) clientDisconnected.complete();
        }

        socket.listen(
          (_) {}, // swallow the client's version banner; never answer it
          onDone: markDisconnected,
          onError: (_) => markDisconnected(),
          cancelOnError: true,
        );
      });
    });

    tearDown(() => server.close());

    test('run() times out and tears the stalled connection down', () async {
      final runner = SshCommandRunner(
        HostConfig(
          host: server.address.address,
          port: server.port,
          user: 'tester',
          privateKeyPem: _testPrivateKeyPem,
        ),
        authTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(runner.dispose);

      await expectLater(
        runner.run('herdr --version'),
        throwsA(isA<TimeoutException>()),
      );
      // The half-authenticated client must actually be closed, not merely
      // abandoned: the server side sees its end of the TCP connection go away.
      await expectLater(
        clientDisconnected.future.timeout(const Duration(seconds: 5)),
        completes,
      );
    });
  });

  group('SshHostKeyMismatchException', () {
    test('toString names both the expected and observed fingerprints', () {
      final ex = SshHostKeyMismatchException(
        expected: 'SHA256:expected',
        observed: 'SHA256:observed',
      );
      expect(ex.toString(), contains('SHA256:expected'));
      expect(ex.toString(), contains('SHA256:observed'));
    });
  });
}
