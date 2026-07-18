import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/screens/agent_screen.dart';
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

const _readText =
    'Bash command\n'
    '\n'
    '  touch spike-test.txt\n'
    '  Create empty file spike-test.txt\n'
    '\n'
    ' Do you want to proceed?\n'
    ' ❯ 1. Yes\n'
    '   2. Yes, and always allow access to drover-spike-test/ from this\n'
    '      project\n'
    '   3. No\n'
    '\n'
    ' Esc to cancel · Tab to amend · ctrl+e to explain\n';

CommandResult _respond(String command) {
  if (command.contains("'workspace' 'list'")) {
    return ok(
      '{"id":"1","result":{"workspaces":['
      '{"workspace_id":"wB","label":"Project B"}'
      ']}}',
    );
  }
  if (command.contains("'agent' 'get'")) {
    return ok(
      '{"id":"1","result":{"agent":{"agent":"claude",'
      '"agent_status":"blocked","cwd":"/tmp/proj","focused":false,'
      '"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
      '"name":"Agent Three"}}}',
    );
  }
  if (command.contains("'agent' 'read'")) {
    return ok(
      '{"id":"1","result":{"read":{"text":${_jsonEncode(_readText)}}}}',
    );
  }
  return ok('{"id":"1","result":{}}');
}

String _jsonEncode(String s) {
  final escaped = s
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n');
  return '"$escaped"';
}

void main() {
  testWidgets('shows prompt options and sends the chosen number', (
    tester,
  ) async {
    final runner = FakeCommandRunner(_respond);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.widgetWithText(FilledButton, '1. Yes'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '3. No'), findsOneWidget);
    expect(find.text('blocked · Project B'), findsOneWidget);
    expect(find.textContaining('p1'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, '1. Yes'));
    await tester.pump();
    await tester.pump();

    expect(
      runner.commands.any(
        (c) => c.contains("agent' 'send'") && c.contains("'1'"),
      ),
      isTrue,
    );
    expect(
      runner.commands.any(
        (c) => c.contains('send-keys') && c.contains("'enter'"),
      ),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('keeps the draft and shows an error when send fails', (
    tester,
  ) async {
    CommandResult respondFailingSend(String command) {
      if (command.contains("'agent' 'send'")) {
        return const CommandResult(exitCode: 1, stdout: '', stderr: 'boom');
      }
      return _respond(command);
    }

    final runner = FakeCommandRunner(respondFailingSend);
    final client = HerdrClient(runner);

    await tester.pumpWidget(
      MaterialApp(
        home: AgentScreen(
          client: client,
          paneId: 'wB:p1',
          pollInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'please continue');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump();

    expect(find.text('please continue'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
