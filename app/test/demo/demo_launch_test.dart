import 'package:drover/l10n/app_localizations.dart';
import 'package:drover/src/demo/demo_backend.dart';
import 'package:drover/src/models/agent_preset.dart';
import 'package:drover/src/screens/launch_agent_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the demo host detects claude and codex', () async {
    final found = await DemoBackend().buildClient().detectAgents(kAgentPresets);
    expect(found.map((p) => p.bin), ['claude', 'codex']);
  });

  testWidgets('the launch sheet offers the demo agents and launches one', (
    tester,
  ) async {
    final client = DemoBackend().buildClient();
    String? popped;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                popped = await showModalBottomSheet<String>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) =>
                      LaunchAgentSheet(client: client, existingCwds: const []),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.textContaining('No launchable agents'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('cwd_field')),
      '/home/demo/app',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('launch_button')));
    await tester.pumpAndSettle();

    expect(popped, demoLaunchedPaneId);
  });

  test(
    'a prompt to the launched pane gets a canned reply only there',
    () async {
      final client = DemoBackend().buildClient();
      final scriptedBefore = await client.readAgent(demoPaneId);
      expect(await client.readAgent(demoLaunchedPaneId), isEmpty);

      await client.prompt(demoLaunchedPaneId, 'do the thing');

      expect(
        await client.readAgent(demoLaunchedPaneId),
        contains('launched on-device'),
      );
      expect(await client.readAgent(demoPaneId), scriptedBefore);
    },
  );
}
