import 'dart:convert';

import 'package:drover/src/demo/demo_backend.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/transcript/native_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

Future<String> _transcript(HerdrClient client) async =>
    utf8.decode(await client.runner.readFile(demoTranscriptPath));

/// The scripted agent, picked out of the herd by pane id — the two other demo
/// agents are static scenery and must never be what these assertions read.
Future<AgentInfo> _scripted(HerdrClient client) async =>
    (await client.listAgents()).firstWhere((a) => a.paneId == demoPaneId);

void main() {
  test('the demo session id is a real UUID, as every native-transcript '
      'loader requires', () {
    // Not cosmetic: `ClaudeTranscriptLoader.supportsAgent` gates on this, so a
    // non-conforming id means no adapter is created and the demo silently
    // renders no chat at all (see demo_screen_test.dart).
    final sessionId = demoTranscriptPath.split('/').last.split('.').first;
    expect(isNativeTranscriptSessionId(sessionId), isTrue, reason: sessionId);
  });

  test('opens blocked, with the permission prompt already on screen', () async {
    final client = DemoBackend().buildClient();

    expect((await _scripted(client)).status, AgentStatus.blocked);

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

    expect((await _scripted(client)).status, AgentStatus.working);
    await client.listAgents();
    expect((await _scripted(client)).status, AgentStatus.idle);

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
      expect((await _scripted(client)).status, AgentStatus.idle);
      expect(backend.isComplete, isFalse);

      await client.prompt(demoPaneId, 'Can you also add a README?');
      expect((await _scripted(client)).status, AgentStatus.working);
      await client.listAgents();
      expect((await _scripted(client)).status, AgentStatus.idle);

      expect(backend.isComplete, isTrue);
      final transcript = await _transcript(client);
      expect(transcript, contains('Can you also add a README?'));
    },
  );

  test(
    'a follow-up containing multiple single-quoted words round-trips intact',
    () async {
      // Regression: extracting the free-text argument used to scan for the
      // last `' '` (quote-space-quote) boundary anywhere in the command
      // line, which a message like this one also produces internally,
      // corrupting the extraction. See _promptText's doc comment.
      final client = DemoBackend().buildClient();
      const message = "please check 'a' 'b' first";

      await client.prompt(demoPaneId, '1');
      await client.listAgents();
      await client.listAgents();
      expect((await _scripted(client)).status, AgentStatus.idle);

      await client.prompt(demoPaneId, message);

      final transcript = await _transcript(client);
      expect(transcript, contains(message));
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

  test('the two non-interactive agents are inert: their own live text, and no '
      'effect on the script', () async {
    final backend = DemoBackend();
    final client = backend.buildClient();

    final agents = await client.listAgents();
    expect(agents.length, 3);
    expect(agents.map((a) => a.status).toSet(), {
      AgentStatus.blocked,
      AgentStatus.working,
      AgentStatus.idle,
    });

    // Neither shows the scripted pane's permission prompt...
    for (final paneId in [demoReviewPaneId, demoDocsPaneId]) {
      expect(
        await client.readAgent(paneId),
        isNot(contains('Do you want to proceed?')),
      );
      // ...nor can anything sent to them advance the scripted session.
      await client.prompt(paneId, '1');
      await client.sendPaneText(paneId, '[Z');
    }
    expect((await _scripted(client)).status, AgentStatus.blocked);
    expect(await client.readAgent(demoPaneId), contains('proceed?'));
  });

  test('reports a supported herdr version', () async {
    final client = DemoBackend().buildClient();
    expect(await client.version(), contains('0.8.0'));
  });
}
