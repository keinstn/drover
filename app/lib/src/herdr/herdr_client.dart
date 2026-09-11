import 'dart:async';
import 'dart:convert';

import '../models/agent_info.dart';
import '../models/agent_preset.dart';
import '../models/host_config.dart';
import '../models/plugin_info.dart';
import '../models/remote_dir_entry.dart';
import '../models/workspace_info.dart';
import 'command_runner.dart';
import 'host_platform.dart';

class HerdrException implements Exception {
  const HerdrException(this.code, this.message, {this.cause});

  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'HerdrException($code): $message';
}

/// A newly-created workspace and its initial shell pane.
class CreatedWorkspace {
  const CreatedWorkspace({required this.workspaceId, required this.paneId});

  final String workspaceId;
  final String paneId;
}

/// Talks to the `herdr` CLI over a [CommandRunner], parsing its single-line
/// JSON envelope responses.
class HerdrClient {
  /// [platform] assembles OS-specific command lines for the SSH target. The
  /// host OS is a runtime property of that target, discovered by running a
  /// command over SSH ([HostPlatform.detect]), so it is a *factory* rather
  /// than an already-started value: a rejected [Future] can never be
  /// re-awaited into a fresh attempt, but a factory can simply be called
  /// again. Production passes `() => HostPlatform.detect(runner)`; the Unix
  /// default preserves behavior for tests and previews that never detect.
  HerdrClient(
    this._runner, {
    this.herdrBin = kDefaultHerdrBin,
    Future<void> Function(Duration duration)? sleep,
    FutureOr<HostPlatform> Function() platform = _defaultPlatform,
  }) : _sleep = sleep ?? Future<void>.delayed,
       _platformFactory = platform;

  static HostPlatform _defaultPlatform() => const UnixHostPlatform();

  static const _startAgentPaneBusyBackoffs = [
    Duration(milliseconds: 250),
    Duration(milliseconds: 500),
    Duration(milliseconds: 1000),
    Duration(milliseconds: 2000),
    Duration(milliseconds: 4000),
  ];

  final CommandRunner _runner;

  /// Injectable delay used by retry paths so tests do not wait on wall clock.
  final Future<void> Function(Duration duration) _sleep;
  final String herdrBin;
  final FutureOr<HostPlatform> Function() _platformFactory;

  /// Cached result of the most recent [_platformFactory] attempt, or null if
  /// none is currently cached — either none has run yet, or the last one
  /// failed. A *successful* detection is a stable property of the host (its
  /// OS doesn't change mid-session), so it is cached forever and never
  /// re-run. A *failed* detection is deliberately NOT cached: it is usually
  /// a transient transport hiccup (host briefly unreachable, Tailscale not
  /// yet reconnected at launch), and caching it would permanently poison
  /// this client — every later command would fail instantly with no chance
  /// to recover short of rebuilding the client. Leaving this null after a
  /// failure means the next caller that needs the platform simply retries
  /// [_platformFactory] from scratch, so an ordinary poll recovers on its
  /// own once the host is reachable again.
  Future<HostPlatform>? _platformFuture;

  /// Transport exposed for native, non-herdr data sources such as transcript
  /// files. Herdr commands themselves remain encapsulated by this client.
  CommandRunner get runner => _runner;

  /// Resolved host platform, for callers assembling raw (non-herdr) host
  /// commands — the same escape hatch as [runner].
  Future<HostPlatform> get hostPlatform => _resolvePlatform();

