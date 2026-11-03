import 'dart:async';

import 'package:drover/src/herdr/combined_client.dart';
import 'package:drover/src/herdr/hc_client.dart';
import 'package:drover/src/herdr/herdr_backend.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/herdr/host_platform.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/models/agent_preset.dart';
import 'package:drover/src/models/plugin_info.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:drover/src/models/workspace_info.dart';
import 'package:flutter_test/flutter_test.dart';

import 'hc_client_test.dart' show FakeHcRunner;

AgentInfo _agent(String paneId) => AgentInfo(
  paneId: paneId,
  workspaceId: '',
  tabId: '',
  agent: 'claude',
  status: AgentStatus.idle,
  cwd: '/',
  focused: false,
);

/// A part that records every call as `method(args)` and answers lists via
/// [agents]/[workspaces] (throw from them to fail the part).
class _Part extends HcClient {
  _Part(this.kind) : super(FakeHcRunner((_) => null));

  final HerdrBackend kind;
  FutureOr<List<AgentInfo>> Function()? agents;
  List<WorkspaceInfo> Function()? workspaces;
  final log = <String>[];
  int listCalls = 0;

  @override
  HerdrBackend get backend => kind;

  Future<T> _rec<T>(String call, T value) async {
    log.add(call);
    return value;
  }

  @override
  Future<List<AgentInfo>> listAgents() async {
    listCalls++;
    return (agents ?? () => [_agent('${kind.name}-agent')])();
  }

  @override
  Future<List<WorkspaceInfo>> listWorkspaces() async =>
      (workspaces ??
      () => [WorkspaceInfo(workspaceId: '${kind.name}-ws', label: 'l')])();

  @override
  Future<String> version() => _rec('version', '${kind.name} 1');
  @override
  Future<AgentInfo> getAgent(String t) => _rec('getAgent($t)', _agent(t));
  @override
  Future<String> readAgent(String t, {int lines = 120}) =>
      _rec('readAgent($t,$lines)', 'text');
  @override
  Future<void> prompt(String p, String text) => _rec('prompt($p,$text)', null);
  @override
  Future<void> sendKeys(String p, String k) => _rec('sendKeys($p,$k)', null);
  @override
  Future<void> sendPaneText(String p, String t) =>
      _rec('sendPaneText($p,$t)', null);
  @override
  bool canTypeWithoutEnter(String p, String t) {
    log.add('canTypeWithoutEnter($p,$t)');
    return true;
  }

  @override
  Future<void> closeAgent(String p) => _rec('closeAgent($p)', null);
  @override
  Future<void> markSeen(String p) => _rec('markSeen($p)', null);
  @override
  Future<void> renameAgent(String t, String n) =>
      _rec('renameAgent($t,$n)', null);
  @override
  Future<void> closeWorkspace(String w) => _rec('closeWorkspace($w)', null);
  @override
  Future<void> renameWorkspace(String w, String l) =>
      _rec('renameWorkspace($w,$l)', null);
  @override
  Future<String> splitPane({
    required String workspaceId,
    required String cwd,
  }) => _rec('splitPane($workspaceId,$cwd)', 'p');
  @override
  Future<bool> startAgent({
    required String name,
    required String kind,
    required String paneId,
  }) => _rec('startAgent($name,$kind,$paneId)', true);
  @override
  Future<List<AgentPreset>> detectAgents(List<AgentPreset> presets) =>
      _rec('detectAgents', presets);
  @override
  Future<PluginInfo?> findPlugin(String id) => _rec('findPlugin($id)', null);
  @override
  Future<String> pluginConfigDir(String id) =>
      _rec('pluginConfigDir($id)', '/d');
  @override
  Future<CreatedWorkspace> createWorkspace({
    required String label,
    String? cwd,
  }) => _rec(
    'createWorkspace($label,$cwd)',
    const CreatedWorkspace(workspaceId: 'w', paneId: 'p'),
  );
  @override
  Future<List<RemoteDirEntry>> listDirectory(String path) =>
      _rec('listDirectory($path)', const []);
  @override
  Future<String> resolvePath(String path) => _rec('resolvePath($path)', path);
}

const _missing = HerdrException(
  'transport',
  'herdr agent list failed (exit 127): sh: herdr: not found',
);
final _sshDown = HerdrException(
  'transport',
  'ssh down',
  cause: StateError('x'),
);

