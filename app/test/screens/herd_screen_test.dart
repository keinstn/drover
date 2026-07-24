import 'dart:convert';

import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/app_theme.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:drover/src/screens/herd_screen.dart';
import 'package:drover/src/screens/launch_agent_sheet.dart';
import 'package:drover/src/widgets/error_message_view.dart';
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

/// The screen under test wrapped in an app shell. Single-client tests pass
/// [client]; multi-host tests pass [hosts] plus a [clientFor] resolver.
Widget _herdApp({
  HerdrClient? client,
  HerdrClient Function(HerdHostRef)? clientFor,
  List<HerdHostRef> hosts = const [_hostRef],
  String? filterHostId,
  Duration pollInterval = const Duration(hours: 1),
  VoidCallback? onOpenHostSwitcher,
}) {
  return MaterialApp(
    theme: droverDarkTheme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: HerdScreen(
      hosts: hosts,
      clientFor: clientFor ?? (_) => client!,
      filterHostId: filterHostId,
      onOpenHostSwitcher: onOpenHostSwitcher ?? () {},
      onOpenSettings: () {},
      pollInterval: pollInterval,
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
    expect(find.textContaining('Agent Two'), findsOneWidget);
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

    final blockedTop = tester.getTopLeft(find.textContaining('Agent Two')).dy;
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
    expect(find.text('waiting for you 1'), findsOneWidget);
    expect(find.text('working 1'), findsOneWidget);
    expect(find.text('all done 0'), findsOneWidget);
    expect(find.text('resting 1'), findsOneWidget);

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
      expect(find.textContaining('Agent Bee'), findsOneWidget);
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
      expect(find.textContaining('Agent Bee'), findsOneWidget);
      expect(find.text('waiting for you 1'), findsOneWidget);
      expect(find.text('working 0'), findsOneWidget);

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
    expect(find.text('waiting for you 2'), findsOneWidget);

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
}
