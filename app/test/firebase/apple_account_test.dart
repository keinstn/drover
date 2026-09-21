import 'package:drover/src/firebase/apple_account.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records the steps in the order they ran: the ordering is the whole
/// feature, so a set of booleans wouldn't test what matters.
void main() {
  test(
    'a linked account reauthenticates, revokes, deletes, starts over',
    () async {
      final calls = <String>[];
      await deleteAccount(
        appleLinked: true,
        reauthenticate: () async {
          calls.add('reauthenticate');
          return 'apple-code';
        },
        revoke: (code) async {
          expect(code, 'apple-code');
          calls.add('revoke');
        },
        delete: () async => calls.add('delete'),
        startOver: () async => calls.add('startOver'),
      );

      expect(calls, ['reauthenticate', 'revoke', 'delete', 'startOver']);
    },
  );

  test('a revoke that fails still deletes the account', () async {
    final calls = <String>[];
    await deleteAccount(
      appleLinked: true,
      reauthenticate: () async => 'apple-code',
      revoke: (_) async => throw Exception('Apple is unreachable'),
      delete: () async => calls.add('delete'),
      startOver: () async => calls.add('startOver'),
    );

    expect(calls, ['delete', 'startOver']);
  });

  test('a dismissed reauthentication deletes nothing', () async {
    final calls = <String>[];
    await expectLater(
      deleteAccount(
        appleLinked: true,
        reauthenticate: () async => throw Exception('sheet dismissed'),
        revoke: (_) async => calls.add('revoke'),
        delete: () async => calls.add('delete'),
        startOver: () async => calls.add('startOver'),
      ),
      throwsException,
    );

    expect(calls, isEmpty);
  });

  test('an anonymous account never reauthenticates or revokes', () async {
    final calls = <String>[];
    await deleteAccount(
      appleLinked: false,
      reauthenticate: () async {
        calls.add('reauthenticate');
        return 'apple-code';
      },
      revoke: (_) async => calls.add('revoke'),
      delete: () async => calls.add('delete'),
      startOver: () async => calls.add('startOver'),
    );

    expect(calls, ['delete', 'startOver']);
  });

  test('no authorization code means nothing to revoke', () async {
    final calls = <String>[];
    await deleteAccount(
      appleLinked: true,
      // What the platform hands back when it carries no code through.
      reauthenticate: () async => null,
      revoke: (_) async => calls.add('revoke'),
      delete: () async => calls.add('delete'),
      startOver: () async => calls.add('startOver'),
    );

    expect(calls, ['delete', 'startOver']);
  });

  test('a failed delete leaves the session alone', () async {
    final calls = <String>[];
    await expectLater(
      deleteAccount(
        appleLinked: false,
        reauthenticate: () async => null,
        revoke: (_) async {},
        delete: () async => throw Exception('callable failed'),
        // Signing in anonymously here would swap the uid out from under an
        // account that still exists.
        startOver: () async => calls.add('startOver'),
      ),
      throwsException,
    );

    expect(calls, isEmpty);
  });
}
