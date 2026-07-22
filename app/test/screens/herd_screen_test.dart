import 'dart:convert';

import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:drover/src/screens/herd_screen.dart';
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
      final entries = sessions.keys.map((paneId) {
        final workspaceId = paneId.split(':').first;
        return '{"agent":"claude","agent_status":"idle",'
            '"cwd":"/tmp/proj","focused":false,"pane_id":"$paneId",'
            '"tab_id":"$workspaceId:t1","workspace_id":"$workspaceId",'
            '"name":"Agent $paneId"}';
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

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HerdScreen(
          client: client,
          onOpenSettings: () {},
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
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
    expect(find.text('claude · proj-a'), findsNWidgets(2));
    expect(find.text('claude · proj-b'), findsOneWidget);

    final blockedTop = tester.getTopLeft(find.textContaining('Agent Two')).dy;
    final idleTop = tester.getTopLeft(find.textContaining('Agent One')).dy;
    expect(blockedTop, lessThan(idleTop));

    await tester.tap(find.text('Agent Three'));
    await tester.pumpAndSettle();

    expect(find.text('working · claude · Project B'), findsOneWidget);
    expect(find.textContaining('p1'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'suspends periodic list polling while AgentScreen is open, resumes '
    'after popping',
    (tester) async {
      final runner = FakeCommandRunner(_respond);
      final client = HerdrClient(runner);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HerdScreen(
            client: client,
            onOpenSettings: () {},
            pollInterval: const Duration(seconds: 1),
          ),
        ),
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

      // While AgentScreen is open (pushed on top), further elapsed poll
      // intervals must not issue any more `agent list` calls.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(listCalls(), atPush);

      // Popping back resumes polling — an immediate refresh fires right
      // away, without waiting for the next tick.
      await tester.pageBack();
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

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HerdScreen(
            client: client,
            onOpenSettings: () {},
            pollInterval: const Duration(hours: 1),
          ),
        ),
      );
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

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HerdScreen(
            client: client,
            onOpenSettings: () {},
            pollInterval: const Duration(hours: 1),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Open pane A: its native history loads (one session-file locate).
      await tester.tap(find.text('Agent wA:p1'));
      await tester.pumpAndSettle();
      expect(find.text('Hello from A'), findsOneWidget);
      expect(locateCallsFor(sessionA), 1);

      await tester.pageBack();
      await tester.pumpAndSettle();

      // Reopening the very same pane must reuse the cached
      // NativeTranscriptHistory/loader instance (resuming from its
      // already-known path/offset) rather than re-locating the session file
      // from scratch.
      await tester.tap(find.text('Agent wA:p1'));
      await tester.pumpAndSettle();
      expect(find.text('Hello from A'), findsOneWidget);
      expect(locateCallsFor(sessionA), 1);

      await tester.pageBack();
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

  testWidgets('shows the launch-agent FAB', (tester) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HerdScreen(
          client: client,
          onOpenSettings: () {},
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('launch_agent_fab')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('left swipe asks for confirmation before stopping an agent', (
    tester,
  ) async {
    final runner = FakeCommandRunner((_) => ok(_listEnvelope));
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HerdScreen(
          client: client,
          onOpenSettings: () {},
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.drag(
      find.byKey(const ValueKey('agent-wA:p1')),
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

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HerdScreen(
          client: client,
          onOpenSettings: () {},
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.drag(
      find.byKey(const ValueKey('agent-wA:p1')),
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

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HerdScreen(
          client: client,
          onOpenSettings: () {},
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
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

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HerdScreen(
          client: client,
          onOpenSettings: () {},
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.longPress(find.byKey(const ValueKey('agent-wA:p1')));
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

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HerdScreen(
            client: client,
            onOpenSettings: () {},
            pollInterval: const Duration(hours: 1),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.longPress(find.byKey(const ValueKey('agent-wB:p1')));
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

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HerdScreen(
            client: client,
            onOpenSettings: () {},
            pollInterval: const Duration(hours: 1),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.longPress(find.byKey(const ValueKey('agent-wB:p1')));
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
}
