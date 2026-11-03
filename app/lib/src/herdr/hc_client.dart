import 'dart:convert';

import '../models/agent_info.dart';
import '../models/plugin_info.dart';
import '../models/workspace_info.dart';
import 'command_runner.dart';
import 'agent_name.dart';
import 'herdr_backend.dart';
import 'herdr_client.dart';
import 'host_platform.dart';

export 'herdr_backend.dart' show kDefaultHcBin;

/// Drives Herdr 2's herdr-core through `hc connect` (JSON-RPC over stdin),
/// presenting it through the same API as [HerdrClient]. [version] is
/// inherited: `hc --version` runs through the same path as herdr's.
///
/// Every id it hands out carries [kHcIdPrefix] (`hc:t16`, `hc:sp…`); ids it
/// takes may carry it or not.
class HcClient extends HerdrClient {
  HcClient(
    super.runner, {
    super.herdrBin = kDefaultHcBin,
    super.sleep,
    super.platform,
    this.requireRunningCore = false,
  });

  /// When set, every `hc connect` first checks that a herdr-core runs and
  /// fails with code [kHcNotRunning] if not, instead of letting `hc connect`
  /// autostart one. The check runs in the same exec as the connect, so the
  /// window between them is tiny but real: a core that exits in between gets
  /// autostarted. Windows hosts always fail it (Herdr 2 on Windows is
  /// deferred).
  // ponytail: the gate needs a procps-style `pgrep -x -U`. Without pgrep, or
  // with one that rejects `-U` (BusyBox builds), Auto mode reads hc as not
  // running; explicit Herdr 2 mode skips the gate and is the workaround. No
  // `pgrep -x herdr-core` fallback: it would match another user's core, and
  // then `hc connect` autostarts ours — what the gate exists to prevent.
  final bool requireRunningCore;

  /// [HerdrException.code] for "no herdr-core runs" under
  /// [requireRunningCore].
  static const kHcNotRunning = 'hc_not_running';

  /// [HerdrException.code] when a gated client is on a non-Unix host:
  /// Herdr 2 on Windows is unsupported, so the part is simply absent.
  static const kHcUnsupportedHost = 'hc_unsupported_host';

  /// What the core gate prints on stderr when no core runs.
  static const notRunningMarker = 'drover-hc-not-running';

  static String _raw(String id) =>
      id.startsWith(kHcIdPrefix) ? id.substring(kHcIdPrefix.length) : id;

  static String _id(String raw) => '$kHcIdPrefix$raw';

  @override
  HerdrBackend get backend => HerdrBackend.hc;

