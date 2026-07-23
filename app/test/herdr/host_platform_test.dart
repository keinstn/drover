import 'dart:convert';

import 'package:drover/src/dev/stub_herdr.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/host_platform.dart';
import 'package:drover/src/models/host_config.dart';
import 'package:flutter_test/flutter_test.dart';

const _encodedPrefix =
    'powershell.exe -NoProfile -NonInteractive -EncodedCommand ';

/// Decode an `-EncodedCommand` exec line back to the PowerShell script:
/// base64 → UTF-16LE bytes → code units (low byte first).
String decodeScript(String command) {
  expect(command, startsWith(_encodedPrefix));
  final bytes = base64.decode(command.substring(_encodedPrefix.length));
  final units = [
    for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8),
  ];
  return String.fromCharCodes(units);
}

void main() {
  group('HostPlatform.detect', () {
    test('classifies Linux, Darwin, and *BSD as Unix', () async {
      for (final kernel in ['Linux\n', 'Darwin\n', 'FreeBSD']) {
        final runner = StubCommandRunner((_) => ok(kernel));
        expect(await HostPlatform.detect(runner), isA<UnixHostPlatform>());
        expect(runner.commands, ['uname -s']);
      }
    });

    test('falls back to ver and classifies Windows', () async {
      final runner = StubCommandRunner((command) {
        if (command == 'uname -s') {
          return const CommandResult(
            exitCode: 1,
            stdout: '',
            stderr:
                "'uname' \u306f\u8a8d\u8b58\u3055\u308c\u3066\u3044\u307e\u305b\u3093",
          );
        }
        return ok('\nMicrosoft Windows [Version 10.0.26200.8875]\n');
      });

      expect(await HostPlatform.detect(runner), isA<WindowsHostPlatform>());
      expect(runner.commands, ['uname -s', 'cmd.exe /c ver']);
    });

    test('throws when neither probe classifies the host', () async {
      final runner = StubCommandRunner(
        (_) => const CommandResult(exitCode: 1, stdout: '', stderr: 'nope'),
      );

      await expectLater(
        HostPlatform.detect(runner),
        throwsA(isA<HostPlatformDetectionException>()),
      );
    });

    test('propagates transport errors untouched', () async {
      final runner = StubCommandRunner((_) => throw StateError('ssh down'));

      await expectLater(
        HostPlatform.detect(runner),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('UnixHostPlatform', () {
    const unix = UnixHostPlatform();

    test('herdrCommand matches buildHerdrCommand byte-for-byte', () {
      const args = ['agent', 'get', "it's mine"];
      expect(
        unix.herdrCommand(kDefaultHerdrBin, args),
        buildHerdrCommand(kDefaultHerdrBin, args),
      );
    });

    test('detectAgentsCommand probes via sh -lc and command -v', () {
      final command = unix.detectAgentsCommand(['claude', 'codex']);
      expect(command, startsWith('sh -lc '));
      expect(command, contains('command -v'));
      expect(command, contains("'claude'"));
      expect(command, contains("'codex'"));
    });
  });

  group('WindowsHostPlatform', () {
    const windows = WindowsHostPlatform();

    test('herdrCommand encodes a UTF-8 PowerShell script', () {
      final command = windows.herdrCommand('herdr', ['agent', 'list']);
      final script = decodeScript(command);
      expect(
        script,
        contains('[Console]::OutputEncoding=[System.Text.Encoding]::UTF8'),
      );
      expect(script, contains("& 'herdr' 'agent' 'list'"));
      expect(script, endsWith(r'exit $LASTEXITCODE'));
    });

    test('herdrCommand doubles embedded single quotes', () {
      final script = decodeScript(windows.herdrCommand('herdr', ["it's"]));
      expect(script, contains("'it''s'"));
    });

    test('herdrCommand preserves Japanese text', () {
      final script = decodeScript(
        windows.herdrCommand('herdr', ['agent', 'prompt', 'wB:p1', '実装して']),
      );
      expect(script, contains("'実装して'"));
    });

    test('detectAgentsCommand encodes a Get-Command probe', () {
      final script = decodeScript(
        windows.detectAgentsCommand(['claude', 'codex']),
      );
      expect(script, contains(r'Get-Command $a -ErrorAction SilentlyContinue'));
      expect(script, contains("'claude'"));
      expect(script, contains("'codex'"));
    });
  });

  group('resolveHerdrBin', () {
    test('Unix passes any configured value through', () {
      const unix = UnixHostPlatform();
      expect(unix.resolveHerdrBin(kDefaultHerdrBin), kDefaultHerdrBin);
      expect(unix.resolveHerdrBin('/opt/herdr'), '/opt/herdr');
    });

    test('Windows maps the Unix default to bare herdr', () {
      const windows = WindowsHostPlatform();
      expect(windows.resolveHerdrBin(kDefaultHerdrBin), 'herdr');
      expect(
        windows.resolveHerdrBin(r'C:\tools\herdr.exe'),
        r'C:\tools\herdr.exe',
      );
    });
  });
}
