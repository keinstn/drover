import 'package:drover/src/herdr/command_runner.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
