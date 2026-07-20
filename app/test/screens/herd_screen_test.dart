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

void main() {
  testWidgets('shows agents grouped by workspace, blocked above idle', (
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

    final blockedTop = tester.getTopLeft(find.textContaining('Agent Two')).dy;
    final idleTop = tester.getTopLeft(find.textContaining('Agent One')).dy;
    expect(blockedTop, lessThan(idleTop));

    await tester.tap(find.text('Agent Three'));
    await tester.pumpAndSettle();

    expect(find.text('working · Project B'), findsOneWidget);
    expect(find.textContaining('p1'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

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
}
