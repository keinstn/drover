import '../models/agent_info.dart';
import '../models/agent_preset.dart';
import '../models/plugin_info.dart';
import '../models/remote_dir_entry.dart';
import '../models/workspace_info.dart';
import 'command_runner.dart';
import 'hc_client.dart';
import 'herdr_backend.dart';
import 'herdr_client.dart';
import 'host_platform.dart';

/// One host's herdr 1 and Herdr 2 behind one [HerdrClient]: lists merge both,
/// and a per-id call goes to the backend that issued the id
/// ([backendOfId]). Host-level calls go to the herdr 1 part when there is
/// one, else the Herdr 2 part.
///
/// A part whose CLI is missing is *absent*: skipped for [absentFor] while the
/// other part answers, then probed again. A gated [HcClient] whose core isn't
/// running is absent too, but re-probed every call (the gate is cheap), so
/// opening the Herdr app shows its agents on the next poll.
class CombinedHerdrClient implements HerdrClient {
  CombinedHerdrClient({
    HerdrClient? herdr,
    HcClient? hc,
    DateTime Function()? now,
  }) : assert(herdr != null || hc != null),
       _parts = {HerdrBackend.herdr: ?herdr, HerdrBackend.hc: ?hc},
       _now = now ?? DateTime.now;

  static const absentFor = Duration(minutes: 5);

  /// In order herdr, hc; host-level calls use the first.
  final Map<HerdrBackend, HerdrClient> _parts;
  final DateTime Function() _now;

  /// Per absent part: until when it's skipped, and the error that made it so.
  final _absent = <HerdrBackend, (DateTime, Object)>{};
  bool _probed = false;

  HerdrClient get _host => _parts.values.first;

  HerdrClient _for(String id) {
    final backend = backendOfId(id);
    return _parts[backend] ??
        (throw HerdrException('unsupported', 'no ${backend.name} on host'));
  }

  static bool _isNotRunning(Object e) =>
      e is HerdrException && e.code == HcClient.kHcNotRunning;

  bool _skipped(HerdrBackend b) {
    final absent = _absent[b];
    return absent != null && _now().isBefore(absent.$1);
  }

  /// Runs [call] on every part not known absent — or on all parts when every
  /// one is, so installing a CLI is noticed without a 5-minute wait — and
  /// merges what they return, with the failures of parts that weren't absent
  /// when another part answered.
  Future<(List<T>, List<(HerdrBackend, Object)>)> _merge<T>(
    Future<List<T>> Function(HerdrClient) call,
  ) async {
    var targets = _parts.keys.where((b) => !_skipped(b)).toList();
    if (targets.isEmpty) targets = _parts.keys.toList();
    final outcomes = await Future.wait([
      for (final b in targets)
        call(_parts[b]!).then<(List<T>?, Object?)>(
          (v) => (v, null),
          onError: (Object e) => (null, e),
        ),
    ]);
    _probed = true;
    final merged = <T>[];
    final errors = <(HerdrBackend, Object)>[];
    var anyOk = false;
    for (final (i, (value, error)) in outcomes.indexed) {
      final b = targets[i];
      if (error == null) {
        anyOk = true;
        _absent.remove(b);
        merged.addAll(value!);
      } else if (isHerdrBinaryMissing(error) ||
          (error is HerdrException &&
              error.code == HcClient.kHcUnsupportedHost)) {
        _absent[b] = (_now().add(absentFor), error);
      } else if (_isNotRunning(error)) {
        _absent[b] = (_now(), error); // absent, but not skipped
      } else {
        _absent.remove(b);
        errors.add((b, error));
      }
    }
    if (anyOk) return (merged, errors);
    // Nothing answered: a real error beats an absent part, herdr 1's beats
    // hc's. Among absent parts, hc's "not running" wins: it means Herdr 2 is
    // installed, so herdr 1's missing binary is the expected one.
    final absent = [for (final b in _parts.keys) ?_absent[b]?.$2];
    final error = errors.isNotEmpty
        ? errors.first.$2
        : absent.where(_isNotRunning).firstOrNull ?? absent.first;
    Error.throwWithStackTrace(error, StackTrace.current);
  }

