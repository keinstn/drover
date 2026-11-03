import 'dart:async';
import 'dart:convert';

import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/herdr/combined_client.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/app_theme.dart';
import 'package:drover/src/demo/demo_herdr.dart' show askUserTranscriptJsonl;
import 'package:drover/src/herdr/hc_client.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:drover/src/models/workspace_info.dart';
import 'package:drover/src/screens/agent_screen.dart';
import 'package:drover/src/screens/herd_screen.dart';
import 'package:drover/src/screens/launch_agent_sheet.dart';
import 'package:drover/src/widgets/agent_status_indicator.dart';
import 'package:drover/src/widgets/error_message_view.dart';
import 'package:drover/src/widgets/status_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCommandRunner extends CommandRunner {
  FakeCommandRunner(this._response);

  final CommandResult Function(String command) _response;
  final commands = <String>[];

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
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

const _listEnvelope =
    '{"id":"1","result":{"agents":['
    '{"agent":"claude","agent_status":"idle","cwd":"/tmp/proj-a",'
    '"focused":false,"pane_id":"wA:p1","tab_id":"wA:t1",'
    '"workspace_id":"wA","name":"Agent One"},'
    '{"agent":"claude","agent_status":"blocked","cwd":"/tmp/proj-a",'
    '"focused":false,"pane_id":"wA:p2","tab_id":"wA:t1",'
    '"workspace_id":"wA","name":"Agent Two"},'
    '{"agent":"claude","agent_status":"working","cwd":"/tmp/proj-b",'
    '"focused":false,"pane_id":"wB:p1","tab_id":"wB:t1",'
    '"workspace_id":"wB","name":"Agent Three"}'
    ']}}';

CommandResult _respond(String command) {
  if (command.contains("'workspace' 'list'")) {
    return ok(
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"wA","label":"Project A"},'
      '{"workspace_id":"wB","label":"Project B"}'
      ']}}',
    );
  }
  if (command.contains("'workspace' 'rename'") ||
      command.contains("'agent' 'rename'")) {
    return ok('{"id":"1","result":{"type":"ok"}}');
  }
  return ok(_listEnvelope);
}

/// Like [_respond], but reports a herdr version below [kMinHerdrVersion].
CommandResult _respondOldHerdr(String command) {
  if (command.contains("'--version'")) return ok('herdr 0.7.0\n');
  return _respond(command);
}

/// Like [_respondOldHerdr], but the background version probe (fired from
/// `initState`) fails its first call — as if it simply hadn't resolved yet —
/// so the bucket's cached version stays null. A later, deliberate
/// `--version` call (e.g. the launch-time authoritative re-check) succeeds
/// and reports the old version. Each call returns a fresh closure so the
/// call counter doesn't leak between tests.
CommandResult Function(String) _respondVersionUncachedThenOld() {
  var versionCalls = 0;
  return (command) {
    if (command.contains("'--version'")) {
      versionCalls++;
      if (versionCalls == 1) {
        return CommandResult(exitCode: 1, stdout: '', stderr: 'transient');
      }
      return ok('herdr 0.7.0\n');
    }
    return _respond(command);
  };
}

// The second host reuses host A's workspace/pane ids on purpose: they are
// only unique within a host, so the multi-host tests double as a check that
// nothing (keys included) collides across hosts.
const _hostBListEnvelope =
    '{"id":"1","result":{"agents":['
    '{"agent":"codex","agent_status":"blocked","cwd":"/tmp/proj-x",'
    '"focused":false,"pane_id":"wA:p1","tab_id":"wA:t1",'
    '"workspace_id":"wA","name":"Agent Bee"}'
    ']}}';

CommandResult _respondB(String command) {
  if (command.contains('command -v')) {
    return ok('claude\n');
  }
  if (command.contains("'workspace' 'list'")) {
    return ok(
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"wA","label":"Project X"}]}}',
    );
  }
  return ok(_hostBListEnvelope);
}

/// A Herdr 2 client: one agent in a space, one outside any space ('').
class _FakeHcClient extends HcClient {
  _FakeHcClient() : super(FakeCommandRunner((_) => ok('')));

  var listWorkspacesCalls = 0;

  @override
  Future<String> version() async => 'hc 0.1.17';

  @override
  Future<List<AgentInfo>> listAgents() async => const [
    AgentInfo(
      paneId: 'hc:t1',
      workspaceId: 'hc:s1',
      tabId: 'hc:tb1',
      agent: 'claude',
      name: 'Spaced',
      status: AgentStatus.idle,
      cwd: '/tmp/a',
      focused: false,
    ),
    AgentInfo(
      paneId: 'hc:t2',
      workspaceId: '',
      tabId: 'hc:tb2',
      agent: 'claude',
      name: 'Loose',
      status: AgentStatus.idle,
      cwd: '/tmp/b',
      focused: false,
    ),
  ];

  @override
  Future<List<WorkspaceInfo>> listWorkspaces() async {
    listWorkspacesCalls++;
    return const [WorkspaceInfo(workspaceId: 'hc:s1', label: 'Space One')];
  }

  @override
  Future<String> readAgent(String target, {int lines = 120}) async => '';
}

/// A Herdr 2 part whose listing fails while herdr 1's answers.
class _FailingHcClient extends _FakeHcClient {
  @override
  Future<List<AgentInfo>> listAgents() async =>
      throw const HerdrException('transport', 'core crashed');
}

/// A Herdr 2 part with an agent in a space that has no label, and no name.
class _UnlabeledSpaceHcClient extends _FakeHcClient {
  @override
  Future<List<AgentInfo>> listAgents() async => const [
    AgentInfo(
      paneId: 'hc:t7',
      workspaceId: 'hc:s9',
      tabId: 'hc:tb7',
      agent: null,
      status: AgentStatus.idle,
      cwd: '/tmp/a',
      focused: false,
    ),
  ];
}

/// herdr 1 ([_respond]'s agents) plus Herdr 2 ([hc]) on one host.
CombinedHerdrClient _mixedClient(
  _FakeHcClient hc, {
  CommandResult Function(String) herdr = _respond,
}) => CombinedHerdrClient(herdr: HerdrClient(FakeCommandRunner(herdr)), hc: hc);

const _hostRef = HerdHostRef(
  hostId: 'host-1',
  displayName: 'Work Mac',
  revision: 0,
);
const _hostRefA = HerdHostRef(
  hostId: 'host-a',
  displayName: 'Host One',
  revision: 0,
);
const _hostRefB = HerdHostRef(
  hostId: 'host-b',
  displayName: 'Host Two',
  revision: 0,
);
const _hostRefEverConnected = HerdHostRef(
  hostId: 'host-a',
  displayName: 'Host One',
  revision: 0,
  hostEverConnected: true,
);

/// Any `Container` carrying a [BoxDecoration] — used with `find.ancestor` to
/// reach the nearest decorated box around a piece of text (a workspace card,
/// a status chip) and assert its geometry.
final _decoratedContainer = find.byWidgetPredicate(
  (widget) => widget is Container && widget.decoration is BoxDecoration,
);

/// Text inside a workspace-list agent tile (each sits in a [Dismissible]),
/// excluding the same agent's card in the "needs you" inbox above.
Finder _inTile(String text) => find.descendant(
  of: find.byType(Dismissible),
  matching: find.textContaining(text),
);

