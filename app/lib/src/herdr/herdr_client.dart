import 'dart:convert';

import '../models/agent_info.dart';
import '../models/agent_preset.dart';
import '../models/host_config.dart';
import '../models/remote_dir_entry.dart';
import '../models/workspace_info.dart';
import 'command_runner.dart';

class HerdrException implements Exception {
  const HerdrException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'HerdrException($code): $message';
}

/// Talks to the `herdr` CLI over a [CommandRunner], parsing its single-line
/// JSON envelope responses.
class HerdrClient {
  HerdrClient(this._runner, {this.herdrBin = kDefaultHerdrBin});

  final CommandRunner _runner;
  final String herdrBin;

  /// Transport exposed for native, non-herdr data sources such as transcript
  /// files. Herdr commands themselves remain encapsulated by this client.
  CommandRunner get runner => _runner;

  /// Runs a herdr command and returns its raw result, throwing a transport
  /// [HerdrException] on a spawn failure or a non-zero exit (herdr prints an
  /// error envelope to stderr and exits non-zero on failure).
  Future<CommandResult> _exec(List<String> args) async {
    final command = buildHerdrCommand(herdrBin, args);
    final CommandResult result;
    try {
      result = await _runner.run(command);
    } catch (e) {
      throw HerdrException('transport', e.toString());
    }

    if (result.exitCode != 0) {
      throw HerdrException(
        'transport',
        'herdr ${args.join(' ')} failed (exit ${result.exitCode}): '
            '${result.stderr}',
      );
    }
    return result;
  }

  /// Runs a command whose success carries no body (herdr's "ok" responses,
  /// e.g. `pane send-keys`, print nothing on stdout). Exit-code checking in
  /// [_exec] is the only success signal.
  Future<void> _runOk(List<String> args) => _exec(args);

  Future<Map<String, dynamic>> _run(List<String> args) async {
    final result = await _exec(args);

    final Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(result.stdout) as Map<String, dynamic>;
    } catch (e) {
      throw HerdrException(
        'transport',
        'unparseable response: ${result.stdout}',
      );
    }

    final error = envelope['error'];
    if (error is Map<String, dynamic>) {
      throw HerdrException(
        error['code'] as String? ?? 'unknown',
        error['message'] as String? ?? 'unknown error',
      );
    }

