import 'dart:convert';

import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/herdr/host_platform.dart';
import 'package:drover/src/models/plugin_info.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:drover/src/notifications/host_pairing.dart';
import 'package:drover/src/notifications/plugin_auto_pairer.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCommandRunner extends CommandRunner {
  FakeCommandRunner(this._response);

  final CommandResult Function(String command) _response;
  final commands = <String>[];
  final stdinByCommand = <String, String>{};

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
    return _response(command);
  }

  @override
  Future<CommandResult> runWithStdin(String command, String stdin) async {
    commands.add(command);
    stdinByCommand[command] = stdin;
    return _response(command);
  }

  @override
  Future<void> uploadFile(String remotePath, List<int> bytes) async {}

  @override
  Future<List<RemoteDirEntry>> listDirectory(String path) async => [];

  @override
  Future<String> resolvePath(String path) async => path;

  @override
  Future<void> dispose() async {}
}

CommandResult ok(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');

const _plugin = PluginInfo(
  pluginId: 'drover.notify',
  enabled: true,
  pluginRoot: '/checkout/plugins/drover-notify',
);

const _pairing = PairingCode(
  code: 'the-pairing-code',
  hostId: 'host-123',
  completionUrl: 'https://example.com/completePairing',
);

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
  group('PluginAutoPairer.detectPlugin', () {
    test('returns the plugin when linked and enabled', () async {
      final runner = FakeCommandRunner(
        (_) => ok(
          '{"id":"1","result":{"plugins":[{"enabled":true,'
          '"plugin_id":"drover.notify",'
          '"plugin_root":"/checkout/plugins/drover-notify"}]}}',
        ),
      );
      final pairer = PluginAutoPairer(HerdrClient(runner));

      final plugin = await pairer.detectPlugin();

      expect(plugin, isNotNull);
      expect(plugin!.pluginRoot, '/checkout/plugins/drover-notify');
    });

    test('returns null when the plugin is linked but disabled', () async {
      final runner = FakeCommandRunner(
        (_) => ok(
          '{"id":"1","result":{"plugins":[{"enabled":false,'
          '"plugin_id":"drover.notify","plugin_root":"/x"}]}}',
        ),
      );
      final pairer = PluginAutoPairer(HerdrClient(runner));

      expect(await pairer.detectPlugin(), isNull);
    });

    test('returns null when the plugin is not linked', () async {
      final runner = FakeCommandRunner(
        (_) => ok('{"id":"1","result":{"plugins":[]}}'),
      );
      final pairer = PluginAutoPairer(HerdrClient(runner));

      expect(await pairer.detectPlugin(), isNull);
    });
  });

  group('PluginAutoPairer.pair', () {
    test('resolves node, sends the code via stdin (never in the command '
        'string), and runs pair.mjs', () async {
      final runner = FakeCommandRunner((command) {
        if (command.startsWith('sh -lc')) {
          return ok('/usr/local/bin/node\n');
        }
        if (command.contains("'config-dir'")) {
          return ok('/home/dev/.config/herdr/plugins/config/drover.notify');
        }
        return ok('');
      });
      final pairer = PluginAutoPairer(HerdrClient(runner));

      await pairer.pair(plugin: _plugin, pairing: _pairing);

      final pairCommand = runner.commands.firstWhere(
        (c) => c.contains('pair.mjs'),
      );
      // The pairing code must never appear in the command string itself —
      // only ever written to the process's stdin — so it can't leak via
      // `ps`, `/proc/*/cmdline`, or command-audit logging on the host.
      expect(pairCommand, isNot(contains('the-pairing-code')));
      expect(runner.stdinByCommand[pairCommand], 'the-pairing-code');
      expect(pairCommand, contains("'/usr/local/bin/node'"));
      expect(
        pairCommand,
        contains("'/checkout/plugins/drover-notify/bin/pair.mjs'"),
      );
      expect(pairCommand, contains('--completion-url'));
      expect(
        pairCommand,
        contains("'/home/dev/.config/herdr/plugins/config/drover.notify'"),
      );
    });

    test('throws when node is not on the host PATH', () async {
      final runner = FakeCommandRunner((command) {
        if (command.startsWith('sh -lc')) return ok('');
        return ok('');
      });
      final pairer = PluginAutoPairer(HerdrClient(runner));

      await expectLater(
        pairer.pair(plugin: _plugin, pairing: _pairing),
        throwsA(isA<PluginAutoPairException>()),
      );
    });

    test('throws when pair.mjs exits non-zero', () async {
      final runner = FakeCommandRunner((command) {
        if (command.startsWith('sh -lc')) return ok('/usr/local/bin/node');
        if (command.contains("'config-dir'")) return ok('/config/dir');
        return const CommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'invalid pairing code',
        );
      });
      final pairer = PluginAutoPairer(HerdrClient(runner));

      await expectLater(
        pairer.pair(plugin: _plugin, pairing: _pairing),
        throwsA(
          isA<PluginAutoPairException>().having(
            (e) => e.message,
            'message',
            contains('invalid pairing code'),
          ),
        ),
      );
    });
  });

  group('PluginAutoPairer.pair on Windows', () {
    const windowsPlugin = PluginInfo(
      pluginId: 'drover.notify',
      enabled: true,
      pluginRoot: r'C:\Users\dev\herdr\plugins\drover-notify',
    );

    test('resolves node via Get-Command, runs pair.mjs through PowerShell, '
        'and keeps the code on stdin', () async {
      final runner = FakeCommandRunner((command) {
        if (!command.startsWith(_encodedPrefix)) return ok('');
        final script = decodeScript(command);
        if (script.contains("Get-Command 'node'")) {
          return ok(r'C:\Program Files\Volta\node.exe');
        }
        if (script.contains("'config-dir'")) {
          return ok(r'C:\Users\dev\.herdr\plugins\config\drover.notify');
        }
        return ok('');
      });
      final pairer = PluginAutoPairer(
        HerdrClient(runner, platform: const WindowsHostPlatform()),
      );

      await pairer.pair(plugin: windowsPlugin, pairing: _pairing);

      final pairCommand = runner.commands.firstWhere(
        (c) =>
            c.startsWith(_encodedPrefix) &&
            decodeScript(c).contains('pair.mjs'),
      );
      final script = decodeScript(pairCommand);
      expect(script, contains(r"& 'C:\Program Files\Volta\node.exe'"));
      expect(
        script,
        contains(r"'C:\Users\dev\herdr\plugins\drover-notify/bin/pair.mjs'"),
      );
      expect(script, contains("'--completion-url'"));
      expect(script, contains("'https://example.com/completePairing'"));
      expect(
        script,
        contains(r"'C:\Users\dev\.herdr\plugins\config\drover.notify'"),
      );
      // The pairing code must never appear in the command (nor the encoded
      // script) — only ever on stdin.
      expect(pairCommand, isNot(contains('the-pairing-code')));
      expect(script, isNot(contains('the-pairing-code')));
      expect(runner.stdinByCommand[pairCommand], 'the-pairing-code');
    });
  });
}
