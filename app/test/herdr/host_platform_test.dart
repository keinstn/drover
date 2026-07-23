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

    test('whichCommand probes via sh -lc and command -v byte-for-byte', () {
      expect(unix.whichCommand('node'), "sh -lc 'command -v '\\''node'\\'''");
    });

    test('runProgramCommand quotes every token', () {
      expect(
        unix.runProgramCommand('/usr/local/bin/node', [
          '/x/pair.mjs',
          '--flag',
          "it's",
        ]),
        "'/usr/local/bin/node' '/x/pair.mjs' '--flag' 'it'\\''s'",
      );
    });

    // The six literal expectations below are the regression lock for the
    // Phase-2 refactor of the transcript/upload call sites: each must stay
    // byte-for-byte identical to the command the original call site sent.

    test('findFileAtDepthCommand without envVar matches the Claude '
        'call site byte-for-byte', () {
      expect(
        unix.findFileAtDepthCommand(
          homeFallback: '.claude/projects',
          depth: 2,
          namePattern: 'abc.jsonl',
        ),
        'command find "\$HOME/.claude/projects" -mindepth 2 -maxdepth 2 '
        "-type f -name 'abc.jsonl' -print -quit",
      );
    });

    test('findFileAtDepthCommand with envVar matches the Codex '
        'call site byte-for-byte', () {
      expect(
        unix.findFileAtDepthCommand(
          envVar: 'CODEX_HOME',
          homeFallback: '.codex',
          suffix: 'sessions',
          depth: 4,
          namePattern: 'rollout-*-11112222-3333-4444-5555-666677778888.jsonl',
        ),
        'sh -lc \'command find "\${CODEX_HOME:-\$HOME/.codex}/sessions" '
        '-mindepth 4 -maxdepth 4 -type f '
        '-name "rollout-*-11112222-3333-4444-5555-666677778888.jsonl" '
        "-print -quit'",
      );
    });

    test('fileExistsCommand with envVar matches the Copilot '
        'call site byte-for-byte', () {
      expect(
        unix.fileExistsCommand(
          envVar: 'COPILOT_HOME',
          homeFallback: '.copilot',
          relativePath: 'session-state/sid-1/events.jsonl',
        ),
        'sh -lc \'p="\${COPILOT_HOME:-\$HOME/.copilot}'
        '/session-state/sid-1/events.jsonl"; '
        'if [ -f "\$p" ]; then command printf "%s" "\$p"; fi\'',
      );
    });

    test('fileExistsCommand without envVar keeps the sh -lc script shape '
        'with a plain \$HOME root', () {
      expect(
        unix.fileExistsCommand(
          homeFallback: '.copilot',
          relativePath: 'session-state/sid-1/events.jsonl',
        ),
        'sh -lc \'p="\$HOME/.copilot/session-state/sid-1/events.jsonl"; '
        'if [ -f "\$p" ]; then command printf "%s" "\$p"; fi\'',
      );
    });

    test('makeDirectoryCommand matches the upload call site '
        'byte-for-byte', () {
      expect(unix.makeDirectoryCommand('/x/y'), "command mkdir -p '/x/y'");
    });

    test('pruneFilesOlderThanCommand matches the upload call site '
        'byte-for-byte', () {
      expect(
        unix.pruneFilesOlderThanCommand('/x/y', 'img-*', days: 2),
        "command find '/x/y' -name 'img-*' -mtime +2 -delete",
      );
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

    test('whichCommand resolves via Get-Command and prints the raw '
        'Windows path (no SFTP normalization)', () {
      final command = windows.whichCommand('node');
      expect(command, startsWith(_encodedPrefix));
      final script = decodeScript(command);
      expect(
        script,
        contains(
          r"$p=(Get-Command 'node' -ErrorAction SilentlyContinue).Source;",
        ),
      );
      // The result feeds runProgramCommand as a native program path, so it
      // must stay verbatim — no leading-slash `/C:/` drive form.
      expect(script, contains(r'if($p){[Console]::Out.Write($p)}'));
      expect(script, isNot(contains(r"-replace '\\','/'")));
    });

    test('runProgramCommand calls via & and propagates the exit code', () {
      final command = windows.runProgramCommand(
        r'C:\Program Files\Volta\node.exe',
        ['/x/pair.mjs', '--completion-url', 'https://example.com/done'],
      );
      expect(command, startsWith(_encodedPrefix));
      final script = decodeScript(command);
      expect(
        script,
        contains(
          r"& 'C:\Program Files\Volta\node.exe' '/x/pair.mjs' "
          r"'--completion-url' 'https://example.com/done'",
        ),
      );
      expect(script, endsWith(r'exit $LASTEXITCODE'));
    });

    /// Number of `*\` glob segments in [script] — one per searched level
    /// above the filename, so depth N globs contain N-1.
    int globStars(String script) => RegExp(r'\*\\').allMatches(script).length;

    test('findFileAtDepthCommand without envVar uses the USERPROFILE '
        'fallback root and a depth-2 glob', () {
      final command = windows.findFileAtDepthCommand(
        homeFallback: '.claude/projects',
        depth: 2,
        namePattern: 'abc.jsonl',
      );
      expect(command, startsWith(_encodedPrefix));
      final script = decodeScript(command);
      expect(script, isNot(contains(r'if($env:')));
      expect(
        script,
        contains(r"$r=Join-Path $env:USERPROFILE '.claude/projects';"),
      );
      expect(globStars(script), 1);
      expect(script, contains('-ErrorAction SilentlyContinue'));
      // Leading-slash drive form: /C:/Users/... via backslash replacement,
      // emitted without a trailing newline (Write-Output's CRLF would break
      // the callers' exact endsWith matches — caught live on Windows).
      expect(
        script,
        contains(r"[Console]::Out.Write('/' + ($p -replace '\\','/'))"),
      );
    });

    test('findFileAtDepthCommand with envVar prefers the env root and '
        'builds a depth-4 glob under the suffix', () {
      final script = decodeScript(
        windows.findFileAtDepthCommand(
          envVar: 'CODEX_HOME',
          homeFallback: '.codex',
          suffix: 'sessions',
          depth: 4,
          namePattern: 'rollout-*-uuid.jsonl',
        ),
      );
      expect(script, contains(r'if($env:CODEX_HOME){$r=$env:CODEX_HOME}else{'));
      expect(script, contains(r"$r=Join-Path $r 'sessions';"));
      // depth 4 → three `*\` segments; the pattern's own `*` adds none.
      expect(globStars(script), 3);
    });

    test('findFileAtDepthCommand doubles single quotes in the pattern', () {
      final script = decodeScript(
        windows.findFileAtDepthCommand(
          homeFallback: '.claude/projects',
          depth: 2,
          namePattern: "it's.jsonl",
        ),
      );
      expect(script, contains("it''s.jsonl"));
    });

    test('fileExistsCommand guards with Test-Path and prints the '
        'normalized path', () {
      final command = windows.fileExistsCommand(
        envVar: 'COPILOT_HOME',
        homeFallback: '.copilot',
        relativePath: 'session-state/sid-1/events.jsonl',
      );
      expect(command, startsWith(_encodedPrefix));
      final script = decodeScript(command);
      expect(
        script,
        contains(r'if($env:COPILOT_HOME){$r=$env:COPILOT_HOME}else{'),
      );
      expect(script, contains(r'Test-Path -LiteralPath $p -PathType Leaf'));
      expect(
        script,
        contains(r"[Console]::Out.Write('/' + ($p -replace '\\','/'))"),
      );
    });

    test('fileExistsCommand without envVar has no env branch', () {
      final script = decodeScript(
        windows.fileExistsCommand(
          homeFallback: '.copilot',
          relativePath: 'session-state/sid-1/events.jsonl',
        ),
      );
      expect(script, isNot(contains(r'if($env:')));
      expect(script, contains(r"$r=Join-Path $env:USERPROFILE '.copilot';"));
    });

    test('makeDirectoryCommand creates idempotently via New-Item -Force', () {
      final command = windows.makeDirectoryCommand('/x/y');
      expect(command, startsWith(_encodedPrefix));
      final script = decodeScript(command);
      expect(script, contains('New-Item -ItemType Directory -Force'));
      expect(script, contains("'/x/y'"));
    });

    test('pruneFilesOlderThanCommand filters by age and removes '
        'best-effort', () {
      final command = windows.pruneFilesOlderThanCommand(
        '/x/y',
        'img-*',
        days: 2,
      );
      expect(command, startsWith(_encodedPrefix));
      final script = decodeScript(command);
      expect(script, contains('AddDays(-2)'));
      expect(script, contains('Remove-Item -ErrorAction SilentlyContinue'));
      expect(script, contains("'img-*'"));
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
