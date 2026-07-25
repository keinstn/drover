import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:drover/src/infra/ssh_command_runner.dart';
import 'package:flutter_test/flutter_test.dart';

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