    final res = envelope['result'];
    if (res is! Map<String, dynamic>) {
      throw HerdrException(
        'transport',
        'missing result field: ${result.stdout}',
      );
    }
    return res;
  }

  Future<List<AgentInfo>> listAgents() async {
    final result = await _run(['agent', 'list']);
    final agents = result['agents'];
    if (agents is! List) {
      throw const HerdrException('transport', 'missing agents field');
    }
    return agents.cast<Map<String, dynamic>>().map(AgentInfo.fromJson).toList();
  }

  Future<AgentInfo> getAgent(String target) async {
    final result = await _run(['agent', 'get', target]);
    final agent = result['agent'];
    if (agent is! Map<String, dynamic>) {
      throw const HerdrException('transport', 'missing agent field');
    }
    return AgentInfo.fromJson(agent);
  }

  /// Reads the recent transcript for [target] as ANSI-coloured text (SGR
  /// escapes only, from the `recent` source).
  Future<String> readAgent(String target, {int lines = 120}) async {
    final result = await _run([
      'agent',
      'read',
      target,
      '--source',
      'recent',
      '--lines',
      '$lines',
      '--format',
      'ansi',
    ]);
    final read = result['read'];
    if (read is! Map<String, dynamic> || read['text'] is! String) {
      throw const HerdrException('transport', 'missing read.text field');
    }
    return read['text'] as String;
  }

  Future<void> sendText(String paneId, String text) async {
    await _run(['agent', 'send', paneId, text]);
  }

  Future<void> sendKeys(String paneId, String key) async {
    await _runOk(['pane', 'send-keys', paneId, key]);
  }

  /// Send raw [text] to [paneId] as keystrokes, with no trailing Enter, via
  /// herdr's `pane send-text` — NOT `agent send` (which would submit a
  /// prompt). Used by agent-specific capabilities to type option digits,
  /// custom answers, and mode-cycle escape sequences straight into an
  /// interactive TUI.
  Future<void> sendPaneText(String paneId, String text) async {
    await _runOk(['pane', 'send-text', paneId, text]);
  }

  /// Stop the agent running in [paneId] by closing its pane.
  Future<void> closeAgent(String paneId) async {
    await _run(['pane', 'close', paneId]);
  }

  Future<void> prompt(String paneId, String text) async {
    await sendText(paneId, text);
    await sendKeys(paneId, 'enter');
  }

  /// Probe the host PATH for which of [presets] are installed, returning the
  /// subset whose [AgentPreset.bin] resolves. Runs a single read-only
  /// `command -v` sweep under a login shell — this is a raw host probe, NOT a
  /// herdr command, so it does not go through the JSON-envelope [_run] path.
  Future<List<AgentPreset>> detectAgents(List<AgentPreset> presets) async {
    if (presets.isEmpty) return [];
    final bins = presets.map((p) => shQuote(p.bin)).join(' ');
    final script =
        'for a in $bins; do command -v "\$a" >/dev/null 2>&1 && echo "\$a"; done';
    final command = 'bash -lc ${shQuote(script)}';
    final CommandResult result;
    try {
      result = await _runner.run(command);
    } catch (e) {
      throw HerdrException('transport', e.toString());
    }
    final found = result.stdout
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toSet();
    return presets.where((p) => found.contains(p.bin)).toList();
  }

  Future<String> createWorkspace({required String label, String? cwd}) async {
    final result = await _run([
      'workspace',
      'create',
      '--label',
      label,
      if (cwd != null) ...['--cwd', cwd],
      '--no-focus',
    ]);
    final ws = result['workspace'];
    if (ws is! Map<String, dynamic> || ws['workspace_id'] is! String) {
      throw const HerdrException('transport', 'missing workspace.workspace_id');
    }
    return ws['workspace_id'] as String;
  }

  /// Close the workspace [workspaceId]. Used to roll back a workspace created
  /// for a launch that then failed.
  Future<void> closeWorkspace(String workspaceId) async {
    await _run(['workspace', 'close', workspaceId]);
  }

  Future<List<WorkspaceInfo>> listWorkspaces() async {
    final result = await _run(['workspace', 'list']);
    final workspaces = result['workspaces'];
    if (workspaces is! List) {
      throw const HerdrException('transport', 'missing workspaces field');
    }
    return workspaces
        .cast<Map<String, dynamic>>()
        .map(WorkspaceInfo.fromJson)
        .toList();
  }

  /// Rename workspace [workspaceId] to [label].
  Future<void> renameWorkspace(String workspaceId, String label) async {
    await _run(['workspace', 'rename', workspaceId, label]);
  }

  /// Launch [argv] as a new herdr-managed agent named [name] in [cwd]. When
  /// [workspaceId] is given the agent is placed in that workspace, otherwise
  /// herdr creates a new one. The `agent_started` envelope omits the `agent`
  /// label key, so the result is intentionally not parsed — the herd list
  /// reflects the new agent on its next poll.
  Future<void> startAgent({
    required String name,
    required List<String> argv,
    required String cwd,
    String? workspaceId,
    String? tabId,
  }) async {
    await _run([
      'agent',
      'start',
      name,
      '--cwd',
      cwd,
      if (workspaceId != null) ...['--workspace', workspaceId],
      if (tabId != null) ...['--tab', tabId],
      '--no-focus',
      '--',
      ...argv,
    ]);
  }

  /// Rename the agent identified by [target] to [name].
  Future<void> renameAgent(String target, String name) async {
    await _run(['agent', 'rename', target, name]);
  }

  /// List the entries of the directory at [path]. Raw transport/SFTP
  /// capability (like the uploads an image-attachment capability drives),
  /// not a herdr JSON-envelope command.
  Future<List<RemoteDirEntry>> listDirectory(String path) =>
      _runner.listDirectory(path);

  /// Resolve [path] to an absolute path on the host. Raw transport/SFTP
  /// capability (like the uploads an image-attachment capability drives),
  /// not a herdr JSON-envelope command.
  Future<String> resolvePath(String path) => _runner.resolvePath(path);
}