  @override
  Future<({List<AgentInfo> agents, List<(HerdrBackend, Object)> partialErrors})>
  listAgentsReportingErrors() async {
    final (agents, errors) = await _merge((c) => c.listAgents());
    return (agents: agents, partialErrors: errors);
  }

  @override
  Future<List<AgentInfo>> listAgents() async =>
      (await listAgentsReportingErrors()).agents;

  // ponytail: a failing part's workspaces are dropped without a warning —
  // its agents' failure already shows in the herd poll's partial errors.
  @override
  Future<List<WorkspaceInfo>> listWorkspaces() async =>
      (await _merge((c) => c.listWorkspaces())).$1;

  @override
  Future<List<HerdrBackend>> availableBackends() async {
    final expired = _absent.keys.any((b) => !_skipped(b));
    if (!_probed || expired) {
      try {
        await listAgents();
      } catch (_) {
        // Absence is what's being asked; any other failure leaves the part
        // listed.
      }
    }
    return [
      for (final b in _parts.keys)
        if (!_absent.containsKey(b)) b,
    ];
  }

  @override
  HerdrClient clientFor(HerdrBackend b) =>
      _parts[b] ?? (throw StateError('no ${b.name} part'));

  @override
  HerdrBackend get backend => _parts.keys.first;

  // Host-level.

  @override
  String get herdrBin => _host.herdrBin;

  @override
  CommandRunner get runner => _host.runner;

  @override
  Future<HostPlatform> get hostPlatform => _host.hostPlatform;

  @override
  Future<String> version() async {
    final herdr = _parts[HerdrBackend.herdr];
    if (herdr == null) {
      throw const HerdrException('unsupported', 'no herdr 1 on host');
    }
    return herdr.version();
  }

  @override
  Future<List<AgentPreset>> detectAgents(List<AgentPreset> presets) =>
      _host.detectAgents(presets);

  @override
  Future<PluginInfo?> findPlugin(String pluginId) => _host.findPlugin(pluginId);

  @override
  Future<String> pluginConfigDir(String pluginId) =>
      _host.pluginConfigDir(pluginId);

  @override
  Future<CreatedWorkspace> createWorkspace({
    required String label,
    String? cwd,
  }) => _host.createWorkspace(label: label, cwd: cwd);

  @override
  Future<List<RemoteDirEntry>> listDirectory(String path) =>
      _host.listDirectory(path);

  @override
  Future<String> resolvePath(String path) => _host.resolvePath(path);

  // Per-id.

  @override
  Future<AgentInfo> getAgent(String target) async =>
      _for(target).getAgent(target);

  @override
  Future<String> readAgent(String target, {int lines = 120}) async =>
      _for(target).readAgent(target, lines: lines);

  @override
  Future<void> prompt(String paneId, String text) async =>
      _for(paneId).prompt(paneId, text);

  @override
  Future<void> sendKeys(String paneId, String key) async =>
      _for(paneId).sendKeys(paneId, key);

  @override
  Future<void> sendPaneText(String paneId, String text) async =>
      _for(paneId).sendPaneText(paneId, text);

  @override
  Future<void> closeAgent(String paneId) async =>
      _for(paneId).closeAgent(paneId);

  @override
  Future<void> markSeen(String paneId) async => _for(paneId).markSeen(paneId);

  @override
  Future<void> renameAgent(String target, String name) async =>
      _for(target).renameAgent(target, name);

  @override
  Future<void> closeWorkspace(String workspaceId) async =>
      _for(workspaceId).closeWorkspace(workspaceId);

  @override
  Future<void> renameWorkspace(String workspaceId, String label) async =>
      _for(workspaceId).renameWorkspace(workspaceId, label);

  @override
  Future<String> splitPane({
    required String workspaceId,
    required String cwd,
  }) async => _for(workspaceId).splitPane(workspaceId: workspaceId, cwd: cwd);

  @override
  Future<bool> startAgent({
    required String name,
    required String kind,
    required String paneId,
  }) async => _for(paneId).startAgent(name: name, kind: kind, paneId: paneId);
}