/// The screen under test wrapped in an app shell. Single-client tests pass
/// [client]; multi-host tests pass [hosts] plus a [clientFor] resolver.
Widget _herdApp({
  HerdrClient? client,
  HerdrClient Function(HerdHostRef)? clientFor,
  List<HerdHostRef> hosts = const [_hostRef],
  String? filterHostId,
  Duration pollInterval = const Duration(hours: 1),
  VoidCallback? onOpenHostSwitcher,
  Locale? locale,
  Stream<void>? networkChanges,
}) {
  return MaterialApp(
    theme: droverDarkTheme,
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    // The working avatar's ring marches forever; reduced motion keeps it
    // static so pumpAndSettle can settle.
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: HerdScreen(
      hosts: hosts,
      clientFor: clientFor ?? (_) => client!,
      filterHostId: filterHostId,
      onOpenHostSwitcher: onOpenHostSwitcher ?? () {},
      onOpenSettings: () {},
      pollInterval: pollInterval,
      networkChanges: networkChanges,
    ),
  );
}

/// A [CommandRunner] backing two Claude agent panes with genuine native
/// session files (served via [statFile]/[readFile]), so `HerdScreen`'s
/// per-pane `NativeTranscriptHistory` cache can be exercised through the real
/// `ClaudeTranscriptLoader`/registry path (not a test double), the same as
/// production. Each pane's session-file "locate" (`find`) lookup is recorded
/// so a test can tell whether opening a pane reused an already-resolved
/// loader/path or re-resolved one from scratch.
class NativeHistoryHerdRunner extends CommandRunner {
  final commands = <String>[];

  /// pane id -> claude session id
  final sessions = <String, String>{
    'wA:p1': 'aaaaaaaa-0000-4000-8000-000000000001',
    'wB:p1': 'bbbbbbbb-0000-4000-8000-000000000002',
  };

