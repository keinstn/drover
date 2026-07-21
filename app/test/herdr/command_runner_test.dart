import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal concrete [CommandRunner] that overrides only the members with
/// no default implementation, so [readFile]/[statFile] exercise the base
/// class's own default behavior (an [UnsupportedError]) unchanged.
class _MinimalCommandRunner extends CommandRunner {
  @override
  Future<CommandResult> run(String command) =>
      Future.value(const CommandResult(exitCode: 0, stdout: '', stderr: ''));

  @override
  Future<void> uploadFile(String remotePath, List<int> bytes) async {}

  @override
  Future<List<RemoteDirEntry>> listDirectory(String path) async => [];

  @override
  Future<String> resolvePath(String path) async => path;

  @override
  Future<void> dispose() async {}
}

void main() {
  group('shQuote', () {
    test('wraps a plain string in single quotes', () {
      expect(shQuote('agent'), "'agent'");
    });

    test('escapes embedded single quotes', () {
      expect(shQuote("it's"), r"'it'\''s'");
    });
  });

  group('buildHerdrCommand', () {
    test('leaves herdrBin unquoted and quotes each arg', () {
      final cmd = buildHerdrCommand('~/.local/bin/herdr', ['agent', 'list']);
      expect(cmd, "~/.local/bin/herdr 'agent' 'list'");
    });

    test('quotes an arg containing a single quote', () {
      final cmd = buildHerdrCommand('~/.local/bin/herdr', [
        'agent',
        'send',
        'wB:p4',
        "it's done",
      ]);
      expect(cmd, r"~/.local/bin/herdr 'agent' 'send' 'wB:p4' 'it'\''s done'");
    });
  });

  group('CommandRunner.readFile default contract', () {
    test('is unavailable by default whether or not a length is given, '
        'preserving the existing offset-only signature', () async {
      final runner = _MinimalCommandRunner();

      await expectLater(
        runner.readFile('/tmp/x'),
        throwsA(isA<UnsupportedError>()),
      );
      await expectLater(
        runner.readFile('/tmp/x', offset: 10),
        throwsA(isA<UnsupportedError>()),
      );
      await expectLater(
        runner.readFile('/tmp/x', offset: 10, length: 5),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('CommandRunner.statFile default contract', () {
    test('is unavailable by default', () async {
      final runner = _MinimalCommandRunner();

      await expectLater(
        runner.statFile('/tmp/x'),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}