  /// Resolves the host platform, surfacing a detection failure as a
  /// transport [HerdrException] so the existing error-screen localization
  /// path handles it like any transport failure.
  ///
  /// Concurrent callers share one in-flight attempt (rather than each
  /// calling [_platformFactory], and thus each running `uname -s`) because
  /// they all read and await the same [_platformFuture] before any of them
  /// awaits anything else — `SshCommandRunner` serializes commands on a
  /// mutex, so parallel detects would only queue up behind each other and
  /// multiply latency for no benefit.
  ///
  /// `_platformFuture` is always created and awaited within the same
  /// synchronous stretch of code below (no `await` in between), so it
  /// always has a listener before control returns to the event loop. This
  /// is what protects against the unhandled-async-error crash the old
  /// `..ignore()` used to guard against — do not restructure this so the
  /// future can be stored across an `await` boundary before anyone awaits
  /// it, or a detection failure nobody has looked at yet can crash the app.
  Future<HostPlatform> _resolvePlatform() async {
    // Future.sync captures both a synchronous throw and an async failure
    // from `_platformFactory` into this Future, so both shapes land in the
    // catch below the same way.
    final future = _platformFuture ??= Future.sync(_platformFactory);
    try {
      return await future;
    } catch (e) {
      // Uncache so the next call retries — but only if nothing has already
      // replaced this attempt. Without this guard, a caller of a stale,
      // already-superseded failed attempt could wipe out a fresh retry that
      // another caller kicked off in the meantime.
      if (identical(_platformFuture, future)) {
        _platformFuture = null;
      }
      throw HerdrException('transport', e.toString(), cause: e);
    }
  }