  /// claude session id -> that session's JSONL contents.
  final sessionContents = <String, String>{
    'aaaaaaaa-0000-4000-8000-000000000001':
        '{"type":"user","message":{"role":"user","content":"Hello from A"}}\n',
    'bbbbbbbb-0000-4000-8000-000000000002':
        '{"type":"user","message":{"role":"user","content":"Hello from B"}}\n',
  };

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
    if (command.contains("'workspace' 'list'")) {
      return ok(
        '{"id":"1","result":{"workspaces":['
        '{"workspace_id":"wA","label":"Project A"},'
        '{"workspace_id":"wB","label":"Project B"}'
        ']}}',
      );
    }
    if (command.contains("'agent' 'list'")) {
      // Mirrors production herdr, whose list entries carry agent_session —
      // AgentScreen now resolves the current agent (and its native history)
      // from `agent list`, not `agent get`.
      final entries = sessions.keys.map((paneId) {
        final workspaceId = paneId.split(':').first;
        final sessionId = sessions[paneId];
        return '{"agent":"claude","agent_status":"idle",'
            '"cwd":"/tmp/proj","focused":false,"pane_id":"$paneId",'
            '"tab_id":"$workspaceId:t1","workspace_id":"$workspaceId",'
            '"name":"Agent $paneId",'
            '"agent_session":{"source":"claude","agent":"claude","kind":"id",'
            '"value":"$sessionId"}}';
      });
      return ok('{"id":"1","result":{"agents":[${entries.join(',')}]}}');
    }
    if (command.contains("'agent' 'get'")) {
      final paneId = sessions.keys.firstWhere(
        (id) => command.contains("'$id'"),
      );
      final workspaceId = paneId.split(':').first;
      final sessionId = sessions[paneId];
      return ok(
        '{"id":"1","result":{"agent":{"agent":"claude","agent_status":"idle",'
        '"cwd":"/tmp/proj","focused":false,"pane_id":"$paneId",'
        '"tab_id":"$workspaceId:t1","workspace_id":"$workspaceId",'
        '"name":"Agent $paneId",'
        '"agent_session":{"source":"claude","agent":"claude","kind":"id",'
        '"value":"$sessionId"}}}}',
      );
    }
    if (command.contains("'agent' 'read'")) {
      return ok('working…');
    }
    if (command.startsWith('command find ')) {
      final match = RegExp(r"-name '([^']+)\.jsonl'").firstMatch(command);
      final sessionId = match?.group(1);
      return ok('/home/dev/.claude/projects/-tmp-proj/$sessionId.jsonl\n');
    }
    return ok('{"id":"1","result":{}}');
  }

  String? _sessionIdFromPath(String path) {
    final fileName = path.split('/').last;
    return fileName.endsWith('.jsonl')
        ? fileName.substring(0, fileName.length - '.jsonl'.length)
        : null;
  }

  @override
  Future<RemoteFileStat> statFile(String path) async {
    final text = sessionContents[_sessionIdFromPath(path)] ?? '';
    return RemoteFileStat(size: utf8.encode(text).length);
  }

  @override
  Future<List<int>> readFile(String path, {int offset = 0, int? length}) async {
    final text = sessionContents[_sessionIdFromPath(path)] ?? '';
    final bytes = utf8.encode(text);
    final end = length == null
        ? bytes.length
        : (offset + length).clamp(0, bytes.length);
    return bytes.sublist(offset, end);
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

const _inboxPaneText =
    'Bash command\n'
    '\n'
    '  touch spike-test.txt\n'
    '\n'
    ' Do you want to proceed?\n'
    ' \u276f 1. Yes\n'
    '   2. No, tell it what to do\n'
    '\n'
    ' Esc to cancel\n';

/// A one-agent host for the "needs you" inbox tests: [status] and [agentType]
/// drive the listing, `agent read` is counted, and `agent prompt` is recorded
/// (or throws while [failPrompt]).
class _InboxHost {
  String status = 'blocked';
  String agentType = 'aider';
  bool failPrompt = false;
  int reads = 0;
  final prompts = <String>[];

  /// The Claude session JSONL served as native history; null means the agent
  /// reports no `agent_session` (so no history can load).
  String? transcript;

  /// What `agent read` returns.
  String paneText = _inboxPaneText;

  /// Native-history file reads (via [_InboxRunner]).
  int historyReads = 0;

  CommandResult respond(String command) {
    if (command.startsWith('command find ')) {
      return ok(
        '/home/dev/.claude/projects/-tmp-proj-a/$_inboxSessionId.jsonl\n',
      );
    }
    if (command.contains("'agent' 'read'")) {
      reads++;
      return ok(paneText);
    }
    if (command.contains("'agent' 'prompt'")) {
      if (failPrompt) throw Exception('boom');
      prompts.add(command);
      return ok('{"id":"1","result":{"type":"ok"}}');
    }
    if (command.contains("'workspace' 'list'")) {
      return ok(
        '{"id":"1","result":{"workspaces":['
        '{"workspace_id":"wA","label":"Project A"}]}}',
      );
    }
    return ok(
      '{"id":"1","result":{"agents":['
      '{"agent":"$agentType","agent_status":"$status","cwd":"/tmp/proj-a",'
      '"focused":false,"pane_id":"wA:p1","tab_id":"wA:t1",'
      '"workspace_id":"wA","name":"Agent Inbox"'
      '${transcript == null ? '' : ',"agent_session":{"source":"claude",'
                '"agent":"claude","kind":"id","value":"$_inboxSessionId"}'}'
      '}]}}',
    );
  }
}

const _inboxSessionId = 'cccccccc-0000-4000-8000-000000000003';

/// Serves [_InboxHost.transcript] as the session file's bytes.
class _InboxRunner extends FakeCommandRunner {
  _InboxRunner(this.host) : super(host.respond);

  final _InboxHost host;

  List<int> get _bytes => utf8.encode(host.transcript ?? '');

  @override
  Future<RemoteFileStat> statFile(String path) async =>
      RemoteFileStat(size: _bytes.length);

  @override
  Future<List<int>> readFile(String path, {int offset = 0, int? length}) async {
    host.historyReads++;
    final bytes = _bytes;
    final end = length == null
        ? bytes.length
        : (offset + length).clamp(0, bytes.length);
    return bytes.sublist(offset, end);
  }
}

void main() {
  testWidgets('shows session titles grouped by workspace, blocked above idle', (
    tester,
  ) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Agent One'), findsOneWidget);
    expect(_inTile('Agent Two'), findsOneWidget);
    expect(find.textContaining('Agent Three'), findsOneWidget);
    expect(find.text('Project A'), findsOneWidget);
    expect(find.text('Project B'), findsOneWidget);
    expect(find.text('wA'), findsNothing);
    expect(find.text('wB'), findsNothing);
    expect(find.textContaining('p1'), findsNothing);
    expect(find.textContaining('p2'), findsNothing);
    // A single stored host renders no host section header.
    expect(find.text('Work Mac'), findsNothing);
    // No pane was opened, so every tile's activity snippet falls back to the
    // `agentType · cwd` metadata.
    expect(find.text('claude · proj-a'), findsNWidgets(2));
    expect(find.text('claude · proj-b'), findsOneWidget);

    final blockedTop = tester.getTopLeft(_inTile('Agent Two')).dy;
    final idleTop = tester.getTopLeft(find.textContaining('Agent One')).dy;
    expect(blockedTop, lessThan(idleTop));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('greets with the blocked count and a per-status chip row', (
    tester,
  ) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    // One agent is blocked in the fixture, so the greeting names that count.
    expect(find.textContaining('1 agent', findRichText: true), findsOneWidget);

    // The chip row shows every status with its count (0 included), using the
    // renewed human labels.
    expect(find.text('WAITING FOR YOU 1'), findsOneWidget);
    expect(find.text('WORKING 1'), findsOneWidget);
    expect(find.text('ALL DONE 0'), findsOneWidget);
    expect(find.text('RESTING 1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('greets all-clear when nothing is blocked', (tester) async {
    const envelope =
        '{"id":"1","result":{"agents":['
        '{"agent":"claude","agent_status":"idle","cwd":"/tmp/proj-a",'
        '"focused":false,"pane_id":"wA:p1","tab_id":"wA:t1",'
        '"workspace_id":"wA","name":"Agent One"}'
        ']}}';
    final runner = FakeCommandRunner((command) {
      if (command.contains("'workspace' 'list'")) {
        return ok(
          '{"id":"1","result":{"workspaces":['
          '{"workspace_id":"wA","label":"Project A"}]}}',
        );
      }
      return ok(envelope);
    });
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    expect(
      find.textContaining("Everyone's on track.", findRichText: true),
      findsOneWidget,
    );
    // The waiting-count greeting (and its accent count) is absent.
    expect(
      find.textContaining('waiting for your reply', findRichText: true),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'suspends periodic list polling while AgentScreen is open, resumes '
    'after popping',
    (tester) async {
      final runner = FakeCommandRunner(_respond);
      final client = HerdrClient(runner);

      await tester.pumpWidget(
        _herdApp(client: client, pollInterval: const Duration(seconds: 1)),
      );
      await tester.pump();
      await tester.pump();

      int listCalls() =>
          runner.commands.where((c) => c.contains("'agent' 'list'")).length;

      // Two polling ticks confirm the periodic poll is indeed running before
      // the detail route is pushed.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      final beforePush = listCalls();
      expect(beforePush, greaterThan(1));

      await tester.tap(find.text('Agent One'));
      await tester.pumpAndSettle();
      final atPush = listCalls();

      // While AgentScreen is open (pushed on top), the herd's own 1s poll
      // must stay suspended. AgentScreen legitimately polls `agent list`
      // itself for the switcher bar on its default 2s interval, so exactly
      // one call lands in these three elapsed seconds — the herd's cadence
      // would have added three more.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(listCalls(), atPush + 1);

      // Popping back resumes polling — an immediate refresh fires right
      // away, without waiting for the next tick.
      await tester.tap(find.byKey(const ValueKey('agent_back_button')));
      await tester.pumpAndSettle();
      expect(listCalls(), greaterThan(atPush));

      final afterPop = listCalls();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(listCalls(), greaterThan(afterPop));

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'shows the agent CLI terminal title (CLI suffix stripped) as the tile '
    'title',
    (tester) async {
      const envelope =
          '{"id":"1","result":{"agents":['
          '{"agent":"copilot","agent_status":"working","cwd":"/tmp/proj-b",'
          '"focused":false,"pane_id":"wB:p1","tab_id":"wB:t1",'
          '"workspace_id":"wB",'
          '"terminal_title_stripped":"Herd の session 表示を設計 - GitHub Copilot"}'
          ']}}';
      final runner = FakeCommandRunner((command) {
        if (command.contains("'workspace' 'list'")) {
          return ok(
            '{"id":"1","result":{"workspaces":['
            '{"workspace_id":"wB","label":"Project B"}]}}',
          );
        }
        return ok(envelope);
      });
      final client = HerdrClient(runner);

      await tester.pumpWidget(_herdApp(client: client));
      await tester.pump();
      await tester.pump();

      expect(find.text('Herd の session 表示を設計'), findsOneWidget);
      expect(
        find.textContaining('GitHub Copilot'),
        findsNothing,
        reason: 'the CLI-specific suffix is stripped from the title',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reuses a pane\'s native transcript history/loader across leaving and '
    'reopening its AgentScreen, keeping a separate one per pane',
    (tester) async {
      final runner = NativeHistoryHerdRunner();
      final client = HerdrClient(runner);
      final sessionA = runner.sessions['wA:p1']!;
      final sessionB = runner.sessions['wB:p1']!;

      int locateCallsFor(String sessionId) => runner.commands
          .where((c) => c.contains("-name '$sessionId.jsonl'"))
          .length;

      await tester.pumpWidget(_herdApp(client: client));
      await tester.pump();
      await tester.pump();

      // Open pane A: its native history loads (one session-file locate).
      await tester.tap(find.text('Agent wA:p1'));
      await tester.pumpAndSettle();
      expect(find.text('Hello from A'), findsOneWidget);
      expect(locateCallsFor(sessionA), 1);

      await tester.tap(find.byKey(const ValueKey('agent_back_button')));
      await tester.pumpAndSettle();

      // Reopening the very same pane must reuse the cached
      // NativeTranscriptHistory/loader instance (resuming from its
      // already-known path/offset) rather than re-locating the session file
      // from scratch.
      await tester.tap(find.text('Agent wA:p1'));
      await tester.pumpAndSettle();
      expect(find.text('Hello from A'), findsOneWidget);
      expect(locateCallsFor(sessionA), 1);

      await tester.tap(find.byKey(const ValueKey('agent_back_button')));
      await tester.pumpAndSettle();

      // A different pane gets its own, independent history/loader: opening
      // it locates its own session file, and pane A's cached state (and
      // locate count) is unaffected.
      await tester.tap(find.text('Agent wB:p1'));
      await tester.pumpAndSettle();
      expect(find.text('Hello from B'), findsOneWidget);
      expect(locateCallsFor(sessionB), 1);
      expect(locateCallsFor(sessionA), 1);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'tile activity snippet reflects the pane\'s cached transcript once opened',
    (tester) async {
      final runner = NativeHistoryHerdRunner();
      final client = HerdrClient(runner);

      await tester.pumpWidget(_herdApp(client: client));
      await tester.pump();
      await tester.pump();

      // Before opening, the snippet is the metadata fallback (no cached
      // transcript yet).
      expect(find.text('claude · proj'), findsNWidgets(2));
      expect(find.text('Hello from A'), findsNothing);

      await tester.tap(find.text('Agent wA:p1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent_back_button')));
      await tester.pumpAndSettle();

      // Back on the herd, that pane's tile now derives its snippet from the
      // loaded native transcript; the other pane still shows the fallback.
      expect(find.text('Hello from A'), findsOneWidget);
      expect(find.text('claude · proj'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('shows the launch-agent FAB', (tester) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('launch_agent_fab')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('workspace card uses the large radius and an outlineVariant '
      'hairline', (tester) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    final decoration =
        tester
                .widget<Container>(
                  find
                      .ancestor(
                        of: find.text('Project A'),
                        matching: _decoratedContainer,
                      )
                      .first,
                )
                .decoration!
            as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(droverRadiusLarge));
    // Dark had no card hairline at all before the ink redesign.
    expect(
      decoration.border,
      Border.all(color: droverDarkTheme.colorScheme.outlineVariant),
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('status summary entry is plain text, not a pill', (tester) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    // No decorated ancestor of the entry carries the old pill fill or
    // border — the label sits directly on the page.
    final decorations = tester
        .widgetList<Container>(
          find.ancestor(
            of: find.text('WAITING FOR YOU 1'),
            matching: _decoratedContainer,
          ),
        )
        .map((c) => c.decoration! as BoxDecoration);
    for (final d in decorations) {
      expect(
        d.color,
        isNot(DroverColors.dark.statusPillBg(AgentStatus.blocked)),
      );
      expect(d.border, isNull);
    }

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('agent tiles carry status as a trailing indicator', (
    tester,
  ) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pumpAndSettle();

    expect(find.textContaining('Agent Three'), findsOneWidget);
    expect(find.byType(StatusPill), findsNothing);

    // The working agent's tile ends in a working indicator…
    Finder indicatorIn(String name) => find.descendant(
      of: find.ancestor(of: find.text(name), matching: find.byType(InkWell)),
      matching: find.byType(AgentStatusIndicator),
    );
    expect(
      tester.widget<AgentStatusIndicator>(indicatorIn('Agent Three')).status,
      AgentStatus.working,
    );
    // …announced, so the dropped pill's text still reaches a screen reader.
    // (The tile merges it into its own announcement.)
    expect(
      tester.getSemantics(indicatorIn('Agent Two')).label,
      contains('waiting for you'),
    );

    // An idle agent's title goes muted; a working one keeps the default ink.
    final scheme = Theme.of(tester.element(find.text('Agent One'))).colorScheme;
    expect(
      tester.widget<Text>(find.text('Agent One')).style!.color,
      scheme.onSurfaceVariant,
    );
    expect(tester.widget<Text>(find.text('Agent Three')).style!.color, isNull);

    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('label ramp leaves Japanese uncased', (tester) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    // The launch FAB's caption is a fixed localized string, which is what
    // the ramp is for — a workspace label is user-chosen and stays off it.
    // Asserting both directions keeps this from passing trivially if the
    // ramp's case treatment were dropped altogether.
    await tester.pumpWidget(
      _herdApp(client: client, locale: const Locale('en')),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('LAUNCH AGENT'), findsOneWidget);
    expect(find.text('Launch agent'), findsNothing);

    await tester.pumpWidget(
      _herdApp(client: client, locale: const Locale('ja')),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('エージェントを起動'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows a warning when the host\'s herdr is too old', (
    tester,
  ) async {
    final runner = FakeCommandRunner(_respondOldHerdr);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('herdr_version_warning_host-1')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('blocks launching a new agent when the herdr is too old', (
    tester,
  ) async {
    final runner = FakeCommandRunner(_respondOldHerdr);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('launch_agent_fab')));
    await tester.pumpAndSettle();

    expect(find.byType(LaunchAgentSheet), findsNothing);
    expect(runner.commands.any((c) => c.contains("'agent' 'start'")), isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'blocks launching when the herdr version was not yet cached (race with '
    'the background probe)',
    (tester) async {
      final runner = FakeCommandRunner(_respondVersionUncachedThenOld());
      final client = HerdrClient(runner);

      await tester.pumpWidget(_herdApp(client: client));
      await tester.pump();
      await tester.pump();

      // The background probe's first (only, so far) call failed, so no
      // cached warning is shown yet.
      expect(
        find.byKey(const ValueKey('herdr_version_warning_host-1')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('launch_agent_fab')));
      await tester.pumpAndSettle();

      expect(find.byType(LaunchAgentSheet), findsNothing);
      expect(
        runner.commands.any((c) => c.contains("'agent' 'start'")),
        isFalse,
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('chip reads "All hosts" when no host filter is set', (
    tester,
  ) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    expect(find.text('Drover'), findsOneWidget);
    expect(find.byKey(const ValueKey('host_switcher_chip')), findsOneWidget);
    expect(find.text('All hosts'), findsOneWidget);
    expect(find.text('Work Mac'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'chip shows the filtered host name and opens the switcher when tapped',
    (tester) async {
      var switcherCalls = 0;
      final runner = FakeCommandRunner(_respond);
      final client = HerdrClient(runner);

      await tester.pumpWidget(
        _herdApp(
          client: client,
          filterHostId: 'host-1',
          onOpenHostSwitcher: () => switcherCalls++,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Drover'), findsOneWidget);
      expect(find.text('Work Mac'), findsOneWidget);
      expect(find.text('All hosts'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('host_switcher_chip')));
      await tester.pump();

      expect(switcherCalls, 1);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('left swipe asks for confirmation before stopping an agent', (
    tester,
  ) async {
    final runner = FakeCommandRunner((_) => ok(_listEnvelope));
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    await tester.drag(
      find.byKey(const ValueKey('agent-host-1-wA:p1')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();

    expect(find.text('Stop agent?'), findsOneWidget);
    expect(find.textContaining('Agent One (wA:p1)'), findsOneWidget);
    expect(
      runner.commands,
      isNot(contains("~/.local/bin/herdr 'pane' 'close' 'wA:p1'")),
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Stop agent?'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stops an agent after confirming a left swipe', (tester) async {
    final runner = FakeCommandRunner((_) => ok(_listEnvelope));
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    await tester.drag(
      find.byKey(const ValueKey('agent-host-1-wA:p1')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
    await tester.pumpAndSettle();

    expect(
      runner.commands,
      contains("~/.local/bin/herdr 'pane' 'close' 'wA:p1'"),
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('long press on workspace header renames workspace', (
    tester,
  ) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    await tester.longPress(find.text('Project A'));
    await tester.pumpAndSettle();

    expect(find.text('Rename workspace'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Delivery');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(
      runner.commands,
      contains("~/.local/bin/herdr 'workspace' 'rename' 'wA' 'Delivery'"),
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('long press on an agent renames the agent', (tester) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();

    await tester.longPress(find.byKey(const ValueKey('agent-host-1-wA:p1')));
    await tester.pumpAndSettle();

    expect(find.text('Rename agent'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Pair Driver');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(
      runner.commands,
      contains("~/.local/bin/herdr 'agent' 'rename' 'wA:p1' 'Pair Driver'"),
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'rename dialog prefills with the agent slug name, not the session title',
    (tester) async {
      const envelope =
          '{"id":"1","result":{"agents":['
          '{"agent":"copilot","agent_status":"working","cwd":"/tmp/proj-b",'
          '"focused":false,"pane_id":"wB:p1","tab_id":"wB:t1",'
          '"workspace_id":"wB","name":"scout",'
          '"terminal_title_stripped":"Herd の session 表示を設計 - GitHub Copilot"}'
          ']}}';
      final runner = FakeCommandRunner((command) {
        if (command.contains("'workspace' 'list'")) {
          return ok(
            '{"id":"1","result":{"workspaces":['
            '{"workspace_id":"wB","label":"Project B"}]}}',
          );
        }
        return ok(envelope);
      });
      final client = HerdrClient(runner);

      await tester.pumpWidget(_herdApp(client: client));
      await tester.pump();
      await tester.pump();

      await tester.longPress(find.byKey(const ValueKey('agent-host-1-wB:p1')));
      await tester.pumpAndSettle();

      expect(find.text('Rename agent'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'scout'),
        findsOneWidget,
        reason: 'the field prefills with the editable slug name',
      );
      expect(
        find.widgetWithText(TextField, 'Herd の session 表示を設計'),
        findsNothing,
        reason: 'the read-only session title is never used as the edit value',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'rename dialog hints the CLI name when the agent has no slug name yet',
    (tester) async {
      const envelope =
          '{"id":"1","result":{"agents":['
          '{"agent":"copilot","agent_status":"working","cwd":"/tmp/proj-b",'
          '"focused":false,"pane_id":"wB:p1","tab_id":"wB:t1",'
          '"workspace_id":"wB",'
          '"terminal_title_stripped":"Herd の session 表示を設計 - GitHub Copilot"}'
          ']}}';
      final runner = FakeCommandRunner((command) {
        if (command.contains("'workspace' 'list'")) {
          return ok(
            '{"id":"1","result":{"workspaces":['
            '{"workspace_id":"wB","label":"Project B"}]}}',
          );
        }
        return ok(envelope);
      });
      final client = HerdrClient(runner);

      await tester.pumpWidget(_herdApp(client: client));
      await tester.pump();
      await tester.pump();

      await tester.longPress(find.byKey(const ValueKey('agent-host-1-wB:p1')));
      await tester.pumpAndSettle();

      expect(find.text('Rename agent'), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(
        field.controller?.text,
        isEmpty,
        reason: 'an unnamed agent starts with a blank field',
      );
      expect(
        field.decoration?.hintText,
        'copilot',
        reason: 'the CLI kind hints what to type',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'renders each host\'s agents under its own section header in the All '
    'view',
    (tester) async {
      // Tall enough that the needs-you inbox above doesn't push host B's
      // section out of the lazily built list.
      tester.view.physicalSize = const Size(2400, 6000);
      addTearDown(tester.view.reset);
      final runnerA = FakeCommandRunner(_respond);
      final runnerB = FakeCommandRunner(_respondB);
      final clientA = HerdrClient(runnerA);
      final clientB = HerdrClient(runnerB);

      await tester.pumpWidget(
        _herdApp(
          hosts: const [_hostRefA, _hostRefB],
          clientFor: (ref) => ref.hostId == 'host-a' ? clientA : clientB,
        ),
      );
      await tester.pump();
      await tester.pump();

      // Host section headers appear because more than one host is stored.
      expect(find.text('Host One'), findsOneWidget);
      expect(find.text('Host Two'), findsOneWidget);

      // Each host's agents and workspace labels render in its section —
      // including the same workspace id ("wA") existing on both hosts.
      expect(find.textContaining('Agent One'), findsOneWidget);
      expect(_inTile('Agent Bee'), findsOneWidget);
      expect(find.text('Project A'), findsOneWidget);
      expect(find.text('Project X'), findsOneWidget);

      // Host A's section (first in the stored order) sits above host B's.
      final headerATop = tester.getTopLeft(find.text('Host One')).dy;
      final headerBTop = tester.getTopLeft(find.text('Host Two')).dy;
      expect(headerATop, lessThan(headerBTop));

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'isolates one host\'s failure: its section shows the error and retry, '
    'the other host still renders and drives the counts',
    (tester) async {
      final runnerA = FakeCommandRunner((_) => throw Exception('boom'));
      final runnerB = FakeCommandRunner(_respondB);
      final clientA = HerdrClient(runnerA);
      final clientB = HerdrClient(runnerB);

      await tester.pumpWidget(
        _herdApp(
          hosts: const [_hostRefA, _hostRefB],
          clientFor: (ref) => ref.hostId == 'host-a' ? clientA : clientB,
        ),
      );
      await tester.pump();
      await tester.pump();

      // Host A failed: an inline error with its per-host retry button.
      expect(find.byType(ErrorMessageView), findsWidgets);
      expect(find.byKey(const ValueKey('host_retry_host-a')), findsOneWidget);

      // Host B is unaffected, and the global counts reflect it alone.
      expect(_inTile('Agent Bee'), findsOneWidget);
      expect(find.text('WAITING FOR YOU 1'), findsOneWidget);
      expect(find.text('WORKING 0'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a host that has connected before shows the lost-connection message, '
    'not the generic address/port one',
    (tester) async {
      final runnerA = FakeCommandRunner((_) => throw Exception('boom'));
      final runnerB = FakeCommandRunner(_respondB);
      final clientA = HerdrClient(runnerA);
      final clientB = HerdrClient(runnerB);

      await tester.pumpWidget(
        _herdApp(
          hosts: const [_hostRefEverConnected, _hostRefB],
          clientFor: (ref) => ref.hostId == 'host-a' ? clientA : clientB,
        ),
      );
      await tester.pump();
      await tester.pump();

      // Both the agents-list error and the workspace-labels error rows show
      // it, since the fake runner fails every command.
      expect(find.textContaining('Lost the connection'), findsWidgets);
      expect(find.textContaining('address and port are correct'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the per-host retry button reloads that host', (tester) async {
    var fail = true;
    final runnerA = FakeCommandRunner((command) {
      if (fail) throw Exception('boom');
      return _respond(command);
    });
    final runnerB = FakeCommandRunner(_respondB);
    final clientA = HerdrClient(runnerA);
    final clientB = HerdrClient(runnerB);

    await tester.pumpWidget(
      _herdApp(
        hosts: const [_hostRefA, _hostRefB],
        clientFor: (ref) => ref.hostId == 'host-a' ? clientA : clientB,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('host_retry_host-a')), findsOneWidget);
    expect(find.textContaining('Agent One'), findsNothing);

    fail = false;
    await tester.tap(find.byKey(const ValueKey('host_retry_host-a')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('host_retry_host-a')), findsNothing);
    expect(find.textContaining('Agent One'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('polls only the filtered host and shows its name in the chip', (
    tester,
  ) async {
    final runnerA = FakeCommandRunner(_respond);
    final runnerB = FakeCommandRunner(_respondB);
    final clientA = HerdrClient(runnerA);
    final clientB = HerdrClient(runnerB);

    await tester.pumpWidget(
      _herdApp(
        hosts: const [_hostRefA, _hostRefB],
        clientFor: (ref) => ref.hostId == 'host-a' ? clientA : clientB,
        filterHostId: 'host-a',
        pollInterval: const Duration(seconds: 1),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(find.textContaining('Agent One'), findsOneWidget);
    expect(find.textContaining('Agent Bee'), findsNothing);
    expect(runnerB.commands, isEmpty);

    // The chip carries the filtered host's name, not "All hosts". (The
    // name also heads the section, hence two matches.)
    expect(find.text('Host One'), findsWidgets);
    expect(find.text('All hosts'), findsNothing);
    expect(find.text('Host Two'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('greeting counts blocked agents across every host', (
    tester,
  ) async {
    final runnerA = FakeCommandRunner(_respond);
    final runnerB = FakeCommandRunner(_respondB);
    final clientA = HerdrClient(runnerA);
    final clientB = HerdrClient(runnerB);

    await tester.pumpWidget(
      _herdApp(
        hosts: const [_hostRefA, _hostRefB],
        clientFor: (ref) => ref.hostId == 'host-a' ? clientA : clientB,
      ),
    );
    await tester.pump();
    await tester.pump();

    // One blocked agent on each host.
    expect(find.textContaining('2 agents', findRichText: true), findsOneWidget);
    expect(find.text('WAITING FOR YOU 2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'FAB in the All view first asks which host to launch on, then opens the '
    'launch sheet against the picked host',
    (tester) async {
      final runnerA = FakeCommandRunner(_respond);
      final runnerB = FakeCommandRunner(_respondB);
      final clientA = HerdrClient(runnerA);
      final clientB = HerdrClient(runnerB);

      await tester.pumpWidget(
        _herdApp(
          hosts: const [_hostRefA, _hostRefB],
          clientFor: (ref) => ref.hostId == 'host-a' ? clientA : clientB,
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('launch_agent_fab')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('launch_host_host-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('launch_host_host-b')), findsOneWidget);
      expect(find.byType(LaunchAgentSheet), findsNothing);

      await tester.tap(find.byKey(const ValueKey('launch_host_host-b')));
      await tester.pumpAndSettle();

      expect(find.byType(LaunchAgentSheet), findsOneWidget);
      // The sheet's agent detection ran against host B, not host A.
      expect(runnerB.commands.any((c) => c.contains('command -v')), isTrue);
      expect(runnerA.commands.any((c) => c.contains('command -v')), isFalse);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a revision bump resets the host\'s bucket and refetches', (
    tester,
  ) async {
    const rebuiltEnvelope =
        '{"id":"1","result":{"agents":['
        '{"agent":"claude","agent_status":"idle","cwd":"/tmp/proj-a",'
        '"focused":false,"pane_id":"wA:p1","tab_id":"wA:t1",'
        '"workspace_id":"wA","name":"Agent New"}'
        ']}}';
    final oldClient = HerdrClient(FakeCommandRunner(_respond));
    final newClient = HerdrClient(
      FakeCommandRunner((command) {
        if (command.contains("'workspace' 'list'")) {
          return ok(
            '{"id":"1","result":{"workspaces":['
            '{"workspace_id":"wA","label":"Project A"}]}}',
          );
        }
        return ok(rebuiltEnvelope);
      }),
    );

    await tester.pumpWidget(_herdApp(client: oldClient));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Agent One'), findsOneWidget);

    // The host's connection was rebuilt (config edit): same hostId, bumped
    // revision, new client. The stale bucket must be dropped and refetched.
    await tester.pumpWidget(
      _herdApp(
        client: newClient,
        hosts: const [
          HerdHostRef(hostId: 'host-1', displayName: 'Work Mac', revision: 1),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Agent New'), findsOneWidget);
    expect(find.textContaining('Agent One'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed host is skipped by the immediately following tick', (
    tester,
  ) async {
    final runner = FakeCommandRunner((_) => throw Exception('boom'));
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      _herdApp(client: client, pollInterval: const Duration(seconds: 1)),
    );
    await tester.pump();
    await tester.pump();

    int listCalls() =>
        runner.commands.where((c) => c.contains("'agent' 'list'")).length;
    expect(listCalls(), 1, reason: 'the initial load ran (and failed)');

    // The next tick lands well inside the failure backoff window
    // (2 x pollInterval on the first failure), so the host is skipped. The
    // backoff schedule itself is unit-tested via [herdPollBackoff] — fake
    // timers advance test time, but DateTime.now() stays real.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(listCalls(), 1);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a network-change event clears a host\'s backoff so the next poll tick '
    'reloads it for real, without the event itself triggering a load',
    (tester) async {
      final runner = FakeCommandRunner((_) => throw Exception('boom'));
      final client = HerdrClient(runner);
      final networkChanges = StreamController<void>.broadcast();
      addTearDown(networkChanges.close);
      // 30s: the failStreak-1 backoff cap, matching the real "up to 30s"
      // window the issue complains about — a wide margin against the real
      // wall clock the "still armed" check below depends on (see the
      // linked doc comment on herdPollBackoff).
      const pollInterval = Duration(seconds: 30);
      const retryButton = ValueKey('host_retry_host-1');

      await tester.pumpWidget(
        _herdApp(
          client: client,
          pollInterval: pollInterval,
          networkChanges: networkChanges.stream,
        ),
      );
      await tester.pump();
      await tester.pump();

      int listCalls() =>
          runner.commands.where((c) => c.contains("'agent' 'list'")).length;
      expect(listCalls(), 1, reason: 'the initial load ran (and failed)');
      expect(find.byKey(retryButton), findsOneWidget);

      // One pollInterval later, the tick is still inside the failure
      // backoff window (2 x pollInterval on the first failure; nextPollAt
      // is compared against the real clock, which has barely moved), so the
      // host is skipped — proving the backoff is genuinely armed before the
      // signal is exercised at all.
      await tester.pump(pollInterval);
      await tester.pump();
      expect(listCalls(), 1);

      // Firing the signal alone must not itself issue a load — but it must
      // have run: the error (and its retry button) disappears immediately,
      // proving the handler executed within this pump rather than the
      // assertion below passing vacuously because it hadn't yet.
      networkChanges.add(null);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(retryButton), findsNothing);
      expect(listCalls(), 1, reason: 'but issued no load of its own');

      // With the backoff cleared, the next ordinary tick polls for real.
      await tester.pump(pollInterval);
      await tester.pump();
      expect(listCalls(), 2);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'rebuilding with a different networkChanges stream resubscribes: the '
    'new controller is heard and the old one no longer acts',
    (tester) async {
      final runner = FakeCommandRunner((_) => throw Exception('boom'));
      final client = HerdrClient(runner);
      final oldController = StreamController<void>.broadcast();
      addTearDown(oldController.close);
      final newController = StreamController<void>.broadcast();
      addTearDown(newController.close);
      const pollInterval = Duration(seconds: 30);
      const retryButton = ValueKey('host_retry_host-1');

      await tester.pumpWidget(
        _herdApp(
          client: client,
          pollInterval: pollInterval,
          networkChanges: oldController.stream,
        ),
      );
      await tester.pump();
      await tester.pump();

      int listCalls() =>
          runner.commands.where((c) => c.contains("'agent' 'list'")).length;
      expect(listCalls(), 1, reason: 'the initial load ran (and failed)');
      expect(find.byKey(retryButton), findsOneWidget);

      // Rebuild with a genuinely different controller's stream — the shape
      // main.dart's own rebuild takes if the underlying signal were ever
      // swapped, and the only shape that can actually discriminate whether
      // didUpdateWidget's cancel-and-relisten ran: with the SAME controller,
      // an old subscription left listening would still hear a later event
      // fired on it (same source), passing either way.
      await tester.pumpWidget(
        _herdApp(
          client: client,
          pollInterval: pollInterval,
          networkChanges: newController.stream,
        ),
      );
      await tester.pump();

      // The discriminating half: an event on the OLD controller must no
      // longer be acted on — if the resubscribe branch were deleted (or a
      // no-op), the original subscription would still be listening to it and
      // would clear the backoff here.
      oldController.add(null);
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(retryButton),
        findsOneWidget,
        reason: 'the old controller must have been unsubscribed',
      );
      expect(listCalls(), 1);

      // An event on the NEW controller must be heard.
      newController.add(null);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(retryButton), findsNothing);
      expect(listCalls(), 1, reason: 'the signal itself issues no load');

      await tester.pump(pollInterval);
      await tester.pump();
      expect(listCalls(), 2);

      await tester.pumpWidget(const SizedBox());
    },
  );

  /// Answers the launch sheet's commands; once `agent start` has run, the
  /// listing carries the new `wZ:p1` agent only when [listsLaunched] is set.
  CommandResult Function(String) launchResponder({
    required bool listsLaunched,
  }) {
    var started = false;
    return (command) {
      if (command.contains('command -v')) return ok('claude\n');
      if (command.contains("'workspace' 'create'")) {
        return ok(
          '{"id":"1","result":{"workspace":'
          '{"workspace_id":"wZ","label":"proj"},'
          '"root_pane":{"pane_id":"wZ:p1"}}}',
        );
      }
      if (command.contains("'agent' 'start'")) {
        started = true;
        return ok('{"id":"1","result":{"type":"agent_started"}}');
      }
      if (command.contains("'agent' 'list'") && started && listsLaunched) {
        return ok(
          '{"id":"1","result":{"agents":['
          '{"agent":"claude","agent_status":"idle","cwd":"/tmp/proj",'
          '"focused":false,"pane_id":"wZ:p1","tab_id":"wZ:t1",'
          '"workspace_id":"wZ","name":"Agent New"}]}}',
        );
      }
      return _respond(command);
    };
  }

  Future<void> launchFromSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('launch_agent_fab')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('cwd_field')),
      '/tmp/proj',
    );
    await tester.pump();
    // The sheet is taller than the 800x600 test surface; scroll to the CTA.
    await tester.ensureVisible(find.byKey(const ValueKey('launch_button')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('launch_button')));
    // Not pumpAndSettle: the pushed agent screen polls on a timer.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('a launch from the sheet opens the new agent', (tester) async {
    final client = HerdrClient(
      FakeCommandRunner(launchResponder(listsLaunched: true)),
    );

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();
    await launchFromSheet(tester);

    expect(find.byType(LaunchAgentSheet), findsNothing);
    expect(find.byType(AgentScreen), findsOneWidget);
    expect(find.text('Agent New'), findsWidgets);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('a launched agent missing from the listing stays on the herd', (
    tester,
  ) async {
    final client = HerdrClient(
      FakeCommandRunner(launchResponder(listsLaunched: false)),
    );

    await tester.pumpWidget(_herdApp(client: client));
    await tester.pump();
    await tester.pump();
    await launchFromSheet(tester);

    expect(find.byType(LaunchAgentSheet), findsNothing);
    expect(find.byType(AgentScreen), findsNothing);
    expect(find.byType(HerdScreen), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  group('HerdHostRef', () {
    test('equality and hashCode account for hostEverConnected', () {
      const a = HerdHostRef(hostId: 'h', displayName: 'H', revision: 0);
      const b = HerdHostRef(
        hostId: 'h',
        displayName: 'H',
        revision: 0,
        hostEverConnected: true,
      );
      expect(a, isNot(equals(b)));
      expect(a.hashCode, isNot(equals(b.hashCode)));
      expect(
        a,
        equals(const HerdHostRef(hostId: 'h', displayName: 'H', revision: 0)),
      );
    });
  });

  group('needs you inbox', () {
    final yes = find.widgetWithText(FilledButton, 'Yes');

    testWidgets('shows a blocked agent\'s question and options, answers one, '
        'and drops the card once it is no longer blocked', (tester) async {
      final host = _InboxHost();
      final runner = FakeCommandRunner(host.respond);
      await tester.pumpWidget(_herdApp(client: HerdrClient(runner)));
      await tester.pump();
      await tester.pump();

      expect(find.text('NEEDS YOU'), findsOneWidget);
      expect(find.text('Do you want to proceed?'), findsOneWidget);
      expect(yes, findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, 'No, tell it what to do'),
        findsOneWidget,
      );
      expect(find.text('aider · Project A'), findsOneWidget);
      expect(find.text('OPEN'), findsNothing);
      expect(find.text('Open'), findsOneWidget);

      host.status = 'idle';
      await tester.tap(yes);
      await tester.pump();
      await tester.pump();

      expect(host.prompts, ["~/.local/bin/herdr 'agent' 'prompt' 'wA:p1' '1'"]);
      expect(find.text('NEEDS YOU'), findsNothing);
      expect(yes, findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('reads the pane once per blocked episode, not every poll', (
      tester,
    ) async {
      final host = _InboxHost();
      await tester.pumpWidget(
        _herdApp(
          client: HerdrClient(FakeCommandRunner(host.respond)),
          pollInterval: const Duration(seconds: 2),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(seconds: 2));
      }
      expect(host.reads, 1);
      expect(yes, findsOneWidget);

      // Leaving blocked drops the cache; the next episode reads again.
      host.status = 'working';
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('NEEDS YOU'), findsNothing);
      host.status = 'blocked';
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(host.reads, 2);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('returning from the agent screen refetches a still-blocked '
        'pane\'s prompt', (tester) async {
      final host = _InboxHost();
      await tester.pumpWidget(
        _herdApp(client: HerdrClient(FakeCommandRunner(host.respond))),
      );
      await tester.pump();
      await tester.pump();
      expect(yes, findsOneWidget);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(AgentScreen), findsOneWidget);

      // Answered there; the agent is immediately blocked on the next prompt,
      // which the suspended herd poll never saw as non-blocked.
      host.paneText = _inboxPaneText
          .replaceFirst('Do you want to proceed?', 'Overwrite the file?')
          .replaceFirst('1. Yes', '1. Overwrite');
      await tester.tap(find.byKey(const ValueKey('agent_back_button')));
      await tester.pumpAndSettle();

      expect(find.text('Overwrite the file?'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Overwrite'), findsOneWidget);
      expect(find.text('Do you want to proceed?'), findsNothing);
      expect(yes, findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no section when nothing is blocked', (tester) async {
      final host = _InboxHost()..status = 'idle';
      await tester.pumpWidget(
        _herdApp(client: HerdrClient(FakeCommandRunner(host.respond))),
      );
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Agent Inbox'), findsOneWidget);
      expect(find.text('NEEDS YOU'), findsNothing);
      expect(host.reads, 0);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an agent with structured prompts whose history can\'t load '
        'only offers Open', (tester) async {
      final host = _InboxHost()..agentType = 'claude';
      await tester.pumpWidget(
        _herdApp(client: HerdrClient(FakeCommandRunner(host.respond))),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('NEEDS YOU'), findsOneWidget);
      expect(find.text('Do you want to proceed?'), findsOneWidget);
      expect(yes, findsNothing);
      expect(find.text('Open'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failed answer toasts and re-enables the options', (
      tester,
    ) async {
      final host = _InboxHost()..failPrompt = true;
      await tester.pumpWidget(
        _herdApp(client: HerdrClient(FakeCommandRunner(host.respond))),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(yes);
      await tester.pump();
      await tester.pump();

      expect(
        find.text("Couldn't send the answer to Agent Inbox"),
        findsOneWidget,
      );
      expect(tester.widget<FilledButton>(yes).onPressed, isNotNull);
      expect(find.text('NEEDS YOU'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });

  group('needs you inbox with structured prompts', () {
    final yes = find.widgetWithText(FilledButton, 'Yes');
    const plainHistory =
        '{"type":"user","message":{"role":"user","content":"Hello"}}\n';

    testWidgets('a fresh history with nothing pending shows the options, '
        'loaded once across polls', (tester) async {
      final host = _InboxHost()
        ..agentType = 'claude'
        ..transcript = plainHistory;
      await tester.pumpWidget(
        _herdApp(
          client: HerdrClient(_InboxRunner(host)),
          pollInterval: const Duration(seconds: 2),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('Do you want to proceed?'), findsOneWidget);
      expect(yes, findsOneWidget);
      final historyReads = host.historyReads;
      expect(historyReads, greaterThan(0));

      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(seconds: 2));
      }
      expect(host.historyReads, historyReads);
      expect(host.reads, 1);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a pending AskUserQuestion only offers Open', (tester) async {
      final host = _InboxHost()
        ..agentType = 'claude'
        ..transcript = askUserTranscriptJsonl;
      await tester.pumpWidget(
        _herdApp(client: HerdrClient(_InboxRunner(host))),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(host.historyReads, greaterThan(0));
      expect(find.text('NEEDS YOU'), findsOneWidget);
      expect(yes, findsNothing);
      expect(find.text('Open'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('herdPollBackoff', () {
    const interval = Duration(seconds: 2);

    test('doubles per consecutive failure', () {
      expect(herdPollBackoff(1, interval), const Duration(seconds: 4));
      expect(herdPollBackoff(2, interval), const Duration(seconds: 8));
      expect(herdPollBackoff(3, interval), const Duration(seconds: 16));
    });

    test('caps at 30 seconds', () {
      expect(herdPollBackoff(4, interval), const Duration(seconds: 30));
      expect(herdPollBackoff(5, interval), const Duration(seconds: 30));
    });

    test('clamps the exponent so a long streak cannot overflow', () {
      expect(
        herdPollBackoff(100, const Duration(milliseconds: 10)),
        const Duration(milliseconds: 320),
      );
    });
  });

  group('Herdr 2 host', () {
    testWidgets('labels the unspaced group, hides renames, skips the version '
        'gate', (tester) async {
      final client = _FakeHcClient();

      await tester.pumpWidget(
        _herdApp(client: client, pollInterval: const Duration(seconds: 2)),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Space One'), findsOneWidget);
      expect(find.text('Not in a space'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('herdr_version_warning_host-1')),
        findsNothing,
      );

      // The unspaced agent's '' id is never in the labels map; it must not
      // re-list spaces on every poll.
      final callsBefore = client.listWorkspacesCalls;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      expect(client.listWorkspacesCalls, callsBefore);

      // The launch FAB opens the sheet instead of a too-old toast.
      await tester.tap(find.byKey(const ValueKey('launch_agent_fab')));
      await tester.pumpAndSettle();
      expect(find.byType(LaunchAgentSheet), findsOneWidget);
      Navigator.of(tester.element(find.byType(LaunchAgentSheet))).pop();
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Space One'));
      await tester.pumpAndSettle();
      expect(find.text('Rename workspace'), findsNothing);
      await tester.longPress(find.byKey(const ValueKey('agent-host-1-hc:t2')));
      await tester.pumpAndSettle();
      expect(find.text('Rename agent'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tags hc hosts in the multi-host header', (tester) async {
      final herdr = HerdrClient(FakeCommandRunner(_respond));
      final hc = _FakeHcClient();
      await tester.pumpWidget(
        _herdApp(
          hosts: const [_hostRefA, _hostRefB],
          clientFor: (host) => host.hostId == 'host-b' ? hc : herdr,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('herdr2_tag_host-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('herdr2_tag_host-a')), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('host with both backends', () {
    Future<void> pumpMixed(WidgetTester tester, HerdrClient client) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_herdApp(client: client));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('renders both backends and tags only the Herdr 2 groups', (
      tester,
    ) async {
      await pumpMixed(tester, _mixedClient(_FakeHcClient()));

      expect(_inTile('Agent One'), findsOneWidget);
      expect(_inTile('Spaced'), findsOneWidget);
      expect(_inTile('Loose'), findsOneWidget);
      expect(find.text('Project A'), findsOneWidget);
      expect(find.text('Space One'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('herdr2_group_tag_hc:s1')),
        findsOneWidget,
      );
      // The unspaced group is Herdr 2's too.
      expect(find.byKey(const ValueKey('herdr2_group_tag_')), findsOneWidget);
      expect(find.text('Herdr 2'), findsNWidgets(2));
      expect(find.byKey(const ValueKey('herdr2_group_tag_wA')), findsNothing);
      expect(find.byKey(const ValueKey('herdr2_tag_host-1')), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('offers rename for the herdr 1 agent only', (tester) async {
      await pumpMixed(tester, _mixedClient(_FakeHcClient()));

      await tester.longPress(find.text('Space One'));
      await tester.pumpAndSettle();
      expect(find.text('Rename workspace'), findsNothing);

      await tester.longPress(find.byKey(const ValueKey('agent-host-1-wA:p1')));
      await tester.pumpAndSettle();
      expect(find.text('Rename agent'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Last: with no long-press handler, the hold falls through to a tap
      // and opens the agent.
      await tester.longPress(find.byKey(const ValueKey('agent-host-1-hc:t1')));
      await tester.pumpAndSettle();
      expect(find.text('Rename agent'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failing backend shows a warning; the other still renders', (
      tester,
    ) async {
      await pumpMixed(tester, _mixedClient(_FailingHcClient()));

      // Through the error-presentation path: a localized headline, with the
      // raw stderr only behind Details.
      expect(find.text('Herdr 2: Something went wrong.'), findsOneWidget);
      expect(find.textContaining('core crashed'), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('partial_error_host-1_hc')),
          matching: find.text('Details'),
        ),
      );
      await tester.pump();
      expect(find.text('core crashed'), findsOneWidget);
      expect(_inTile('Agent One'), findsOneWidget);
      expect(_inTile('Agent Three'), findsOneWidget);
      expect(_inTile('Spaced'), findsNothing);
      expect(find.byKey(const ValueKey('host_retry_host-1')), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a fallback label for an hc id hides the hc: prefix', (
      tester,
    ) async {
      await pumpMixed(tester, _mixedClient(_UnlabeledSpaceHcClient()));
      // The space has no label and the agent no name: both fall back to ids.
      expect(find.text('s9'), findsOneWidget);
      expect(_inTile('t7'), findsOneWidget);
      expect(find.textContaining('hc:'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an old herdr 1 warns but doesn\'t block opening the sheet', (
      tester,
    ) async {
      await pumpMixed(
        tester,
        _mixedClient(_FakeHcClient(), herdr: _respondOldHerdr),
      );
      expect(
        find.byKey(const ValueKey('herdr_version_warning_host-1')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('launch_agent_fab')));
      await tester.pumpAndSettle();
      expect(find.byType(LaunchAgentSheet), findsOneWidget);
      Navigator.of(tester.element(find.byType(LaunchAgentSheet))).pop();
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no herdr 1 part: no version warning', (tester) async {
      await pumpMixed(tester, CombinedHerdrClient(hc: _FakeHcClient()));
      expect(_inTile('Spaced'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('herdr_version_warning_host-1')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('herdr2_group_tag_hc:s1')),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox());
    });
  });
}