void main() {
  late _Part herdr;
  late _Part hc;
  late DateTime now;
  CombinedHerdrClient both() =>
      CombinedHerdrClient(herdr: herdr, hc: hc, now: () => now);

  setUp(() {
    herdr = _Part(HerdrBackend.herdr);
    hc = _Part(HerdrBackend.hc);
    now = DateTime(2026, 11, 3);
  });

  /// Every id-taking call, against [id].
  Future<void> perId(HerdrClient c, String id) async {
    await c.getAgent(id);
    await c.readAgent(id, lines: 5);
    await c.prompt(id, 'hi');
    await c.sendKeys(id, 'esc');
    await c.sendPaneText(id, 'x');
    c.canTypeWithoutEnter(id, 'y');
    await c.closeAgent(id);
    await c.markSeen(id);
    await c.renameAgent(id, 'n');
    await c.closeWorkspace(id);
    await c.renameWorkspace(id, 'l');
    await c.splitPane(workspaceId: id, cwd: '/c');
    await c.startAgent(name: 'n', kind: 'claude', paneId: id);
  }

  List<String> perIdLog(String id) => [
    'getAgent($id)',
    'readAgent($id,5)',
    'prompt($id,hi)',
    'sendKeys($id,esc)',
    'sendPaneText($id,x)',
    'canTypeWithoutEnter($id,y)',
    'closeAgent($id)',
    'markSeen($id)',
    'renameAgent($id,n)',
    'closeWorkspace($id)',
    'renameWorkspace($id,l)',
    'splitPane($id,/c)',
    'startAgent(n,claude,$id)',
  ];

  group('routing', () {
    test('a herdr 1 id goes to the herdr part, unchanged', () async {
      await perId(both(), 'w2H:p1');
      expect(herdr.log, perIdLog('w2H:p1'));
      expect(hc.log, isEmpty);
    });

    test('an hc: id goes to the hc part, still prefixed', () async {
      await perId(both(), 'hc:t16');
      expect(hc.log, perIdLog('hc:t16'));
      expect(herdr.log, isEmpty);
    });

    test('an id for a backend the host lacks is unsupported', () async {
      final c = CombinedHerdrClient(hc: hc);
      await expectLater(
        c.readAgent('w2H:p1'),
        throwsA(
          isA<HerdrException>().having((e) => e.code, 'code', 'unsupported'),
        ),
      );
    });

    Future<void> hostLevel(HerdrClient c) async {
      await c.detectAgents(const []);
      await c.findPlugin('p');
      await c.pluginConfigDir('p');
      await c.createWorkspace(label: 'l', cwd: '/c');
      await c.listDirectory('/d');
      await c.resolvePath('.');
    }

    const hostLog = [
      'detectAgents',
      'findPlugin(p)',
      'pluginConfigDir(p)',
      'createWorkspace(l,/c)',
      'listDirectory(/d)',
      'resolvePath(.)',
    ];

    test('host-level calls go to herdr 1 when present', () async {
      final c = both();
      await hostLevel(c);
      expect(await c.version(), 'herdr 1');
      expect(herdr.log, [...hostLog, 'version']);
      expect(hc.log, isEmpty);
      expect(c.backend, HerdrBackend.herdr);
      expect(c.runner, same(herdr.runner));
      expect(c.herdrBin, herdr.herdrBin);
    });

    test('host-level calls go to hc without herdr 1', () async {
      final c = CombinedHerdrClient(hc: hc);
      await hostLevel(c);
      expect(hc.log, hostLog);
      expect(c.backend, HerdrBackend.hc);
      await expectLater(
        c.version(),
        throwsA(
          isA<HerdrException>().having((e) => e.code, 'code', 'unsupported'),
        ),
      );
    });

    test('clientFor hands out the part, e.g. to launch on hc', () {
      final c = both();
      expect(c.clientFor(HerdrBackend.herdr), same(herdr));
      expect(c.clientFor(HerdrBackend.hc), same(hc));
      expect(
        () => CombinedHerdrClient(hc: hc).clientFor(HerdrBackend.herdr),
        throwsStateError,
      );
    });
  });

  group('lists', () {
    test('merge both parts, herdr 1 first', () async {
      final c = both();
      expect((await c.listAgents()).map((a) => a.paneId), [
        'herdr-agent',
        'hc-agent',
      ]);
      expect((await c.listWorkspaces()).map((w) => w.workspaceId), [
        'herdr-ws',
        'hc-ws',
      ]);
      expect((await c.listAgentsReportingErrors()).partialErrors, isEmpty);
      expect(await c.availableBackends(), [
        HerdrBackend.herdr,
        HerdrBackend.hc,
      ]);
    });

    test('one part failing keeps the other and reports it', () async {
      hc.agents = () => throw _sshDown;
      final c = both();
      final r = await c.listAgentsReportingErrors();
      expect(r.agents.map((a) => a.paneId), ['herdr-agent']);
      expect(r.partialErrors.single.$1, HerdrBackend.hc);
      expect(r.partialErrors.single.$2, same(_sshDown));
      // Not absent: retried on the next poll, and cleared once it answers.
      hc.agents = null;
      final again = await c.listAgentsReportingErrors();
      expect(again.agents, hasLength(2));
      expect(again.partialErrors, isEmpty);
    });

    test(
      'a concurrent listing cannot clobber another\'s partial errors',
      () async {
        final failing = Completer<List<AgentInfo>>();
        final answering = Completer<List<AgentInfo>>();
        final pending = [failing, answering];
        hc.agents = () => pending.removeAt(0).future;
        final c = both();
        final a = c.listAgentsReportingErrors();
        final b = c.listAgents();
        failing.completeError(_sshDown);
        final aResult = await a;
        answering.complete([_agent('hc-agent')]);
        expect(await b, hasLength(2));
        expect(aResult.partialErrors.single.$1, HerdrBackend.hc);
        // Read after b finished: a's own result, not client state.
        expect(aResult.partialErrors, hasLength(1));
      },
    );

    test('both failing rethrows herdr 1\'s error', () async {
      herdr.agents = () => throw const HerdrException('a', 'herdr');
      hc.agents = () => throw const HerdrException('b', 'hc');
      await expectLater(both().listAgents(), throwsA(_code('a')));
    });

    test('a real error beats a missing binary', () async {
      herdr.agents = () => throw _missing;
      hc.agents = () => throw const HerdrException('b', 'hc');
      await expectLater(both().listAgents(), throwsA(_code('b')));
    });

    test('both absent throws hc\'s "not running" over herdr 1\'s missing '
        'binary: Herdr 2 is installed', () async {
      herdr.agents = () => throw _missing;
      hc.agents = () =>
          throw const HerdrException(HcClient.kHcNotRunning, 'no core');
      await expectLater(
        both().listAgents(),
        throwsA(_code(HcClient.kHcNotRunning)),
      );
    });

    test('both missing throws herdr 1\'s missing error', () async {
      herdr.agents = () => throw _missing;
      hc.agents = () => throw _missing;
      await expectLater(both().listAgents(), throwsA(same(_missing)));
    });
  });

  group('absent parts', () {
    test('a missing binary is skipped for 5 minutes, then re-probed', () async {
      herdr.agents = () => throw _missing;
      final c = both();
      final r = await c.listAgentsReportingErrors();
      expect(r.agents.map((a) => a.paneId), ['hc-agent']);
      expect(r.partialErrors, isEmpty, reason: 'absent is not a warning');
      expect(await c.availableBackends(), [HerdrBackend.hc]);

      now = now.add(const Duration(minutes: 4));
      await c.listAgents();
      expect(herdr.listCalls, 1);

      herdr.agents = null; // installed meanwhile
      now = now.add(const Duration(minutes: 2));
      expect(await c.listAgents(), hasLength(2));
      expect(herdr.listCalls, 2);
      expect(await c.availableBackends(), [
        HerdrBackend.herdr,
        HerdrBackend.hc,
      ]);
    });

    test('a not-running core is absent but re-probed every poll', () async {
      hc.agents = () =>
          throw const HerdrException(HcClient.kHcNotRunning, 'no core');
      final c = both();
      final r = await c.listAgentsReportingErrors();
      expect(r.agents, hasLength(1));
      expect(r.partialErrors, isEmpty);
      expect(await c.availableBackends(), [HerdrBackend.herdr]);

      // The Herdr app opens: the next poll shows its agents, and the launch
      // sheet offers Herdr 2, with no 5-minute wait.
      hc.agents = null;
      expect(await c.listAgents(), hasLength(2));
      expect(await c.availableBackends(), [
        HerdrBackend.herdr,
        HerdrBackend.hc,
      ]);
    });

    test('a real gated HcClient with no core reads as absent', () async {
      final runner = FakeHcRunner.raw(
        (_) => const CommandResult(
          exitCode: 3,
          stdout: '',
          stderr: '${HcClient.notRunningMarker}\n',
        ),
      );
      final c = CombinedHerdrClient(
        herdr: herdr,
        hc: HcClient(
          runner,
          requireRunningCore: true,
          platform: () => const UnixHostPlatform(),
        ),
      );
      final r = await c.listAgentsReportingErrors();
      expect(r.agents.map((a) => a.paneId), ['herdr-agent']);
      expect(r.partialErrors, isEmpty);
      expect(runner.commands.first, contains('pgrep -x -U'));
      expect(await c.availableBackends(), [HerdrBackend.herdr]);
    });

    test('with every part absent, each poll re-probes', () async {
      final c = CombinedHerdrClient(herdr: herdr, now: () => now);
      herdr.agents = () => throw _missing;
      await expectLater(c.listAgents(), throwsA(same(_missing)));
      herdr.agents = null;
      expect(await c.listAgents(), hasLength(1));
      expect(herdr.listCalls, 2);
    });

    test('availableBackends probes once when nothing is known', () async {
      hc.agents = () => throw _missing;
      final c = both();
      expect(await c.availableBackends(), [HerdrBackend.herdr]);
      expect(await c.availableBackends(), [HerdrBackend.herdr]);
      expect(herdr.listCalls, 1);
    });
  });

  test('a single-backend client reports itself', () async {
    final c = HerdrClient(FakeHcRunner((_) => null));
    expect(await c.availableBackends(), [HerdrBackend.herdr]);
    expect(c.clientFor(HerdrBackend.herdr), same(c));
    final r = await herdr.listAgentsReportingErrors();
    expect(r.agents, hasLength(1));
    expect(r.partialErrors, isEmpty);
  });
}

Matcher _code(String code) =>
    isA<HerdrException>().having((e) => e.code, 'code', code);