  /// Parses [channel] as a herdr JSON envelope and extracts its coded error,
  /// or returns null if [channel] isn't parseable JSON or carries no `error`
  /// map. herdr's error channel (stdout vs stderr) and exit code are not
  /// consistent across commands (see docs/herdr-notes.md), so callers probe
  /// both channels with this same envelope shape rather than assuming either.
  HerdrException? _codedErrorFrom(String channel) {
    final Object? decoded;
    try {
      decoded = jsonDecode(channel.trim());
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final error = decoded['error'];
    if (error is! Map<String, dynamic>) return null;
    return HerdrException(
      error['code'] as String? ?? 'unknown',
      error['message'] as String? ?? 'unknown error',
    );
  }

  /// Runs a herdr command and returns its raw result, throwing a coded
  /// [HerdrException] when either channel carries a JSON error envelope, or a
  /// generic transport [HerdrException] on a spawn failure or an unrecognized
  /// non-zero exit. herdr has been observed reporting errors both as
  /// non-zero exit with the envelope on stdout, and as exit 0 with an empty
  /// stdout and the envelope on stderr — both are checked so callers keyed on
  /// [HerdrException.code] (e.g. the `agent_pane_busy` retry in [startAgent])
  /// see the real code regardless of which shape herdr used.
  Future<CommandResult> _exec(List<String> args) async {
    final platform = await _resolvePlatform();
    final command = platform.herdrCommand(
      platform.resolveHerdrBin(herdrBin),
      args,
    );
    final CommandResult result;
    try {
      result = await _runner.run(command);
    } catch (e) {
      throw HerdrException('transport', e.toString(), cause: e);
    }

    if (result.exitCode != 0) {
      throw _codedErrorFrom(result.stdout) ??
          _codedErrorFrom(result.stderr) ??
          HerdrException(
            'transport',
            'herdr ${args.join(' ')} failed (exit ${result.exitCode}): '
                '${result.stderr}',
          );
    }
    final codedError = _codedErrorFrom(result.stderr);
    if (codedError != null) throw codedError;
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
        'unparseable response to herdr ${args.join(' ')} '
            '(exit ${result.exitCode}): '
            'stdout=${jsonEncode(result.stdout)} '
            'stderr=${jsonEncode(result.stderr)}',
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
        'missing result field for herdr ${args.join(' ')}: '
            '${jsonEncode(result.stdout)}',
      );
    }
    return res;
  }

  /// Raw `herdr --version` stdout (e.g. `"herdr 0.7.5\n"`) — plain text, NOT
  /// a JSON envelope like the other commands in this class.
  Future<String> version() async => (await _exec(['--version'])).stdout;

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
    final result = await _exec([
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
    return result.stdout;
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

  /// Type [text] into [paneId] and submit it, atomically, via herdr's
  /// `agent prompt` (which replaced the removed `agent send` + a separate
  /// `pane send-keys enter`).
  Future<void> prompt(String paneId, String text) async {
    await _runOk(['agent', 'prompt', paneId, text]);
  }

  /// Probe the host PATH for which of [presets] are installed, returning the
  /// subset whose [AgentPreset.bin] resolves. Runs the platform's single
  /// read-only probe command — this is a raw host probe, NOT a herdr command,
  /// so it does not go through the JSON-envelope [_run] path.
  Future<List<AgentPreset>> detectAgents(List<AgentPreset> presets) async {
    if (presets.isEmpty) return [];
    final platform = await _resolvePlatform();
    final command = platform.detectAgentsCommand(
      presets.map((p) => p.bin).toList(),
    );
    final CommandResult result;
    try {
      result = await _runner.run(command);
    } catch (e) {
      throw HerdrException('transport', e.toString(), cause: e);
    }
    // The parse is deliberately OS-agnostic: both probes echo bare bin names
    // one per line, and trim() handles the '\r' in Windows line endings.
    final found = result.stdout
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toSet();
    return presets.where((p) => found.contains(p.bin)).toList();
  }

  /// Finds a linked plugin by [pluginId], or null if it is not linked.
  /// `--plugin` filters the CLI's own list, so a non-empty result always
  /// contains exactly the requested plugin.
  Future<PluginInfo?> findPlugin(String pluginId) async {
    final result = await _run([
      'plugin',
      'list',
      '--plugin',
      pluginId,
      '--json',
    ]);
    final plugins = result['plugins'];
    if (plugins is! List) {
      throw const HerdrException('transport', 'missing plugins field');
    }
    if (plugins.isEmpty) return null;
    return PluginInfo.fromJson(plugins.first as Map<String, dynamic>);
  }

  /// Print the Herdr-managed config directory for plugin [pluginId]. Raw
  /// text output, not a JSON envelope. herdr returns a path here even for an
  /// unlinked plugin id, so this must not be used to detect whether a
  /// plugin is installed — use [findPlugin] for that.
  Future<String> pluginConfigDir(String pluginId) async {
    final result = await _exec(['plugin', 'config-dir', pluginId]);
    return result.stdout.trim();
  }

  Future<CreatedWorkspace> createWorkspace({
    required String label,
    String? cwd,
  }) async {
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
    final rootPane = result['root_pane'];
    if (rootPane is! Map<String, dynamic> || rootPane['pane_id'] is! String) {
      throw const HerdrException('transport', 'missing root_pane.pane_id');
    }
    return CreatedWorkspace(
      workspaceId: ws['workspace_id'] as String,
      paneId: rootPane['pane_id'] as String,
    );
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

  /// Creates a shell pane in [workspaceId] at [cwd] and returns its id.
  Future<String> splitPane({
    required String workspaceId,
    required String cwd,
  }) async {
    final result = await _run(['pane', 'list', '--workspace', workspaceId]);
    final panes = result['panes'];
    if (panes is! List ||
        panes.isEmpty ||
        panes.first is! Map<String, dynamic>) {
      throw const HerdrException('transport', 'missing panes field');
    }
    final sourcePaneId = (panes.first as Map<String, dynamic>)['pane_id'];
    if (sourcePaneId is! String) {
      throw const HerdrException('transport', 'missing pane.pane_id');
    }

    final split = await _run([
      'pane',
      'split',
      sourcePaneId,
      '--direction',
      'right',
      '--cwd',
      cwd,
      '--no-focus',
    ]);
    final pane = split['pane'];
    if (pane is! Map<String, dynamic> || pane['pane_id'] is! String) {
      throw const HerdrException('transport', 'missing pane.pane_id');
    }
    return pane['pane_id'] as String;
  }

  /// Starts an agent of [kind] in an existing interactive shell [paneId].
  ///
  /// Herdr may briefly report a newly created or split pane as
  /// `agent_pane_busy` while its shell initializes, so retry that race only.
  Future<void> startAgent({
    required String name,
    required String kind,
    required String paneId,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        await _run(['agent', 'start', name, '--kind', kind, '--pane', paneId]);
        return;
      } on HerdrException catch (e) {
        if (e.code != 'agent_pane_busy' ||
            attempt >= _startAgentPaneBusyBackoffs.length) {
          rethrow;
        }
        await _sleep(_startAgentPaneBusyBackoffs[attempt]);
      }
    }
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
