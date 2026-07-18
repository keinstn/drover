import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/screens/herd_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCommandRunner implements CommandRunner {
  FakeCommandRunner(this._response);

  final CommandResult Function(String command) _response;
  final commands = <String>[];

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
    return _response(command);
  }

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

void main() {
  testWidgets('shows agents grouped by workspace, blocked above idle', (
    tester,
  ) async {
    final runner = FakeCommandRunner((_) => ok(_listEnvelope));
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
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
    expect(find.text('wA'), findsOneWidget);
    expect(find.text('wB'), findsOneWidget);

    final blockedTop = tester.getTopLeft(find.textContaining('Agent Two')).dy;
    final idleTop = tester.getTopLeft(find.textContaining('Agent One')).dy;
    expect(blockedTop, lessThan(idleTop));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows the launch-agent FAB', (tester) async {
    final runner = FakeCommandRunner((_) => ok(_listEnvelope));
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
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
}
