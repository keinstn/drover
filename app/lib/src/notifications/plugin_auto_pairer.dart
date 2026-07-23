import '../herdr/command_runner.dart';
import '../herdr/herdr_client.dart';
import '../models/plugin_info.dart';
import 'host_pairing.dart';

const _droverNotifyPluginId = 'drover.notify';

class PluginAutoPairException implements Exception {
  const PluginAutoPairException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Detects whether the `drover.notify` Herdr plugin is already linked and
/// enabled on a host, and drives its non-interactive `bin/pair.mjs` script
/// over the same SSH connection to complete pairing without the user
/// needing a host terminal. Installing/linking the plugin itself stays a
/// manual host operation — this only drives an already-installed plugin's
/// own script.
class PluginAutoPairer {
  const PluginAutoPairer(this._herdrClient);

  final HerdrClient _herdrClient;

  /// Returns the plugin info when `drover.notify` is linked and enabled,
  /// null when it is not installed or is installed but disabled.
  Future<PluginInfo?> detectPlugin() async {
    final plugin = await _herdrClient.findPlugin(_droverNotifyPluginId);
    return plugin != null && plugin.enabled ? plugin : null;
  }

  /// Completes pairing for an already-linked [plugin] by running its
  /// `bin/pair.mjs` over SSH, writing [pairing]'s code to the command's
  /// stdin (via [CommandRunner.runWithStdin]) rather than interpolating it
  /// into the command string — it must never appear in any remote process's
  /// argv (visible via `ps`, `/proc/*/cmdline`, or command-audit logging).
  Future<void> pair({
    required PluginInfo plugin,
    required PairingCode pairing,
  }) async {
    final node = await _resolveNodeBin();
    final configDir = await _herdrClient.pluginConfigDir(_droverNotifyPluginId);
    final platform = await _herdrClient.hostPlatform;
    final command = platform.runProgramCommand(node, [
      '${plugin.pluginRoot}/bin/pair.mjs',
      '--completion-url',
      pairing.completionUrl,
      '--config-dir',
      configDir,
    ]);
    final CommandResult result;
    try {
      result = await _herdrClient.runner.runWithStdin(command, pairing.code);
    } catch (e) {
      throw PluginAutoPairException(e.toString());
    }
    if (result.exitCode != 0) {
      throw PluginAutoPairException(
        'pair.mjs failed (exit ${result.exitCode}): ${result.stderr}',
      );
    }
  }

  /// Resolves the absolute path to `node` via the host platform's PATH
  /// probe (a login shell on Unix, so `PATH` matches what a human's own
  /// shell would see; `Get-Command` on Windows) — the same probe pattern
  /// `HerdrClient.detectAgents` uses for agent binaries. A non-interactive
  /// SSH exec channel otherwise often lacks the PATH entries a manual
  /// terminal session would have.
  Future<String> _resolveNodeBin() async {
    final platform = await _herdrClient.hostPlatform;
    final command = platform.whichCommand('node');
    final CommandResult result;
    try {
      result = await _herdrClient.runner.run(command);
    } catch (e) {
      throw PluginAutoPairException(e.toString());
    }
    final path = result.stdout.trim();
    if (path.isEmpty) {
      throw const PluginAutoPairException(
        'node was not found on the host PATH.',
      );
    }
    return path;
  }
}
