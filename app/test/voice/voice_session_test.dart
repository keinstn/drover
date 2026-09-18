import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drover/src/voice/voice_drafts.dart';
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

  // The usage readout every session below ends on: a fake transport reports
  // no usage, and the injected clock does not move.
  const noUsage = 'usage · 0m 0s · no usage reported';

  // Recorded instead of waited: each call advances the fake clock by the
  // requested duration.
  final sleeps = <Duration>[];

  VoiceSession session({
    bool muteMicWhileSpeaking = true,
    Duration aecWarmUp = Duration.zero,
    Future<VoiceTransport> Function(String?)? connect,
    FakeVoiceHerd? herd,
    VoiceInbox? inbox,
    VoiceDrafts? drafts,
    Completer<void>? sleepGate,
  }) => VoiceSession(
    connect: connect ?? (_) async => transport,
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
    drafts: drafts,
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
      // The real draft/send pair, so tool calls drive the drafts box.
      if (herd != null && drafts != null)
        ...droverVoiceTools(
          herd,
          drafts,
        ).where((t) => t.name == 'draft_message' || t.name == 'send_message'),
    ],
    muteMicWhileSpeaking: muteMicWhileSpeaking,
    aecWarmUp: aecWarmUp,
  );

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// Moves both clocks: the cap timer runs on FakeAsync, the deadline it is
  /// armed from is read off the injected [clock], and a test that advanced
  /// only one of them would measure nothing.
  Future<void> advance(WidgetTester tester, Duration d) async {
    clock = clock.add(d);
    await tester.pump(d);
  }

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

  test('a call that ends in error still reports what it billed for', () async {
    mic = FakeMic(permitted: false);
    final s = session();
    await s.start();

    // Whatever killed the call, what it spent before that is still spent, and
    // a measurement that drops the calls that went wrong measures the wrong
    // population.
    expect(s.status, VoiceSessionStatus.error);
    expect(
      s.entries.where((e) => e.kind == VoiceEntryKind.system).last.text,
      startsWith('usage · '),
    );
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

  test('the gate defaults to on, so a caller that omits it stays safe', () {
    final s = VoiceSession(
      connect: (_) async => transport,
      mic: mic,
      speaker: speaker,
      tools: const [],
    );
    // Production overrides it per build mode (voiceMicGateNeeded); what
    // matters here is that omitting it cannot silently drop the gate.
    expect(s.muteMicWhileSpeaking, isTrue);
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

  group('AEC warm-up gate', () {
    // 48000 bytes = one second of 24 kHz PCM16 mono.
    Future<void> playSecond(FakeTransport t) async {
      t.push(audioChunk(bytes: 48000));
      await settle();
    }

    /// Moves past the playback estimate of one second plus the 1.5 s tail.
    void skipPlayback() => clock = clock.add(const Duration(seconds: 3));

    test('gates while the model is speaking until the threshold', () async {
      final s = session(
        muteMicWhileSpeaking: false,
        aecWarmUp: const Duration(seconds: 2),
      );
      await s.start();

      await playSecond(transport);
      await sendMicFrame();
      expect(transport.sentAudio, isEmpty, reason: 'warming up, 1 s of 2 s');

      skipPlayback();
      await sendMicFrame();
      expect(transport.sentAudio, hasLength(1), reason: 'nothing playing');

      await playSecond(transport);
      await sendMicFrame();
      expect(transport.sentAudio, hasLength(2), reason: 'warmed up at 2 s');
    });

    test('a restart re-arms it: the canceller starts cold again', () async {
      // A fresh transport per connect: FakeTransport.close() closes its
      // stream, so a restart on the same one would just end the session.
      final connector = FakeConnector();
      final s = session(
        muteMicWhileSpeaking: false,
        aecWarmUp: const Duration(seconds: 2),
        connect: connector.call,
      );
      await s.start();
      await playSecond(connector.last);
      await playSecond(connector.last);
      await s.stop();

      await s.start();
      await playSecond(connector.last);
      await sendMicFrame();

      expect(connector.transports.last.sentAudio, isEmpty);
    });

    test('a resume keeps it: the mic never stopped', () async {
      final connector = FakeConnector();
      final s = session(
        muteMicWhileSpeaking: false,
        aecWarmUp: const Duration(seconds: 2),
        connect: connector.call,
      );
      await s.start();
      await playSecond(connector.last);
      await playSecond(connector.last);
      connector.last.pushResumption('h1');
      await settle();
      await connector.transports.first.server.close();
      await settle();

      await playSecond(connector.last);
      await sendMicFrame();

      expect(connector.transports.last.sentAudio, hasLength(1));
    });
  });

  test(
    'audio chunks notify once, when speaking begins, not per chunk',
    () async {
      final s = session();
      await s.start();
      var notifications = 0;
      s.addListener(() => notifications++);

      // Seconds of audio: a real timer fires at the estimated end, and a
      // tiny chunk would already be over by the next line.
      transport.push(audioChunk(bytes: 48000));
      transport.push(audioChunk(bytes: 48000));
      await settle();
      expect(speaker.played, hasLength(2));
      expect(notifications, 1);

      transport.push(
        LiveServerContent(outputTranscription: const Transcription(text: 'hi')),
      );
      await settle();
      expect(notifications, 2);
    },
  );

  // testWidgets for the FakeAsync zone: the playback timer is a real Timer.
  testWidgets('speaking follows the playback estimate, and its end notifies', (
    tester,
  ) async {
    final s = session();
    await s.start();
    var notifications = 0;
    s.addListener(() => notifications++);

    // One second of audio; the transcript plays no part.
    transport.push(audioChunk(bytes: 48000));
    await tester.pump();
    expect(s.speaking, isTrue);
    expect(notifications, 1);

    clock = clock.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(notifications, 2, reason: 'the timer reported the end');
    expect(s.speaking, isFalse);

    // Re-armed by the next chunk; stop() must leave no timer pending (the
    // framework fails the test on a leaked one).
    transport.push(audioChunk(bytes: 48000));
    await tester.pump();
    expect(s.speaking, isTrue);
    await s.stop();
    expect(s.speaking, isFalse);
  });

  group('level', () {
    // RMS 0.1 of full scale x kVoiceLevelGain -> a 0.6 target.
    final loud = pcm16Frame(0.1);
    final silent = pcm16Frame(0);

    Future<void> pushMic(Uint8List frame, int times) async {
      for (var i = 0; i < times; i++) {
        mic.frames.add(frame);
        await settle();
      }
    }

    test('loud mic frames raise it, silence brings it back down', () async {
      final s = session(muteMicWhileSpeaking: false);
      await s.start();

      await pushMic(loud, 5);
      final peak = s.level.value;
      expect(peak, greaterThan(0.3));

      await pushMic(silent, 30);
      expect(s.level.value, lessThan(peak));
      expect(s.level.value, lessThan(0.05));
    });

    test('while speaking the speaker drives it, not the mic', () async {
      // Ungated, so the mic path really is live during playback.
      final s = session(muteMicWhileSpeaking: false);
      await s.start();

      transport.push(audioChunk(bytes: 48000));
      await settle();
      expect(s.speaking, isTrue);

      for (var i = 0; i < 10; i++) {
        speaker.levels.add(0.8);
        await settle();
      }
      final fromSpeaker = s.level.value;
      expect(fromSpeaker, greaterThan(0.6));

      // Silence on the mic would drag it down if the mic path won.
      await pushMic(silent, 5);
      expect(s.level.value, fromSpeaker);

      await s.stop();
    });

    test('a mic frame while the model speaks does not raise it', () async {
      final s = session();
      await s.start();

      transport.push(audioChunk(bytes: 48000));
      await settle();

      await pushMic(loud, 5);
      expect(s.level.value, 0);

      await s.stop();
    });

    test('stop() zeroes it', () async {
      final s = session(muteMicWhileSpeaking: false);
      await s.start();

      await pushMic(loud, 5);
      expect(s.level.value, greaterThan(0));

      await s.stop();
      expect(s.level.value, 0);
    });

    // testWidgets for the FakeAsync zone: the playback timer is a real Timer.
    testWidgets('the playback timer zeroes it', (tester) async {
      final s = session(muteMicWhileSpeaking: false);
      await s.start();

      transport.push(audioChunk(bytes: 48000));
      await tester.pump();
      speaker.levels.add(0.9);
      await tester.pump();
      expect(s.level.value, greaterThan(0));

      clock = clock.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      expect(s.level.value, 0, reason: 'frozen otherwise for the mute tail');

      // Re-armed by the next chunk: stop() must zero it with a timer pending.
      transport.push(audioChunk(bytes: 48000));
      await tester.pump();
      speaker.levels.add(0.9);
      await tester.pump();
      expect(s.level.value, greaterThan(0));

      await s.stop();
      expect(s.level.value, 0);
    });

    testWidgets("a barge-in disarms the dropped turn's timer", (tester) async {
      final s = session(muteMicWhileSpeaking: false);
      await s.start();

      // Eight seconds of audio arrive at once, as Gemini streams them.
      transport.push(audioChunk(bytes: 48000 * 8));
      await tester.pump();
      expect(s.speaking, isTrue);

      // The user barges in half a second in.
      clock = clock.add(const Duration(milliseconds: 500));
      transport.push(LiveServerContent(interrupted: true));
      await tester.pump();
      expect(s.speaking, isFalse);

      for (var i = 0; i < 5; i++) {
        mic.frames.add(loud);
        await tester.pump();
      }
      expect(s.level.value, greaterThan(0.3));

      // Past the end the dropped turn would have had.
      clock = clock.add(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 10));
      expect(
        s.level.value,
        greaterThan(0.3),
        reason: 'a stale timer slammed the orb to rest mid-sentence',
      );

      await s.stop();
    });

    test('a mic frame in the mute tail raises it but is not sent', () async {
      final s = session();
      await s.start();

      transport.push(audioChunk(bytes: 48000));
      await settle();

      // The audio has finished, the AEC tail has not: the user is replying.
      clock = clock.add(const Duration(milliseconds: 1200));
      expect(s.speaking, isFalse);

      await pushMic(loud, 5);
      expect(s.level.value, greaterThan(0.3));
      expect(transport.sentAudio, isEmpty, reason: 'the gate still drops it');

      await s.stop();
    });

    test('after a stop/start the speaker still drives it', () async {
      // A fresh transport per connect, as FakeTransport.close() closes its
      // stream; the speaker is the same one, disposed and re-inited.
      final connector = FakeConnector();
      final s = session(muteMicWhileSpeaking: false, connect: connector.call);
      await s.start();
      await s.stop();
      await s.start();

      connector.last.push(audioChunk(bytes: 48000));
      await settle();
      expect(s.speaking, isTrue);

      for (var i = 0; i < 10; i++) {
        speaker.levels.add(0.8);
        await settle();
      }
      expect(s.level.value, greaterThan(0.6));

      await s.stop();
    });
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
    expect(
      s.entries.map((e) => e.text),
      containsAllInOrder([VoiceSession.endedCode, noUsage]),
    );
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
    final s = session(connect: (_) => connecting.future);

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
    expect(s.entries.map((e) => e.text), [VoiceSession.endedCode, noUsage]);
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

  group('resumption', () {
    final claude = fakeAgent(paneId: 'p1', title: 'Implement OAuth');

    /// A connect that hands out [transport] first and parks every later one
    /// on [gate], so a reconnect can be observed mid-flight.
    Future<VoiceTransport> Function(String?) gatedConnect(
      Completer<VoiceTransport> gate,
    ) {
      var calls = 0;
      return (_) => ++calls == 1 ? Future.value(transport) : gate.future;
    }

    Future<void> dropAfterHandle(VoiceSession s, {String handle = 'h1'}) async {
      transport.pushResumption(handle);
      await settle();
      await transport.server.close();
      await settle();
    }

    test('a dropped connection is resumed on the stored handle', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      connector.last.pushResumption('h1');
      await settle();

      await connector.transports.first.server.close();
      await settle();

      expect(connector.handles, [null, 'h1']);
      expect(s.status, VoiceSessionStatus.live);
      expect(s.entries.map((e) => e.text), [VoiceSession.resumedCode]);
      // The audio path is never torn down across a resume.
      expect(mic.stopCalls, 0);
      expect(mic.startCalls, 1);
      expect(speaker.initCalls, 1);
      expect(speaker.disposeCalls, 0);
    });

    test('mic audio goes to the resumed transport', () async {
      final connector = FakeConnector();
      final s = session(muteMicWhileSpeaking: false, connect: connector.call);
      await s.start();
      connector.last.pushResumption('h1');
      await settle();
      await connector.transports.first.server.close();
      await settle();

      await sendMicFrame();

      expect(connector.transports.first.sentAudio, isEmpty);
      expect(connector.transports.last.sentAudio, hasLength(1));
    });

    test('an error followed by the close resumes only once', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      connector.last.pushResumption('h1');
      await settle();

      connector.transports.first.server.addError(StateError('socket'));
      await connector.transports.first.server.close();
      await settle();

      expect(connector.handles, [null, 'h1']);
      expect(s.status, VoiceSessionStatus.live);
      expect(s.entries.map((e) => e.text), [VoiceSession.resumedCode]);
    });

    test('a refused handle fails the session and starts fresh next', () async {
      final connector = FakeConnector()..throwAt.add(1);
      final s = session(connect: connector.call);
      await s.start();
      connector.last.pushResumption('h1');
      await settle();
      await connector.transports.first.server.close();
      await settle();

      expect(s.status, VoiceSessionStatus.error);
      expect(s.error, contains('handle refused'));
      expect(mic.stopCalls, 1);

      await s.start();

      expect(connector.handles, [null, 'h1', null]);
      expect(s.status, VoiceSessionStatus.live);
    });

    test('an event during the resume is announced on the new wire', () async {
      final herd = FakeVoiceHerd(agents: [claude])
        ..replies['p1'] = 'All green.';
      final inbox = VoiceInbox();
      addTearDown(inbox.dispose);
      final gate = Completer<VoiceTransport>();
      final resumed = FakeTransport();
      final s = session(herd: herd, inbox: inbox, connect: gatedConnect(gate));
      await s.start();
      await dropAfterHandle(s);
      expect(s.status, VoiceSessionStatus.connecting);

      inbox.add(AgentEvent(AgentEventKind.finished, claude));
      await settle();
      expect(
        inbox.pending,
        hasLength(1),
        reason: 'held until the resume lands',
      );

      gate.complete(resumed);
      await settle();

      expect(s.status, VoiceSessionStatus.live);
      expect(inbox.pending, isEmpty);
      expect(transport.sentText, isEmpty);
      expect(resumed.sentText, hasLength(1));
      expect(resumed.sentText.single, contains('Last reply: "All green."'));
      expect(s.entries.map((e) => e.text), [
        VoiceSession.resumedCode,
        'finished:Implement OAuth',
      ]);
    });

    test('stop during the resume wins over it', () async {
      final gate = Completer<VoiceTransport>();
      final resumed = FakeTransport();
      final s = session(connect: gatedConnect(gate));
      await s.start();
      await dropAfterHandle(s);
      expect(s.status, VoiceSessionStatus.connecting);

      await s.stop();
      expect(s.status, VoiceSessionStatus.ended);

      gate.complete(resumed);
      await settle();

      expect(s.status, VoiceSessionStatus.ended);
      expect(s.entries.map((e) => e.text), [VoiceSession.endedCode, noUsage]);
      expect(resumed.closeCalls, 1);
      expect(resumed.server.hasListener, isFalse);
      expect(mic.stopCalls, 1);
    });

    test('the handle is consumed: a second drop needs a fresh one', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      connector.last.pushResumption('h1');
      await settle();
      await connector.transports.first.server.close();
      await settle();
      expect(s.status, VoiceSessionStatus.live);

      // The resumed connection drops before offering a handle of its own.
      await connector.transports.last.server.close();
      await settle();

      expect(connector.handles, [null, 'h1'], reason: 'no reconnect loop');
      expect(s.status, VoiceSessionStatus.ended);
      expect(s.entries.map((e) => e.text), [
        VoiceSession.resumedCode,
        VoiceSession.endedCode,
        noUsage,
      ]);
    });

    test('a fresh handle on the resumed wire resumes again', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      connector.last.pushResumption('h1');
      await settle();
      await connector.transports.first.server.close();
      await settle();

      connector.last.pushResumption('h2');
      await settle();
      await connector.transports[1].server.close();
      await settle();

      expect(connector.handles, [null, 'h1', 'h2']);
      expect(s.status, VoiceSessionStatus.live);
    });

    test('a non-resumable update leaves the handle unset', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      connector.last.pushResumption('h1', resumable: false);
      await settle();

      await connector.transports.first.server.close();
      await settle();

      expect(connector.handles, [null]);
      expect(s.status, VoiceSessionStatus.ended);
    });
  });

  group('drafts', () {
    late FakeVoiceHerd herd;
    late VoiceDrafts drafts;
    final claude = fakeAgent(paneId: 'p1', title: 'Implement OAuth');

    setUp(() {
      herd = FakeVoiceHerd(agents: [claude]);
      drafts = VoiceDrafts();
    });

    Future<void> draftViaTool() async {
      transport.push(
        LiveServerToolCall(
          functionCalls: const [
            FunctionCall('draft_message', {
              'agent': 'claude',
              'message': 'add tests too',
            }, id: 'c1'),
          ],
        ),
      );
      await settle();
    }

    test(
      'draft_message logs a draft entry; send_message a sent entry',
      () async {
        final s = session(herd: herd, inbox: VoiceInbox(), drafts: drafts);
        await s.start();

        await draftViaTool();
        expect(s.entries.map((e) => (e.kind, e.text)), [
          (VoiceEntryKind.tool, 'draft_message'),
          (VoiceEntryKind.draft, 'd1'),
        ]);
        expect(herd.sent, isEmpty);

        transport.push(
          LiveServerToolCall(
            functionCalls: const [
              FunctionCall('send_message', {'draft_id': 'd1'}, id: 'c2'),
            ],
          ),
        );
        await settle();

        expect(s.entries.skip(2).map((e) => (e.kind, e.text)), [
          (VoiceEntryKind.tool, 'send_message'),
          (VoiceEntryKind.sent, 'd1'),
        ]);
        expect(herd.sent.single.$2, 'add tests too');
        expect(transport.toolResponses.last.single.response['sent'], isTrue);
      },
    );

    test('stopping with a pending draft logs unsent_drafts once', () async {
      final s = session(herd: herd, inbox: VoiceInbox(), drafts: drafts);
      await s.start();
      await draftViaTool();

      await s.stop();
      await s.stop();

      expect(s.entries.map((e) => e.text).skip(2), [
        VoiceSession.endedCode,
        VoiceSession.unsentDraftsCode,
        noUsage,
      ]);
    });

    test('sendDraft sends via the herd and marks the draft sent', () async {
      final s = session(herd: herd, inbox: VoiceInbox(), drafts: drafts);
      await s.start();
      await draftViaTool();
      await s.stop();

      await s.sendDraft('d1');
      await s.sendDraft('d1');

      expect(herd.sent.single.$1.paneId, 'p1');
      expect(herd.sent.single.$2, 'add tests too');
      expect(drafts.pending, isEmpty);
      expect(
        s.entries.last,
        isA<VoiceEntry>().having((e) => e.kind, 'kind', VoiceEntryKind.sent),
      );
      expect(
        s.entries.where((e) => e.kind == VoiceEntryKind.sent),
        hasLength(1),
      );
    });

    test(
      'launchDraft launches via the herd and marks the draft done',
      () async {
        final s = session(herd: herd, inbox: VoiceInbox(), drafts: drafts);
        await s.start();
        drafts.addLaunch(kind: 'codex', cwd: '/tmp/proj', brief: 'add retries');
        await s.stop();

        await s.launchDraft('d1');
        await s.launchDraft('d1');

        expect(herd.launched.single, ('codex', '/tmp/proj', 'add retries'));
        expect(drafts.pending, isEmpty);
        expect(
          s.entries.where((e) => e.kind == VoiceEntryKind.sent).single.text,
          'd1',
        );
      },
    );

    test(
      'a failed launchDraft logs launch_failed and keeps the draft',
      () async {
        final s = session(herd: herd, inbox: VoiceInbox(), drafts: drafts);
        await s.start();
        drafts.addLaunch(kind: 'codex', cwd: '/tmp/proj', brief: 'add retries');
        herd.launchError = StateError('ssh down');

        await s.launchDraft('d1');

        expect(drafts.pending, hasLength(1));
        expect(s.entries.last.kind, VoiceEntryKind.system);
        expect(s.entries.last.text, VoiceSession.launchFailedCode);
        expect(s.status, VoiceSessionStatus.live);
        // Released again, so the card's button still works.
        expect(drafts.isBusy(drafts.byId('d1')!), isFalse);
      },
    );

    test('launchDraft is a no-op while a launch is in flight', () async {
      final s = session(herd: herd, inbox: VoiceInbox(), drafts: drafts);
      await s.start();
      drafts.addLaunch(kind: 'codex', cwd: '/tmp/proj', brief: 'add retries');
      herd.launchGate = Completer<void>();
      final first = s.launchDraft('d1');
      await pumpEventQueue();

      await s.launchDraft('d1');

      expect(herd.launched, hasLength(1));
      herd.launchGate!.complete();
      await first;
      expect(drafts.pending, isEmpty);
      expect(drafts.isBusy(drafts.byId('d1')!), isFalse);
    });

    test('sendDraft ignores a launch draft id', () async {
      final s = session(herd: herd, inbox: VoiceInbox(), drafts: drafts);
      await s.start();
      drafts.addLaunch(kind: 'codex', cwd: '/tmp/proj', brief: 'add retries');

      await s.sendDraft('d1');

      expect(herd.sent, isEmpty);
      expect(drafts.pending, hasLength(1));
    });

    test('a failed sendDraft logs send_failed and keeps the draft', () async {
      final s = session(herd: herd, inbox: VoiceInbox(), drafts: drafts);
      await s.start();
      await draftViaTool();
      herd.sendError = StateError('ssh down');

      await s.sendDraft('d1');

      expect(drafts.pending, hasLength(1));
      expect(s.entries.last.kind, VoiceEntryKind.system);
      expect(s.entries.last.text, VoiceSession.sendFailedCode);
      expect(s.status, VoiceSessionStatus.live);
    });
  });

  // testWidgets, not test: the cap is a real Timer, and only flutter_test's
  // FakeAsync zone lets it fire on demand instead of after ten real minutes.
  group('session cap', () {
    testWidgets('ends the session by itself once the cap runs out', (
      tester,
    ) async {
      final s = session();
      await s.start();
      expect(s.status, VoiceSessionStatus.live);

      await tester.pump(kVoiceSessionCap + const Duration(seconds: 1));
      await tester.pump();

      expect(s.status, VoiceSessionStatus.ended);
      expect(s.entries.map((e) => e.text), [
        VoiceSession.capReachedCode,
        VoiceSession.endedCode,
        noUsage,
      ]);
      expect(mic.stopCalls, 1);
      expect(speaker.disposeCalls, 1);
    });

    testWidgets('is wall clock from start: a reconnect does not restart it', (
      tester,
    ) async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      connector.last.pushResumption('h1');
      await tester.pump();

      // One minute short of the cap, the connection drops and is resumed.
      await tester.pump(kVoiceSessionCap - const Duration(minutes: 1));
      await connector.transports.first.server.close();
      await tester.pump();

      expect(connector.handles, [null, 'h1']);
      expect(s.status, VoiceSessionStatus.live);

      // A cap that restarted with the reconnect would still have most of its
      // ten minutes left here.
      await tester.pump(const Duration(minutes: 1, seconds: 1));
      await tester.pump();

      expect(s.status, VoiceSessionStatus.ended);
      expect(s.entries.map((e) => e.text), [
        VoiceSession.resumedCode,
        VoiceSession.capReachedCode,
        VoiceSession.endedCode,
        noUsage,
      ]);
    });

    testWidgets('a call the cap ended is over: the next start is a new one', (
      tester,
    ) async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      connector.last.pushResumption('h1');
      await tester.pump();

      await advance(tester, kVoiceSessionCap + const Duration(seconds: 1));
      await tester.pump();
      expect(s.status, VoiceSessionStatus.ended);

      await s.start();

      // Resuming on the handle the cap outlived would carry the capped
      // conversation on under a brand new cap.
      expect(connector.handles, [null, null]);
      expect(s.status, VoiceSessionStatus.live);

      // The fresh cap is armed; the framework fails the test on a leaked one.
      await s.stop();
    });

    testWidgets('the handle dies with the call the cap ended', (tester) async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      connector.last.pushResumption('h1');
      await tester.pump();

      // Call A is killed by the cap with its handle still in hand.
      await advance(tester, kVoiceSessionCap + const Duration(seconds: 1));
      await tester.pump();
      expect(s.status, VoiceSessionStatus.ended);

      // Restart begins call B, and the screen is left before the server ever
      // offers B a handle of its own.
      await s.start();
      await s.suspend();

      // A handle left over from A would make B look resumable and stitch the
      // capped conversation back on — under a cap that just restarted.
      expect(s.resumable, isFalse);
      await s.start();

      expect(connector.handles, [null, null, null]);
      await s.stop();
    });

    testWidgets('stopping before the cap leaves no timer to fire', (
      tester,
    ) async {
      final s = session();
      await s.start();
      await s.stop();

      await tester.pump(kVoiceSessionCap + const Duration(seconds: 1));

      expect(s.entries.map((e) => e.text), [VoiceSession.endedCode, noUsage]);
    });
  });

  group('usage readout', () {
    // The `usageMetadata` of one real turn, from the same capture the
    // transport's own tests replay.
    final turn =
        (jsonDecode(File('test/voice/live_frames.json').readAsStringSync())
                as Map<String, Object?>)['turnComplete']!
            as Map<String, Object?>;

    test(
      'a session whose frames carry no usage still ends, and says so',
      () async {
        final s = session();
        await s.start();
        // A frame that goes through the whole handling path carrying no usage.
        transport.push(audioChunk());
        await settle();

        await s.stop();

        expect(s.status, VoiceSessionStatus.ended);
        expect(s.entries.map((e) => e.text), [VoiceSession.endedCode, noUsage]);
      },
    );

    test('the readout sums every transport the call used', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      connector.last.usage.add(turn['usageMetadata']);
      connector.last.pushResumption('h1');
      await settle();
      // A genuine drop: the session reconnects onto a second transport, and
      // what the call cost is both of them together.
      await connector.transports.first.server.close();
      await settle();
      connector.last.usage.add(turn['usageMetadata']);
      clock = clock.add(const Duration(minutes: 2, seconds: 5));

      await s.stop();

      expect(
        s.entries.last.text,
        [
          'usage · 2 turns · 2m 5s',
          'prompt 1964 (TEXT 1484, AUDIO 402)',
          'response 40 (AUDIO 40)',
        ].join(' · '),
      );
    });
  });

  group('suspend()', () {
    // The `usageMetadata` of one real turn, as the usage group replays it.
    final turn =
        (jsonDecode(File('test/voice/live_frames.json').readAsStringSync())
                as Map<String, Object?>)['turnComplete']!
            as Map<String, Object?>;

    /// Starts [s], lets the server offer a handle, then suspends.
    Future<void> startAndSuspend(VoiceSession s, FakeConnector c) async {
      await s.start();
      c.last.pushResumption('h1');
      await settle();
      await s.suspend();
    }

    test('start after it continues the same conversation', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await startAndSuspend(s, connector);

      expect(s.resumable, isTrue);
      expect(s.entries.map((e) => e.text).first, VoiceSession.suspendedCode);

      await s.start();

      expect(connector.handles, [null, 'h1']);
      expect(s.status, VoiceSessionStatus.live);
      expect(s.resumable, isFalse, reason: 'one suspension, one continuation');
      // Without this the log reads "ended" and then simply goes live again,
      // and the reader cannot tell the conversation survived.
      expect(s.entries.map((e) => e.text), [
        VoiceSession.suspendedCode,
        VoiceSession.endedCode,
        noUsage,
        VoiceSession.resumedCode,
      ]);

      await s.stop();
    });

    test('a start during its teardown still continues the call', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      connector.last.pushResumption('h1');
      await settle();

      // Leaving the screen and coming straight back: the second gesture
      // lands while the teardown is still releasing the mic and the socket,
      // with the status not yet flipped off live.
      final suspending = s.suspend();
      expect(s.status, VoiceSessionStatus.live, reason: 'mid-teardown');
      await s.start();
      await suspending;

      expect(connector.handles, [null, 'h1']);
      expect(s.status, VoiceSessionStatus.live);
      expect(s.entries.map((e) => e.text), contains(VoiceSession.resumedCode));

      await s.stop();
    });

    test('with no handle yet, the next start is a fresh one', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      await s.suspend();

      expect(s.resumable, isFalse);
      await s.start();

      expect(connector.handles, [null, null]);
    });

    test('it is a no-op once the session already ended', () async {
      final s = session();
      await s.start();
      await s.stop();

      await s.suspend();

      expect(s.resumable, isFalse);
      expect(s.entries.map((e) => e.text), [VoiceSession.endedCode, noUsage]);
    });

    test('usage covers the whole call, across the gap', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      connector.last.usage.add(turn['usageMetadata']);
      connector.last.pushResumption('h1');
      await settle();
      clock = clock.add(const Duration(minutes: 1));

      await s.suspend();
      clock = clock.add(const Duration(minutes: 1));
      await s.start();
      connector.last.usage.add(turn['usageMetadata']);
      clock = clock.add(const Duration(minutes: 1));
      await s.stop();

      // A continuation that reset the totals would report one turn and the
      // minute since it started, not the whole three-minute call.
      expect(s.entries.last.text, startsWith('usage · 2 turns · 3m 0s · '));
    });

    test('stop then start does not continue', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      connector.last.pushResumption('h1');
      await settle();

      await s.stop();
      expect(s.resumable, isFalse);
      await s.start();

      expect(connector.handles, [null, null]);
      expect(s.status, VoiceSessionStatus.live);
    });

    test('a continuation that is refused is not offered again', () async {
      final connector = FakeConnector()..throwAt.add(1);
      final s = session(connect: connector.call);
      await startAndSuspend(s, connector);

      await s.start();

      expect(s.status, VoiceSessionStatus.error);
      expect(s.resumable, isFalse);
      expect(
        s.entries.map((e) => e.text),
        isNot(contains(VoiceSession.resumedCode)),
        reason: 'it never got back on the wire',
      );
      await s.start();
      expect(connector.handles, [null, 'h1', null]);

      await s.stop();
    });

    // testWidgets for the FakeAsync zone: the cap is a real Timer.
    testWidgets('the cap is spent while suspended, not extended', (
      tester,
    ) async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      connector.last.pushResumption('h1');
      await tester.pump();

      // Two minutes of talking, two minutes away, then back.
      await advance(tester, const Duration(minutes: 2));
      await s.suspend();
      await advance(tester, const Duration(minutes: 2));
      await s.start();
      expect(s.status, VoiceSessionStatus.live);

      // One minute of the five is left — a cap re-armed for a full
      // kVoiceSessionCap would still have four.
      await advance(tester, const Duration(minutes: 1, seconds: 1));
      await tester.pump();

      expect(s.status, VoiceSessionStatus.ended);
      expect(
        s.entries.map((e) => e.text),
        containsAllInOrder([
          VoiceSession.suspendedCode,
          VoiceSession.capReachedCode,
          VoiceSession.endedCode,
        ]),
      );
    });

    test('a start after the cap ran out while away does not connect', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await startAndSuspend(s, connector);

      clock = clock.add(kVoiceSessionCap + const Duration(seconds: 1));
      await s.start();

      expect(connector.handles, [null], reason: 'never reconnected');
      expect(mic.startCalls, 1);
      expect(s.status, VoiceSessionStatus.ended);
      expect(s.entries.last.text, VoiceSession.capReachedCode);
      expect(s.resumable, isFalse);
    });
  });

  group('background()', () {
    test('ends a live session and logs why', () async {
      final s = session();
      await s.start();

      await s.background();

      expect(s.status, VoiceSessionStatus.ended);
      expect(s.entries.map((e) => e.text), [
        VoiceSession.backgroundedCode,
        VoiceSession.endedCode,
        noUsage,
      ]);
      expect(mic.stopCalls, 1);
      expect(speaker.disposeCalls, 1);
      expect(transport.closeCalls, 1);
    });

    test('is a no-op once the session already ended', () async {
      final s = session();
      await s.start();
      await s.stop();

      await s.background();

      expect(s.status, VoiceSessionStatus.ended);
      expect(s.entries.map((e) => e.text), [VoiceSession.endedCode, noUsage]);
    });
  });
}
