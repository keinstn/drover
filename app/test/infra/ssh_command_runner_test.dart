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

  group('installIfCurrent', () {
    test('returns the client when the generation has not moved', () async {
      var closed = false;
      final client = await installIfCurrent<String>(
        Future.value('client'),
        startedAt: 0,
        generation: () => 0,
        close: (_) => closed = true,
      );
      expect(client, 'client');
      expect(closed, isFalse);
    });

    test('closes the client and throws when invalidation raced the connect '
        '(generation moved before the connect resolved)', () async {
      var closed = false;
      var generation = 0;
      final completer = Completer<String>();

      final result = installIfCurrent<String>(
        completer.future,
        startedAt: 0,
        generation: () => generation,
        close: (_) => closed = true,
      );

      // Invalidation happens while the connect is still in flight...
      generation = 1;
      // ...and only then does the connect resolve (with a client built
      // over the now-stale network path).
      completer.complete('client');

      await expectLater(result, throwsA(isA<StateError>()));
      expect(closed, isTrue);
    });
  });

  // Regression coverage for invalidateConnection() called mid-connect: this
  // does NOT exercise installIfCurrent's generation-mismatch branch itself
  // (here the in-flight connect ends in the pre-existing authTimeout
  // TimeoutException, not a successful-but-stale resolve — see the
  // `installIfCurrent` group above for that exact race). What this proves is
  // the runner-level bookkeeping around it: invalidating mid-connect leaves
  // the runner cleanly reconnectable rather than wedged.
  group(
    'SshCommandRunner: invalidateConnection during an in-flight connect',
    () {
      test('fails that call; the next call reconnects rather than reusing '
          'stale state', () async {
        var acceptCount = 0;
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);
        server.listen((socket) {
          acceptCount++;
          socket.listen((_) {}, cancelOnError: true); // swallow, never answer
        });

        final runner = SshCommandRunner(
          HostConfig(
            host: server.address.address,
            port: server.port,
            user: 'tester',
            privateKeyPem: _testPrivateKeyPem,
          ),
          authTimeout: const Duration(milliseconds: 150),
        );
        addTearDown(runner.dispose);

        final firstRun = runner.run('herdr --version');
        // Let _connect() open the TCP socket and start awaiting the (never
        // arriving) handshake before invalidating mid-flight.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await runner.invalidateConnection();

        await expectLater(firstRun, throwsA(anything));
        expect(acceptCount, 1);

        final secondRun = runner.run('herdr --version');
        await expectLater(secondRun, throwsA(anything));
        expect(
          acceptCount,
          2,
          reason:
              'the second call must open a fresh connection, not reuse '
              'or wedge on the invalidated one',
        );
      });
    },
  );

  group('SshCommandRunner: invalidateConnection with no cached client', () {
    // This does NOT (and cannot, in this suite) exercise the harmful old
    // behaviour directly: that only manifests when a connect invalidated
    // mid-flight goes on to actually SUCCEED (installIfCurrent's generation
    // check only runs after `connecting` resolves — a failing connect
    // rethrows before that check, so old and new invalidateConnection()
    // behaviour are externally identical on every failure path). Simulating
    // a successful handshake needs a real SSH server, which this file's own
    // auth-handshake-bound tests above deliberately avoid building (see the
    // "fake SSH server issue #118 ruled out" comment). The generation
    // mismatch mechanics themselves are covered directly by the
    // `installIfCurrent` group. This test instead covers what IS observable
    // here: the no-op guard doesn't corrupt anything on the failure path
    // this suite can produce.
    test('is a no-op with no cached client, and does not disturb a normal '
        'reconnect afterward', () async {
      var acceptCount = 0;
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((socket) {
        acceptCount++;
        socket.listen((_) {}, cancelOnError: true); // swallow, never answer
      });

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

      // Nothing has ever connected, so _client and _connecting are both
      // null: this must complete without error.
      await runner.invalidateConnection();

      // A following run() still dials exactly once and fails the normal
      // way (auth-handshake timeout) — the no-op guard hasn't left the
      // runner in some broken state.
      await expectLater(
        runner.run('herdr --version'),
        throwsA(isA<TimeoutException>()),
      );
      expect(acceptCount, 1);

      // Calling it again afterward (still no cached client — the run()
      // above already failed and cleared it) is likewise inert.
      await runner.invalidateConnection();

      await expectLater(
        runner.run('herdr --version'),
        throwsA(isA<TimeoutException>()),
      );
      expect(acceptCount, 2, reason: 'the second call reconnects fresh');
    });
  });

  group('SshCommandRunner: dispose() is unconditional, unlike '
      'invalidateConnection()', () {
    // As with the invalidateConnection group above, the property this exists
    // to guard — that dispose() discards an in-flight connect that goes on to
    // SUCCEED, so it can't install an [SSHClient] into a runner nothing holds
    // a reference to any more (a leaked SSH connection) — is NOT verified
    // here: `installIfCurrent`'s generation check only runs once `connecting`
    // resolves, and a failing connect (all this suite can produce without a
    // real SSH server) rethrows before that check, making dispose()'s old
    // (shared-with-invalidateConnection) and new (independent) behaviour
    // externally identical on that path. These tests instead cover what IS
    // observable: dispose() completes cleanly with no cached client, both at
    // rest and mid-connect, and doesn't corrupt the runner's ability to
    // reconnect — regression coverage for the two implementations no longer
    // sharing code, not a discriminator for the leak this guards against.
    test('completes without error when there is no cached client and '
        'nothing in flight', () async {
      final runner = SshCommandRunner(
        HostConfig(
          host: '127.0.0.1',
          port: 1,
          user: 'tester',
          privateKeyPem: _testPrivateKeyPem,
        ),
      );
      await runner.dispose();
    });

    test('during an in-flight connect (no cached client yet) still tears down '
        'cleanly', () async {
      var acceptCount = 0;
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((socket) {
        acceptCount++;
        socket.listen((_) {}, cancelOnError: true); // swallow, never answer
      });

      final runner = SshCommandRunner(
        HostConfig(
          host: server.address.address,
          port: server.port,
          user: 'tester',
          privateKeyPem: _testPrivateKeyPem,
        ),
        authTimeout: const Duration(milliseconds: 150),
      );

      final firstRun = runner.run('herdr --version');
      // Let _connect() open the TCP socket and start awaiting the (never
      // arriving) handshake before disposing mid-flight.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await runner.dispose();

      await expectLater(firstRun, throwsA(anything));
      expect(acceptCount, 1);

      // The runner is not meant to be reused after dispose() in
      // production, but proving it isn't left half-torn-down (e.g. a
      // second dispose() hanging or throwing) is cheap and worthwhile.
      await runner.dispose();
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
