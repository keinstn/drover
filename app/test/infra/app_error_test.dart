import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/infra/app_error.dart';
import 'package:drover/src/infra/ssh_command_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyError', () {
    test('bare host-key mismatch classifies as hostKeyMismatch', () {
      final error = SshHostKeyMismatchException(
        expected: 'aa:bb',
        observed: 'cc:dd',
      );
      expect(classifyError(error), AppErrorKind.hostKeyMismatch);
    });

    test('bare auth failure classifies as sshAuth', () {
      expect(classifyError(SshAuthException('nope')), AppErrorKind.sshAuth);
    });

    test('wrapped host-key mismatch classifies as hostKeyMismatch', () {
      final error = HerdrException(
        'transport',
        'msg',
        cause: SshHostKeyMismatchException(expected: 'aa', observed: 'bb'),
      );
      expect(classifyError(error), AppErrorKind.hostKeyMismatch);
    });

    test('wrapped auth failure classifies as sshAuth', () {
      final error = HerdrException(
        'transport',
        'msg',
        cause: SshAuthException('nope'),
      );
      expect(classifyError(error), AppErrorKind.sshAuth);
    });

    test('wrapped generic cause classifies as hostConnection', () {
      final error = HerdrException(
        'transport',
        'msg',
        cause: Exception('socket'),
      );
      expect(classifyError(error), AppErrorKind.hostConnection);
    });

    test('herdr failure without a cause classifies as unknown', () {
      final error = HerdrException('transport', 'herdr failed (exit 1): boom');
      expect(classifyError(error), AppErrorKind.unknown);
    });

    test('non-transport herdr error without a cause classifies as unknown', () {
      final error = HerdrException('agent_pane_busy', 'busy');
      expect(classifyError(error), AppErrorKind.unknown);
    });

    test('a plain exception classifies as unknown', () {
      expect(classifyError(Exception('weird')), AppErrorKind.unknown);
    });
  });

  group('errorDetail', () {
    test('returns the inner message for a causeless HerdrException', () {
      final error = HerdrException('transport', 'clean message');
      expect(errorDetail(error), 'clean message');
    });

    test('returns the cause detail when the transport threw', () {
      final error = HerdrException(
        'transport',
        'x',
        cause: SshAuthException('auth boom'),
      );
      expect(errorDetail(error), contains('auth boom'));
    });
  });
}
