import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/screens/launch_agent_sheet.dart';
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
  Future<void> uploadFile(String remotePath, List<int> bytes) async {}

  @override
  Future<void> dispose() async {}
}

CommandResult ok(String stdout) =>
    CommandResult(exitCode: 0, stdout: stdout, stderr: '');

CommandResult _response(String command) {
  if (command.contains('command -v')) {
    return ok('claude\n');
  }
  if (command.contains("'workspace' 'create'")) {
    return ok(
      '{"id":"1","result":{"workspace":'
      '{"workspace_id":"wZ","label":"proj"}}}',
    );
  }
  if (command.contains("'agent' 'start'")) {
    return ok('{"id":"1","result":{"type":"agent_started"}}');
  }
  throw StateError('unexpected command: $command');
}

/// Pushes [LaunchAgentSheet] as a route and captures its pop value.
class _Harness extends StatefulWidget {
  const _Harness({required this.client});

  final HerdrClient client;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool? poppedValue;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () async {
            poppedValue = await showModalBottomSheet<bool>(
              context: context,
              isScrollControlled: true,
              builder: (_) => LaunchAgentSheet(
                client: widget.client,
                existingCwds: const [],
              ),
            );
            setState(() {});
          },
          child: const Text('open'),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('shows the detected preset after loading', (tester) async {
    final runner = FakeCommandRunner(_response);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LaunchAgentSheet(client: client, existingCwds: const []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.byKey(const ValueKey('preset_claude')), findsOneWidget);
  });

  testWidgets(
    'new-workspace launch creates a workspace then starts the agent',
    (tester) async {
      final runner = FakeCommandRunner(_response);
      final client = HerdrClient(runner);

      await tester.pumpWidget(MaterialApp(home: _Harness(client: client)));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('cwd_field')),
        '/tmp/proj',
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('launch_button')));
      await tester.pumpAndSettle();

      final createIndex = runner.commands.indexWhere(
        (c) => c.contains("'workspace' 'create'"),
      );
      final startIndex = runner.commands.indexWhere(
        (c) => c.contains("'agent' 'start'"),
      );
      expect(createIndex, greaterThanOrEqualTo(0));
      expect(startIndex, greaterThan(createIndex));
      expect(runner.commands[startIndex], contains("'--workspace'"));
      expect(runner.commands[startIndex], contains("'claude'"));

      final state = tester.state<_HarnessState>(find.byType(_Harness));
      expect(state.poppedValue, true);
    },
  );
}
