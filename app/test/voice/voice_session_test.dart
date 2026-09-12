import 'dart:async';
import 'dart:typed_data';

import 'package:drover/src/voice/voice_herd.dart';
import 'package:drover/src/voice/voice_session.dart';
import 'package:drover/src/voice/voice_tools.dart';
import 'package:drover/src/voice/voice_transport.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late FakeTransport transport;
  late FakeMic mic;
  late FakeSpeaker speaker;
  var toolCalls = 0;
  // Injected clock so the mic gate can be tested without sleeping.
  var clock = DateTime(2026, 1, 1);

  // Recorded instead of waited: each call advances the fake clock by the
  // requested duration.
  final sleeps = <Duration>[];

  VoiceSession session({
    bool muteMicWhileSpeaking = true,
    Future<VoiceTransport> Function()? connect,
    FakeVoiceHerd? herd,
    VoiceInbox? inbox,
    Completer<void>? sleepGate,
  }) => VoiceSession(
    connect: connect ?? () async => transport,
    now: () => clock,
    sleep: (d) async {
      sleeps.add(d);
      clock = clock.add(d);
      await sleepGate?.future;
    },
    mic: mic,
    speaker: speaker,
    herd: herd,
    inbox: inbox,
    tools: [
      VoiceTool(
        name: 'list_agents',
        description: '',
        parameters: const {},
        run: (_) async {
          toolCalls++;
          return {'agents': []};
        },
      ),
    ],
    muteMicWhileSpeaking: muteMicWhileSpeaking,
  );

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<void> sendMicFrame() async {
    mic.frames.add(Uint8List.fromList([1]));
    await settle();
  }

  setUp(() {
    transport = FakeTransport();
    mic = FakeMic();
    speaker = FakeSpeaker();
    toolCalls = 0;
    clock = DateTime(2026, 1, 1);
    sleeps.clear();
  });

  test('start goes live, inits the speaker and forwards mic audio', () async {
    final s = session(muteMicWhileSpeaking: false);
    await s.start();

    expect(s.status, VoiceSessionStatus.live);
    expect(speaker.initCalls, 1);
    mic.frames.add(Uint8List.fromList([9]));
    await settle();
    expect(transport.sentAudio, hasLength(1));
  });

  test('denied mic permission ends in error without connecting', () async {
    mic = FakeMic(permitted: false);
    final s = session();
    await s.start();

    expect(s.status, VoiceSessionStatus.error);
    expect(s.error, VoiceSession.micPermissionDenied);
    expect(speaker.initCalls, 0);
  });

  test('a tool call is answered with the same id and logged', () async {
    final s = session();
    await s.start();

    transport.push(
      LiveServerToolCall(
        functionCalls: const [FunctionCall('list_agents', {}, id: 'call-1')],
      ),
    );
    await settle();

    expect(toolCalls, 1);
    expect(transport.toolResponses.single.single.id, 'call-1');
    expect(transport.toolResponses.single.single.name, 'list_agents');
    expect(s.entries.map((e) => e.kind), [VoiceEntryKind.tool]);
    expect(s.entries.single.text, 'list_agents');
  });

  test('a tool call flushes the pending user transcription first', () async {
    final s = session();
    await s.start();

    transport.push(
      LiveServerContent(
        inputTranscription: Transcription(text: 'which agent', finished: false),
      ),
    );
    transport.push(
      LiveServerToolCall(
        functionCalls: const [FunctionCall('list_agents', {}, id: 'call-2')],
      ),
    );
    await settle();

    expect(s.entries.map((e) => e.kind), [
      VoiceEntryKind.user,
      VoiceEntryKind.tool,
    ]);
    expect(s.entries.first.text, 'which agent');
    expect(s.partialUser, isNull);
  });

  test('transcription chunks flush on turnComplete, user first', () async {
    final s = session();
    await s.start();

    transport.push(
      LiveServerContent(
        outputTranscription: const Transcription(text: 'Two agents'),
      ),
    );
    transport.push(
      LiveServerContent(
        inputTranscription: const Transcription(text: 'status?'),
      ),
    );
    await settle();
    expect(s.partialAssistant, 'Two agents');
    expect(s.partialUser, 'status?');
    expect(s.entries, isEmpty);

    transport.push(
      LiveServerContent(
        outputTranscription: const Transcription(text: ', one blocked.'),
        turnComplete: true,
      ),
    );
    await settle();

    expect(s.partialAssistant, isNull);
    expect(s.partialUser, isNull);
    expect(s.entries.map((e) => (e.kind, e.text)), [
      (VoiceEntryKind.user, 'status?'),
      (VoiceEntryKind.assistant, 'Two agents, one blocked.'),
    ]);
  });

  test(
    'a finished transcription flushes without waiting for the turn',
    () async {
      final s = session();
      await s.start();

      transport.push(
        LiveServerContent(
          inputTranscription: const Transcription(text: 'hi', finished: true),
        ),
      );
      await settle();

      expect(s.partialUser, isNull);
      expect(s.entries.single.text, 'hi');
    },
  );

  test('audio chunks play; interrupted stops the speaker once', () async {
    final s = session();
    await s.start();

    transport.push(audioChunk());
    transport.push(LiveServerContent(interrupted: true));
    await settle();

    expect(speaker.played, hasLength(1));
    expect(speaker.interruptCalls, 1);
    expect(s.entries.single.text, VoiceSession.interruptedCode);
  });

  test(
    'the gate mutes the mic for the estimated playback plus the tail',
    () async {
      final s = session();
      await s.start();

      // 48000 bytes = one second of 24 kHz PCM16 mono.
      transport.push(audioChunk(bytes: 48000));
      await settle();

      clock = clock.add(const Duration(seconds: 1));
      await sendMicFrame();
      expect(transport.sentAudio, isEmpty, reason: 'still playing');

      clock = clock.add(const Duration(milliseconds: 1400));
      await sendMicFrame();
      expect(transport.sentAudio, isEmpty, reason: 'inside the 1.5 s tail');

      clock = clock.add(const Duration(milliseconds: 200));
      await sendMicFrame();
      expect(transport.sentAudio, hasLength(1), reason: 'playback + tail over');
    },
  );

  test(
    'interrupted cuts the playback estimate; only the tail remains',
    () async {
      final s = session();
      await s.start();

      transport.push(audioChunk(bytes: 48000 * 10));
      await settle();
      clock = clock.add(const Duration(seconds: 1));
      transport.push(LiveServerContent(interrupted: true));
      await settle();

      clock = clock.add(const Duration(milliseconds: 1400));
      await sendMicFrame();
      expect(transport.sentAudio, isEmpty, reason: 'inside the tail');

      clock = clock.add(const Duration(milliseconds: 200));
      await sendMicFrame();
      expect(transport.sentAudio, hasLength(1));
    },
  );

  test('turnComplete alone does not gate the mic', () async {
    final s = session();
    await s.start();

    transport.push(LiveServerContent(turnComplete: true));
    await settle();
    await sendMicFrame();

    expect(transport.sentAudio, hasLength(1));
  });

  test(
    'mic frames are forwarded while the model speaks when ungated',
    () async {
      final s = session(muteMicWhileSpeaking: false);
      await s.start();

      transport.push(audioChunk(bytes: 48000));
      await settle();
      await sendMicFrame();

      expect(transport.sentAudio, hasLength(1));
    },
  );

  test('an audio-only chunk does not notify listeners', () async {
    final s = session();
    await s.start();
    var notifications = 0;
    s.addListener(() => notifications++);

    transport.push(audioChunk());
    await settle();
    expect(speaker.played, hasLength(1));
    expect(notifications, 0);

    transport.push(
      LiveServerContent(outputTranscription: const Transcription(text: 'hi')),
    );
    await settle();
    expect(notifications, 1);
  });

  test('messages are handled in order: audio waits for interrupt', () async {
    final gate = Completer<void>();
    speaker = FakeSpeaker(interruptGate: gate);
    final s = session();
    await s.start();

    transport.push(LiveServerContent(interrupted: true));
    transport.push(audioChunk());
    await settle();
    expect(speaker.interruptCalls, 1);
    expect(speaker.played, isEmpty);

    gate.complete();
    await settle();
    expect(speaker.played, hasLength(1));
  });

  test('a throwing message handler fails the session', () async {
    speaker = FakeSpeaker(interruptError: StateError('device gone'));
    final s = session();
    await s.start();

    transport.push(LiveServerContent(interrupted: true));
    await settle();

    expect(s.status, VoiceSessionStatus.error);
    expect(s.error, contains('device gone'));
    expect(mic.stopCalls, 1);
  });

  test('going away is logged', () async {
    final s = session();
    await s.start();

    transport.push(const GoingAwayNotice(timeLeft: '10s'));
    await settle();

    expect(s.entries.single.text, VoiceSession.goingAwayCode);
  });

  test('server stream done ends the session and stops the mic', () async {
    final s = session();
    await s.start();

    await transport.server.close();
    await settle();

    expect(s.status, VoiceSessionStatus.ended);
    expect(mic.stopCalls, 1);
    expect(speaker.disposeCalls, 1);
    expect(s.entries.last.text, VoiceSession.endedCode);
  });

  test('a stream error ends in error status', () async {
    final s = session();
    await s.start();

    transport.server.addError(StateError('socket'));
    await settle();

    expect(s.status, VoiceSessionStatus.error);
    expect(s.error, contains('socket'));
    expect(mic.stopCalls, 1);
  });

  test('error status is reported only after teardown finished', () async {
    final gate = Completer<void>();
    speaker = FakeSpeaker(disposeGate: gate);
    final s = session();
    await s.start();

    transport.server.addError(StateError('socket'));
    await settle();
    expect(mic.stopCalls, 1);
    expect(s.status, VoiceSessionStatus.live, reason: 'speaker still busy');

    gate.complete();
    await settle();
    expect(s.status, VoiceSessionStatus.error);
  });

  test('stop during connecting wins over the pending start', () async {
    final connecting = Completer<VoiceTransport>();
    final s = session(connect: () => connecting.future);

    final starting = s.start();
    await settle();
    expect(s.status, VoiceSessionStatus.connecting);
    await s.stop();
    expect(s.status, VoiceSessionStatus.ended);

    connecting.complete(transport);
    await starting;
    await settle();

    expect(transport.closeCalls, 1);
    expect(s.status, VoiceSessionStatus.ended);
    expect(mic.startCalls, 0);
    // The late transport was closed unread: nothing ever subscribed to it.
    expect(transport.server.hasListener, isFalse);
    expect(speaker.played, isEmpty);
  });

  test('stop twice is safe and idempotent', () async {
    final s = session();
    await s.start();

    await s.stop();
    await s.stop();

    expect(s.status, VoiceSessionStatus.ended);
    expect(transport.closeCalls, 1);
    expect(mic.stopCalls, 1);
    expect(
      s.entries.where((e) => e.text == VoiceSession.endedCode),
      hasLength(1),
    );
  });

  test('start after stop reconnects and keeps the log', () async {
    final s = session();
    await s.start();
    await s.stop();

    transport = FakeTransport();
    await s.start();

    expect(s.status, VoiceSessionStatus.live);
    expect(speaker.initCalls, 2);
    expect(s.entries.single.text, VoiceSession.endedCode);
  });

  test('sends after the session ended are ignored', () async {
    final s = session(muteMicWhileSpeaking: false);
    await s.start();
    await s.stop();

    mic.frames.add(Uint8List.fromList([1]));
    await settle();

    expect(transport.sentAudio, isEmpty);
  });

  group('callbacks', () {
    late FakeVoiceHerd herd;
    late VoiceInbox inbox;
    final claude = fakeAgent(paneId: 'p1', title: 'Implement OAuth');
    final codex = fakeAgent(paneId: 'p2', kind: 'codex', name: 'Reviewer');

    setUp(() {
      herd = FakeVoiceHerd(agents: [claude, codex])
        ..replies['p1'] = 'All green.';
      inbox = VoiceInbox();
    });

    tearDown(() => inbox.dispose());

    test('pending events are announced as one text after going live', () async {
      inbox.add(AgentEvent(AgentEventKind.finished, claude));
      inbox.add(AgentEvent(AgentEventKind.blocked, codex));
      final s = session(herd: herd, inbox: inbox);

      await s.start();
      await settle();

      expect(inbox.pending, isEmpty);
      expect(transport.sentText, hasLength(1));
      expect(transport.sentText.single, startsWith('[event] Agent "Implement'));
      expect(
        transport.sentText.single,
        contains('\n\n[event] Agent "Reviewer"'),
      );
      expect(s.entries.map((e) => (e.kind, e.text)), [
        (VoiceEntryKind.event, 'finished:Implement OAuth'),
        (VoiceEntryKind.event, 'blocked:Reviewer'),
      ]);
      expect(s.status, VoiceSessionStatus.live);
    });

    test('an event added while live is announced once and drained', () async {
      final s = session(herd: herd, inbox: inbox);
      await s.start();
      expect(transport.sentText, isEmpty);

      inbox.add(AgentEvent(AgentEventKind.finished, claude));
      await settle();

      expect(inbox.pending, isEmpty);
      expect(transport.sentText, hasLength(1));
      expect(transport.sentText.single, contains('Last reply: "All green."'));
      expect(s.entries.single.text, 'finished:Implement OAuth');
    });

    test('a failed read logs announce_failed and keeps the session', () async {
      herd.readError = StateError('ssh down');
      final s = session(herd: herd, inbox: inbox);
      await s.start();

      inbox.add(AgentEvent(AgentEventKind.finished, claude));
      await settle();

      expect(transport.sentText, isEmpty);
      expect(s.entries.single.kind, VoiceEntryKind.system);
      expect(s.entries.single.text, VoiceSession.announceFailedCode);
      expect(s.status, VoiceSessionStatus.live);
    });

    test('an announcement waits for playback plus the tail', () async {
      final s = session(herd: herd, inbox: inbox);
      await s.start();
      // 96000 bytes = two seconds of 24 kHz PCM16 mono.
      transport.push(audioChunk(bytes: 96000));
      await settle();

      inbox.add(AgentEvent(AgentEventKind.finished, claude));
      await settle();

      expect(transport.sentText, hasLength(1));
      expect(s.entries.single.text, 'finished:Implement OAuth');
      // Slept in 200 ms steps until 2 s + 1.5 s had elapsed, no further.
      expect(sleeps, isNotEmpty);
      expect(
        sleeps.every((d) => d == const Duration(milliseconds: 200)),
        isTrue,
      );
      expect(
        sleeps.fold(Duration.zero, (a, d) => a + d),
        const Duration(milliseconds: 3600),
      );
    });

    test('an announcement with no recent audio is sent at once', () async {
      final s = session(herd: herd, inbox: inbox);
      await s.start();

      inbox.add(AgentEvent(AgentEventKind.finished, claude));
      await settle();

      expect(transport.sentText, hasLength(1));
      expect(sleeps, isEmpty);
    });

    test('the playback wait is bounded to 20 s', () async {
      final s = session(herd: herd, inbox: inbox);
      await s.start();
      transport.push(audioChunk(bytes: 48000 * 60));
      await settle();

      // The sleep advances the clock, but the estimate is a minute out, so
      // only the bound ends the wait.
      inbox.add(AgentEvent(AgentEventKind.finished, claude));
      await settle();

      expect(transport.sentText, hasLength(1));
      expect(
        sleeps.fold(Duration.zero, (a, d) => a + d),
        const Duration(seconds: 20),
      );
      expect(s.status, VoiceSessionStatus.live);
    });

    test('stopping during the playback wait drops the announcement', () async {
      final gate = Completer<void>();
      final s = session(herd: herd, inbox: inbox, sleepGate: gate);
      await s.start();
      transport.push(audioChunk(bytes: 96000));
      await settle();

      inbox.add(AgentEvent(AgentEventKind.finished, claude));
      await settle();
      expect(sleeps, hasLength(1), reason: 'parked in the first sleep');
      expect(transport.sentText, isEmpty);

      await s.stop();
      gate.complete();
      await settle();

      expect(transport.sentText, isEmpty);
      expect(s.status, VoiceSessionStatus.ended);
    });

    test('events after stop are not sent', () async {
      final s = session(herd: herd, inbox: inbox);
      await s.start();
      await s.stop();

      inbox.add(AgentEvent(AgentEventKind.finished, claude));
      await settle();

      expect(transport.sentText, isEmpty);
      expect(inbox.pending, hasLength(1), reason: 'kept for the next session');
    });
  });
}
