import 'package:drover/src/infra/ssh_command_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