  /// Sends [calls] (method, params) as one `hc connect` session, one JSON-RPC
  /// request per line, and returns their results in order. A request hc
  /// answered with an error comes back as a [HerdrException] value, so a
  /// batch can tolerate one failure; [_ok] throws it.
  Future<List<Object?>> _rpc(List<(String, Map<String, Object?>)> calls) async {
    final platform = await hostPlatform;
    final bin = platform.resolveHerdrBin(herdrBin);
    if (requireRunningCore && platform is! UnixHostPlatform) {
      throw const HerdrException(
        kHcUnsupportedHost,
        'Herdr 2 needs a Unix host',
      );
    }
    // fish is a common login shell, so the gate script avoids `'` and `\`;
    // [bin] stays unquoted so sh expands a `~`.
    final command = requireRunningCore
        ? 'sh -c ${shQuote('pgrep -x -U "\$(id -u)" herdr-core >/dev/null 2>&1 '
          '|| { echo $notRunningMarker >&2; exit 3; }; exec $bin connect')}'
        : platform.herdrCommand(bin, ['connect']);
    final stdin = [
      for (final (i, (method, params)) in calls.indexed)
        '${jsonEncode({'jsonrpc': '2.0', 'id': i + 1, 'method': method, 'params': params})}\n',
    ].join();

    final CommandResult result;
    try {
      result = await runner.runWithStdin(command, stdin);
    } catch (e) {
      throw HerdrException('transport', e.toString(), cause: e);
    }
    final methods = calls.map((c) => c.$1).join(', ');
    if (requireRunningCore && result.stderr.contains(notRunningMarker)) {
      throw const HerdrException(kHcNotRunning, 'no herdr-core is running');
    }
    if (result.exitCode != 0) {
      throw HerdrException(
        'transport',
        'hc connect ($methods) failed (exit ${result.exitCode}): '
            '${result.stderr}',
      );
    }

    final replies = <Object?, Map<String, dynamic>>{};
    for (final line in const LineSplitter().convert(result.stdout)) {
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) replies[decoded['id']] = decoded;
      } on FormatException {
        // Surfaces below as a missing reply.
      }
    }

    return [
      for (var id = 1; id <= calls.length; id++)
        _resultOf(replies[id], calls[id - 1].$1, result.stdout),
    ];
  }

  static Object? _resultOf(
    Map<String, dynamic>? reply,
    String method,
    String stdout,
  ) {
    if (reply == null) {
      throw HerdrException(
        'transport',
        'no reply to hc $method: stdout=${jsonEncode(stdout)}',
      );
    }
    final error = reply['error'];
    if (error is Map<String, dynamic>) {
      final data = error['data'];
      return HerdrException(
        (data is Map<String, dynamic> ? data['kind'] as String? : null) ??
            'unknown',
        error['message'] as String? ?? 'unknown error',
      );
    }
    return reply['result'];
  }

  static Object? _ok(Object? result) =>
      result is HerdrException ? throw result : result;

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, Object?> params,
  ) async {
    final result = _ok((await _rpc([(method, params)])).single);
    if (result is! Map<String, dynamic>) {
      throw HerdrException('transport', 'missing result for hc $method');
    }
    return result;
  }

  static const _herdrAppDoc = ('doc.get', {'name': 'herdr-app'});

  @override
  Future<List<AgentInfo>> listAgents() async {
    final [list, doc] = await _rpc([('terminal.list', {}), _herdrAppDoc]);
    final terminals = switch (_ok(list)) {
      final Map<String, dynamic> m => m['terminals'],
      _ => null,
    };
    if (terminals is! List) {
      throw const HerdrException('transport', 'missing terminals field');
    }
    // A doc failure doesn't fail the poll (agents carry their space id in
    // labels); it only drops the cache, so nothing stale is served.
    _lastWorkspaces = doc is HerdrException ? null : _workspacesFrom(doc);
    _seen.clear();
    return [
      for (final t in terminals.cast<Map<String, dynamic>>())
        if (t['state'] == 'live' &&
            !(t['address'] as String).contains('/') &&
            _isAgent(t))
          _agentFrom(t),
    ];
  }

  @override
  Future<AgentInfo> getAgent(String target) async {
    target = _raw(target);
    _pendingText.remove(target);
    final record = await _call('terminal.get', {'terminal': target});
    if (!_isAgent(record)) {
      throw HerdrException('not_agent', '$target is not running an agent');
    }
    return _agentFrom(record);
  }

  /// An agent is a terminal reporting status (OSC 7501), or one drover
  /// launched — so a CLI without an integration stays reachable.
  static bool _isAgent(Map<String, dynamic> t) =>
      t['status'] is Map || _labelsOf(t)[_launchedLabel] == '1';

  static const _launchedLabel = 'drover.launched';

  static Map<String, dynamic> _labelsOf(Map<String, dynamic> t) =>
      (t['labels'] as Map<String, dynamic>?) ?? const {};

  /// (turn, herdr.seen) per address from the last [listAgents]/[getAgent],
  /// so [markSeen] needs no extra round trip on the poll.
  final _seen = <String, (int, int?)>{};

  /// Workspaces from the `doc.get` batched into the latest [listAgents],
  /// handed out once so a poll's `listAgents` + `listWorkspaces` pair costs
  /// one round trip; otherwise [listWorkspaces] fetches.
  List<WorkspaceInfo>? _lastWorkspaces;

  @override
  Future<List<WorkspaceInfo>> listWorkspaces() async {
    final cached = _lastWorkspaces;
    _lastWorkspaces = null;
    return cached ?? _workspacesFrom(_ok((await _rpc([_herdrAppDoc])).single));
  }

  static List<WorkspaceInfo> _workspacesFrom(Object? doc) {
    final value = doc is Map<String, dynamic> ? doc['value'] : null;
    final spaces = value is Map<String, dynamic> ? value['spaces'] : null;
    if (spaces is! List) return [];
    return [
      for (final s in spaces.cast<Map<String, dynamic>>())
        WorkspaceInfo(
          workspaceId: _id(s['id'] as String),
          label: switch (s['name']) {
            final String name when name.isNotEmpty => name,
            _ => _basename(s['folder'] as String? ?? ''),
          },
        ),
    ];
  }

  /// Basename of the program [argv] runs, looking through [_loginShell].
  static String? _programOf(Object? argv) {
    if (argv is! List || argv.isEmpty) return null;
    final args = argv.cast<String>();
    final isWrapped =
        args.length > _loginShell.length &&
        _loginShell.indexed.every((e) => args[e.$1] == e.$2);
    return _basename(args[isWrapped ? _loginShell.length : 0]);
  }

  static String _basename(String path) =>
      path.split('/').lastWhere((p) => p.isNotEmpty, orElse: () => path);

  AgentInfo _agentFrom(Map<String, dynamic> t) {
    final status = (t['status'] as Map<String, dynamic>?) ?? const {};
    final labels = _labelsOf(t);
    final seen = int.tryParse(labels['herdr.seen'] as String? ?? '');
    _seen[t['address'] as String] = (t['turn'] as int? ?? 0, seen);
    final foreground = t['foreground'] as Map<String, dynamic>?;
    final app = status['app'] as String? ?? '';
    final title = t['title'] as String? ?? '';
    String? prefixed(Object? id) =>
        id is String && id.isNotEmpty ? _id(id) : null;
    return AgentInfo(
      paneId: _id(t['address'] as String),
      workspaceId: prefixed(labels['herdr.space']) ?? '',
      tabId: prefixed(labels['herdr.tab']) ?? '',
      agent: switch (app) {
        'claude-code' => 'claude',
        '' => foreground?['name'] as String? ?? _programOf(t['argv']),
        _ => app,
      },
      name: t['name'] as String?,
      status: _statusOf(status['state'] as String?, t['turn'] as int?, seen),
      cwd: foreground?['cwd'] as String? ?? t['cwd'] as String? ?? '',
      foregroundCwd: foreground?['cwd'] as String?,
      focused: false,
      terminalTitle: title.isEmpty ? null : title,
    );
  }

  /// The shared seen rule (herdr-app docs/labels.md): with a `herdr.seen`
  /// label, a finished agent is done until someone has seen its latest turn.
  /// Without one, hc's own word stands.
  static AgentStatus _statusOf(String? state, int? turn, int? seen) =>
      switch (state) {
        'working' => AgentStatus.working,
        'blocked' || 'error' => AgentStatus.blocked,
        'idle' || 'done' when seen != null && turn != null =>
          turn > seen ? AgentStatus.done : AgentStatus.idle,
        'idle' => AgentStatus.idle,
        'done' => AgentStatus.done,
        _ => AgentStatus.unknown,
      };

  @override
  Future<String> readAgent(String target, {int lines = 120}) async {
    target = _raw(target);
    _pendingText.remove(target);
    final result = await _call('terminal.read', {
      'terminal': target,
      'lines': lines,
    });
    return result['text'] as String? ?? '';
  }

  // ponytail: a bare number is taken as a dialog option answer (how the herd
  // and agent screens answer a blocked agent) and forced through; any other
  // text is refused by hc on a blocked terminal (`blocked`), so free text
  // can't land in a dialog. Upgrade: an explicit answer-dialog call.
  @override
  Future<void> prompt(String paneId, String text) async {
    paneId = _raw(paneId);
    _pendingText.remove(paneId);
    await _send(paneId, text, force: RegExp(r'^\d+$').hasMatch(text));
  }

  Future<void> _send(String paneId, String text, {required bool force}) =>
      _call('terminal.send', {
        'terminal': paneId,
        'text': text,
        if (force) 'force': true,
      });

  /// drover's key names (up/down/left/right, esc, enter, tab, shift+tab) are
  /// already hc key names.
  @override
  Future<void> sendKeys(String paneId, String key) async {
    paneId = _raw(paneId);
    final pending = _pendingText.remove(paneId);
    if (pending != null && key == 'enter') {
      return _send(paneId, pending, force: true);
    }
    await _keys(paneId, [key]);
  }

  /// Free text [sendPaneText] couldn't type, per pane, waiting for the
  /// `enter` that submits it. Any other call on that pane drops it.
  final _pendingText = <String, String>{};

  Future<void> _keys(String paneId, List<String> keys) async {
    await _call('terminal.keys', {'terminal': paneId, 'keys': keys});
  }

  static final _plainKey = RegExp(r"^[a-z0-9`\\\[\],=\-.';/]$");

  // ponytail: hc has no raw-text-without-Enter. Text that spells out as hc
  // key names is typed; anything else is held until the pane's next `enter`
  // (every submitter follows free text with one) and then pasted with Enter.
  // Anything in between — e.g. Codex reading the pane to confirm the text —
  // drops it, so nothing half-typed is sent. Upgrade path: write to the
  // framed `attach` stream.
  @override
  Future<void> sendPaneText(String paneId, String text) async {
    paneId = _raw(paneId);
    _pendingText.remove(paneId);
    if (text == '\x1b[Z') return _keys(paneId, ['shift+tab']);
    // Focus in/out reports: nothing to forward on hc.
    if (text == '\x1b[I' || text == '\x1b[O') return;
    final keys = [
      for (final char in text.split(''))
        if (char == ' ')
          'space'
        else if (_plainKey.hasMatch(char))
          char
        else if (RegExp('^[A-Z]\$').hasMatch(char))
          'shift+${char.toLowerCase()}'
        else
          null,
    ];
    if (!keys.contains(null)) {
      if (keys.isNotEmpty) await _keys(paneId, keys.cast<String>());
      return;
    }
    _pendingText[paneId] = text;
  }

  @override
  Future<void> closeAgent(String paneId) async {
    paneId = _raw(paneId);
    _pendingText.remove(paneId);
    _seen.remove(paneId);
    await _call('terminal.kill', {'terminal': paneId});
  }

  /// Raises `herdr.seen` to the terminal's current turn (never lowers it),
  /// so this agent stops showing as done on every Herdr client. Reads turn
  /// from the last poll, fetching only for an address it hasn't seen.
  @override
  Future<void> markSeen(String paneId) async {
    paneId = _raw(paneId);
    _pendingText.remove(paneId);
    final cached = _seen[paneId];
    final (turn, seen) = cached ?? await _fetchSeen(paneId);
    if (seen != null && seen >= turn) return;
    await _call('terminal.label', {
      'terminal': paneId,
      'labels': {'herdr.seen': '$turn'},
    });
    _seen[paneId] = (turn, turn);
  }

  Future<(int, int?)> _fetchSeen(String paneId) async {
    final record = await _call('terminal.get', {'terminal': paneId});
    final seen = _labelsOf(record)['herdr.seen'] as String?;
    return (record['turn'] as int? ?? 0, int.tryParse(seen ?? ''));
  }

  /// Runs `"$@"` under the user's login shell's PATH: hc's core may have
  /// been started with a bare PATH (launchd), where `claude` etc. aren't
  /// found. argv rides as positional args, never spliced into shell code.
  /// The inner command reads the same in sh/bash/zsh/fish. Its line is
  /// tagged because an interactive shell can print around it (fish emits a
  /// cursor-shape escape on exit, verified live).
  static const _loginShell = [
    '/bin/sh',
    '-c',
    r'p=$("${SHELL:-/bin/sh}" -lic "printenv PATH | sed s/^/drover-path=/"'
        r' </dev/null 2>/dev/null | sed -n "s/^drover-path=//p" | tail -n 1);'
        r' [ -n "$p" ] && PATH=$p && export PATH; exec "$@"',
    'sh',
  ];

  /// Starts [argv] in [cwd] as a new terminal in Herdr space [spaceId] and
  /// returns its (prefixed) address. [name] is sanitized to hc's `[a-z0-9_-]{1,32}`,
  /// and dropped on a collision rather than failing the launch.
  Future<String> runAgent({
    required List<String> argv,
    required String cwd,
    required String spaceId,
    String? name,
  }) async {
    final platform = await hostPlatform;
    Future<String> run(String? name) async {
      final result = await _call('terminal.run', {
        'argv': [if (platform is UnixHostPlatform) ..._loginShell, ...argv],
        'cwd': cwd,
        'labels': {
          'herdr.space': _raw(spaceId),
          'herdr.seen': '0',
          _launchedLabel: '1',
        },
        'name': ?name,
      });
      final address = result['address'];
      if (address is! String) {
        throw const HerdrException('transport', 'missing address field');
      }
      return _id(address);
    }

    if (name == null || name.trim().isEmpty) return run(null);
    try {
      // agentNameSlug's `[a-z][a-z0-9_-]{0,31}` is a subset of hc's names.
      return await run(agentNameSlug(name));
    } on HerdrException catch (e) {
      if (e.code != 'name_taken') rethrow;
      return run(null);
    }
  }

  static Never _unsupported(String what) =>
      throw HerdrException('unsupported', 'Herdr 2 does not support $what');

  @override
  Future<CreatedWorkspace> createWorkspace({
    required String label,
    String? cwd,
  }) async => _unsupported('creating workspaces');

  @override
  Future<void> closeWorkspace(String workspaceId) async =>
      _unsupported('closing workspaces');

  @override
  Future<void> renameWorkspace(String workspaceId, String label) async =>
      _unsupported('renaming workspaces');

  @override
  Future<String> splitPane({
    required String workspaceId,
    required String cwd,
  }) async => _unsupported('splitting panes');

  @override
  Future<bool> startAgent({
    required String name,
    required String kind,
    required String paneId,
  }) async => _unsupported('starting an agent in a pane; use runAgent');

  @override
  Future<void> renameAgent(String target, String name) async =>
      _unsupported('renaming agents');

  /// Herdr 2 has no plugins.
  @override
  Future<PluginInfo?> findPlugin(String pluginId) async => null;

  @override
  Future<String> pluginConfigDir(String pluginId) async =>
      _unsupported('plugins');
}
