import 'dart:convert';

import 'package:drover/src/demo/demo_backend.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:flutter_test/flutter_test.dart';

Future<String> _transcript(HerdrClient client) async =>
    utf8.decode(await client.runner.readFile(demoTranscriptPath));

void main() {
  test('opens blocked, with the permission prompt already on screen', () async {
    final client = DemoBackend().buildClient();

    final agents = await client.listAgents();
    expect(agents.single.status, AgentStatus.blocked);
    expect(agents.single.paneId, demoPaneId);

    final live = await client.readAgent(demoPaneId);
    expect(live, contains('Do you want to proceed?'));
  });

  test('answering the permission prompt advances the transcript and the '
      'status, landing a canned reply after a couple of ticks', () async {
    final client = DemoBackend().buildClient();
    final before = await _transcript(client);

    await client.prompt(demoPaneId, '1');

    // The answer itself is recorded immediately, before any working tick.
    final afterAnswer = await _transcript(client);
    expect(afterAnswer.length, greaterThan(before.length));
    expect(afterAnswer, contains('tool_result'));

    expect((await client.listAgents()).single.status, AgentStatus.working);
    await client.listAgents();
    expect((await client.listAgents()).single.status, AgentStatus.idle);

    final afterReply = await _transcript(client);
    expect(afterReply, contains('spike-test.txt'));
    expect(afterReply, contains('assistant'));
  });

  test(
    'a follow-up after the first reply lands a second reply and completes',
    () async {
      final backend = DemoBackend();
      final client = backend.buildClient();

      await client.prompt(demoPaneId, '1');
      await client.listAgents();
      await client.listAgents();
      expect((await client.listAgents()).single.status, AgentStatus.idle);
      expect(backend.isComplete, isFalse);

      await client.prompt(demoPaneId, 'Can you also add a README?');
      expect((await client.listAgents()).single.status, AgentStatus.working);
      await client.listAgents();
      expect((await client.listAgents()).single.status, AgentStatus.idle);

      expect(backend.isComplete, isTrue);
      final transcript = await _transcript(client);
      expect(transcript, contains('Can you also add a README?'));
    },
  );

  test('cycling the mode updates the live pane text', () async {
    final client = DemoBackend().buildClient();
    // Answer the initial prompt first: the mode line only appears once past
    // the blocked-prompt pane text.
    await client.prompt(demoPaneId, '1');

    final before = await client.readAgent(demoPaneId);
    expect(before, contains('auto mode on'));

    await client.sendPaneText(demoPaneId, '[Z');

    final after = await client.readAgent(demoPaneId);
    expect(after, contains('accept edits on'));
  });

  test('reports a supported herdr version', () async {
    final client = DemoBackend().buildClient();
    expect(await client.version(), contains('0.7.5'));
  });
}
