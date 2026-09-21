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
    Future<VoiceTransport> Function(String?, String)? connect,
    FakeVoiceHerd? herd,
    VoiceInbox? inbox,
    VoiceDrafts? drafts,
    Completer<void>? sleepGate,
  }) => VoiceSession(
    connect: connect ?? (_, _) async => transport,
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

  test('a refused mint ends in the out-of-credits error value', () async {
    final s = session(connect: (_, _) async => throw const VoiceOutOfCredits());
    await s.start();

    // The wallet is unreadable from the device, so a refused mint is the only
    // thing the app ever learns about the balance — and it gets its own copy
    // rather than a stringified exception.
    expect(s.status, VoiceSessionStatus.error);
    expect(s.error, VoiceSession.outOfCredits);
  });

  test(
    'a spent campaign is its own error value, not an empty wallet',
    () async {
      final s = session(
        connect: (_, _) async =>
            throw const VoiceOutOfCredits(campaignOver: true),
      );
      await s.start();

      // Same code and same status on the wire; the screen still has to be
      // able to tell "you have none" from "there are none left for anyone".
      expect(s.status, VoiceSessionStatus.error);
      expect(s.error, VoiceSession.campaignOver);
    },
  );

  test('a finished call reports the time it was actually connected', () async {
    final s = session();
    await s.start();
    clock = clock.add(const Duration(seconds: 298));
    await s.stop();

    // Only the End that closes a call out marks it finished, and by then
    // the connected total is settled — which is what the receipt reads.
    expect(s.finished, isTrue);
    expect(s.connected, const Duration(seconds: 298));
  });

  test('a parked call is not finished and does not stop counting', () async {
    final s = session();
    await s.start();
    clock = clock.add(const Duration(seconds: 60));
    await s.background();
    // The gap: time spent away is not call time.
    clock = clock.add(const Duration(minutes: 2));

    expect(s.status, VoiceSessionStatus.ended);
    expect(s.finished, isFalse);
    expect(s.connected, const Duration(seconds: 60));
  });

  test('a call that died mid-sentence is finished and paid for', () async {
    final s = session();
    await s.start();
    clock = clock.add(const Duration(seconds: 298));
    transport.server.addError(StateError('the connection dropped'));
    await pumpEventQueue();

    // The transport existed, so the mint behind it went through: the call
    // is over for good and it cost a credit, however badly it went.
    expect(s.status, VoiceSessionStatus.error);
    expect(s.finished, isTrue);
    expect(s.spent, isTrue);
    expect(s.connected, const Duration(seconds: 298));
  });

  test('a refused mint is finished but spent nothing', () async {
    final s = session(connect: (_, _) async => throw const VoiceOutOfCredits());
    await s.start();

    expect(s.finished, isTrue);
    expect(s.spent, isFalse);
  });

  test('a dial that never got a transport spent nothing either', () async {
    final s = session(connect: (_, _) async => throw StateError('no host'));
    await s.start();

    // Not a refusal, but no transport either: the session cannot know a
    // mint went out, and must not claim a credit it cannot see.
    expect(s.status, VoiceSessionStatus.error);
    expect(s.finished, isTrue);
    expect(s.spent, isFalse);
  });

  test('a missing microphone permission spends nothing', () async {
    mic = FakeMic(permitted: false);
    final s = session();
    await s.start();

    expect(s.spent, isFalse);
  });

  test('a resumed park keeps the credit it already paid', () async {
    final connector = FakeConnector();
    final s = session(connect: connector.call);
    await s.start();
    connector.last.pushResumption('h1');
    await pumpEventQueue();
    await s.background();
    expect(s.spent, isTrue, reason: 'parked');

    await s.start();

    // Same call, same credit: the reset only happens for a start that
    // begins a new one.
    expect(s.spent, isTrue);
    expect(connector.handles, [null, 'h1']);
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
      connect: (_, _) async => transport,
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
    final s = session(connect: (_, _) => connecting.future);

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

  group('focus', () {
    final claude = fakeAgent(paneId: 'p1', title: 'Implement OAuth');
    final codex = fakeAgent(paneId: 'p2', kind: 'codex', name: 'Reviewer');

    test('focusAgent tells the model whose screen is open', () async {
      final s = session();
      await s.start();

      s.focusAgent(claude);
      await settle();

      expect(transport.sentText, hasLength(1));
      expect(transport.sentText.single, startsWith('[focus] '));
      expect(transport.sentText.single, contains('Implement OAuth'));
      // Navigation, not conversation: nothing reaches the log.
      expect(s.entries, isEmpty);
    });

    test('focusing the same pane twice sends one hint', () async {
      final s = session();
      await s.start();

      s.focusAgent(claude);
      s.focusAgent(claude);
      await settle();

      expect(transport.sentText, hasLength(1));
    });

    test('releasing a pane that lost the focus sends nothing', () async {
      final s = session();
      await s.start();
      s.focusAgent(claude);
      await settle();
      s.focusAgent(codex);
      await settle();

      // What the outgoing screen does after the incoming one took over.
      s.releaseFocus('p1');
      await settle();

      expect(transport.sentText, hasLength(2));
      expect(transport.sentText.last, contains('Reviewer'));
    });

    test('releasing the focused pane says no screen is open', () async {
      final s = session();
      await s.start();
      s.focusAgent(claude);
      await settle();

      s.releaseFocus('p1');
      await settle();

      expect(transport.sentText, hasLength(2));
      expect(transport.sentText.last, startsWith('[focus] '));
      expect(transport.sentText.last, contains('no longer looking'));
    });

    test('a session that is not live sends nothing', () async {
      final s = session();

      s.focusAgent(claude);
      s.releaseFocus('p1');
      await settle();

      expect(transport.sentText, isEmpty);
      expect(s.status, VoiceSessionStatus.idle);
    });

    test('a hint waiting out playback names where focus ended up', () async {
      final gate = Completer<void>();
      final s = session(sleepGate: gate);
      await s.start();
      // Two seconds of model audio, so the first hint parks in the wait.
      transport.push(audioChunk(bytes: 96000));
      await settle();

      s.focusAgent(claude);
      await settle();
      expect(sleeps, hasLength(1), reason: 'parked in the first sleep');
      expect(transport.sentText, isEmpty);

      s.focusAgent(codex);
      gate.complete();
      await settle();

      expect(transport.sentText, hasLength(1));
      expect(transport.sentText.single, contains('Reviewer'));
    });
  });

  group('focus reconciliation', () {
    final claude = fakeAgent(paneId: 'p1', title: 'Implement OAuth');

    /// A connect that hands out [transport] first and parks every later one
    /// on [gate], so the window a reconnect leaves with no transport can be
    /// held open.
    Future<VoiceTransport> Function(String?, String) gatedConnect(
      Completer<VoiceTransport> gate,
    ) {
      var calls = 0;
      return (_, _) => ++calls == 1 ? Future.value(transport) : gate.future;
    }

    /// Drops the first connection after offering a handle, leaving the
    /// session reconnecting with `_transport` null.
    Future<void> dropIntoReconnect(VoiceSession s) async {
      transport.pushResumption('h1');
      await settle();
      await transport.server.close();
      await settle();
    }

    test('a focus set while reconnecting lands on the new wire', () async {
      final gate = Completer<VoiceTransport>();
      final resumed = FakeTransport();
      final s = session(connect: gatedConnect(gate));
      await s.start();
      await dropIntoReconnect(s);
      expect(s.status, VoiceSessionStatus.connecting);

      s.focusAgent(claude);
      await settle();
      expect(transport.sentText, isEmpty, reason: 'that wire is gone');

      gate.complete(resumed);
      await settle();

      expect(resumed.sentText, hasLength(1));
      expect(resumed.sentText.single, contains('Implement OAuth'));
      expect(s.status, VoiceSessionStatus.live);
    });

    test('a release lost to a reconnect is said on the new wire', () async {
      final gate = Completer<VoiceTransport>();
      final resumed = FakeTransport();
      final s = session(connect: gatedConnect(gate));
      await s.start();
      s.focusAgent(claude);
      await settle();
      expect(transport.sentText, hasLength(1));
      await dropIntoReconnect(s);

      // Leaving the screen inside the window: the model still believes the
      // user is on it, and the prompt tells it to trust that.
      s.releaseFocus('p1');
      await settle();
      gate.complete(resumed);
      await settle();

      expect(resumed.sentText, hasLength(1));
      expect(resumed.sentText.single, contains('no longer looking'));
    });

    test('a focus released inside the playback wait sends nothing', () async {
      final gate = Completer<void>();
      final s = session(sleepGate: gate);
      await s.start();
      // Two seconds of model audio, so the hint parks in the wait.
      transport.push(audioChunk(bytes: 96000));
      await settle();

      s.focusAgent(claude);
      await settle();
      expect(sleeps, hasLength(1), reason: 'parked in the first sleep');
      s.releaseFocus('p1');
      gate.complete();
      await settle();

      // The two cancel: barging into the model's turn to say the user opened
      // a screen and left it again is worse than saying nothing.
      expect(transport.sentText, isEmpty);
    });

    test('a call that goes live on a focused pane says so', () async {
      final s = session();
      s.focusAgent(claude);
      await settle();
      expect(transport.sentText, isEmpty);

      await s.start();
      await settle();

      expect(transport.sentText, hasLength(1));
      expect(transport.sentText.single, contains('Implement OAuth'));
    });

    test('a fresh conversation is told the focus again', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      s.focusAgent(claude);
      await settle();
      expect(connector.transports.first.sentText, hasLength(1));

      // End and start again: a new Live conversation, which has been told
      // nothing, however much the last one knew.
      await s.stop();
      await s.start();
      await settle();

      expect(connector.transports[1].sentText, hasLength(1));
      expect(connector.transports[1].sentText.single, contains('OAuth'));
    });
  });

  group('resumption', () {
    final claude = fakeAgent(paneId: 'p1', title: 'Implement OAuth');

    /// A connect that hands out [transport] first and parks every later one
    /// on [gate], so a reconnect can be observed mid-flight.
    Future<VoiceTransport> Function(String?, String) gatedConnect(
      Completer<VoiceTransport> gate,
    ) {
      var calls = 0;
      return (_, _) => ++calls == 1 ? Future.value(transport) : gate.future;
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

    test('a resumed conversation keeps its voice session id', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      connector.last.pushResumption('h1');
      await settle();
      await connector.transports.first.server.close();
      await settle();

      expect(connector.sessionIds, hasLength(2));
      expect(connector.sessionIds.first, isNotEmpty);
      expect(
        connector.sessionIds[1],
        connector.sessionIds.first,
        reason:
            'a reconnect re-mints, and mintVoiceToken charges per id — '
            'a second id would bill one conversation twice',
      );
    });

    test('resuming a parked call keeps its voice session id', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      // Backgrounding parks the call rather than ending it, so coming back is
      // the same conversation — and must not be a second debit.
      await s.background();
      await s.start();
      await settle();

      expect(connector.sessionIds, hasLength(2));
      expect(
        connector.sessionIds[1],
        connector.sessionIds.first,
        reason:
            'an unpark re-mints, and a fresh id would charge again for a '
            'call the user never ended',
      );
    });

    test('a restart is a new call with a new voice session id', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      await s.stop();
      await s.start();
      await settle();

      expect(connector.sessionIds, hasLength(2));
      expect(connector.sessionIds[1], isNot(connector.sessionIds.first));
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

    test('parking with a pending draft does not warn about it', () async {
      final s = session(herd: herd, inbox: VoiceInbox(), drafts: drafts);
      await s.start();
      await draftViaTool();

      await s.background();

      // The call is coming back to send it; the warning belongs at the end
      // that finishes the call, not at a pause in the middle of it.
      expect(s.entries.map((e) => e.text).skip(2), [
        VoiceSession.backgroundedCode,
      ]);
    });

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

    testWidgets('it survives a park made before the first handle', (
      tester,
    ) async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      // No SessionResumptionUpdate ever arrives, so nothing is resumable —
      // but it is still one call, and one cap.
      await s.start();
      await advance(tester, const Duration(minutes: 2));
      await s.background();
      await advance(tester, const Duration(minutes: 2));
      await s.start();

      expect(s.resumable, isFalse);
      expect(connector.handles, [null, null], reason: 'a new conversation');
      expect(s.status, VoiceSessionStatus.live);

      // One minute of the five is left. A deadline that keyed on the handle
      // would have handed this call a whole fresh cap.
      await advance(tester, const Duration(minutes: 1, seconds: 1));
      await tester.pump();

      expect(s.status, VoiceSessionStatus.ended);
      expect(
        s.entries.map((e) => e.text),
        containsAllInOrder([
          VoiceSession.backgroundedCode,
          VoiceSession.capReachedCode,
          VoiceSession.endedCode,
        ]),
      );
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

      // Restart begins call B, and the app is backgrounded before the server
      // ever offers B a handle of its own.
      await s.start();
      await s.background();

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

  // testWidgets for the FakeAsync zone: the bound is a real Timer.
  testWidgets('a wedged release does not strand the next start', (
    tester,
  ) async {
    final gate = Completer<void>();
    speaker = FakeSpeaker(disposeGate: gate);
    final connector = FakeConnector();
    final s = session(connect: connector.call);
    await s.start();
    connector.last.pushResumption('h1');
    await tester.pump();

    // The speaker never finishes releasing — voice_transport.dart documents
    // the same shape for a socket close.
    final parking = s.background();
    await tester.pump();
    expect(s.status, VoiceSessionStatus.live, reason: 'stuck in the release');

    await advance(tester, const Duration(seconds: 3));
    await parking;
    expect(s.status, VoiceSessionStatus.ended, reason: 'the bound gave up');

    // Which is the point: an unbounded release parks every later start on it
    // forever, while the herd screen keeps handing the session back as live.
    await s.start();
    expect(s.status, VoiceSessionStatus.live);
    expect(connector.handles, [null, 'h1']);

    gate.complete();
    await s.stop();
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

  group('background()', () {
    // The `usageMetadata` of one real turn, as the usage group replays it.
    final turn =
        (jsonDecode(File('test/voice/live_frames.json').readAsStringSync())
                as Map<String, Object?>)['turnComplete']!
            as Map<String, Object?>;

    /// Starts [s], lets the server offer a handle, then backgrounds.
    Future<void> startAndBackground(VoiceSession s, FakeConnector c) async {
      await s.start();
      c.last.pushResumption('h1');
      await settle();
      await s.background();
    }

    test('ends a live session and logs why', () async {
      final s = session();
      await s.start();

      await s.background();

      // Ended as far as the screen is concerned, but the call is parked, not
      // finished: the log says why it stopped and nothing more.
      expect(s.status, VoiceSessionStatus.ended);
      expect(s.entries.map((e) => e.text), [VoiceSession.backgroundedCode]);
      expect(mic.stopCalls, 1);
      expect(speaker.disposeCalls, 1);
      expect(transport.closeCalls, 1);
    });

    test('start after it continues the same conversation', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await startAndBackground(s, connector);

      expect(s.resumable, isTrue);
      expect(s.entries.map((e) => e.text).first, VoiceSession.backgroundedCode);

      await s.start();

      expect(connector.handles, [null, 'h1']);
      expect(s.status, VoiceSessionStatus.live);
      expect(s.resumable, isFalse, reason: 'one parking, one continuation');
      // One uninterrupted call: no "Session ended" and no usage readout in
      // the middle of it — only why it paused and that it came back.
      expect(s.entries.map((e) => e.text), [
        VoiceSession.backgroundedCode,
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

      // Leaving the app and coming straight back: the second gesture lands
      // while the teardown is still releasing the mic and the socket, with
      // the status not yet flipped off live.
      final backgrounding = s.background();
      expect(s.status, VoiceSessionStatus.live, reason: 'mid-teardown');
      await s.start();
      await backgrounding;

      expect(connector.handles, [null, 'h1']);
      expect(s.status, VoiceSessionStatus.live);
      expect(s.entries.map((e) => e.text), contains(VoiceSession.resumedCode));

      await s.stop();
    });

    test('a disposed session is neither resumable nor startable', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      connector.last.pushResumption('h1');
      await settle();
      await s.background();
      expect(s.resumable, isTrue);

      // HerdScreen can drop a retained session while a pushed VoiceScreen
      // still holds the object and acts on its `resumable`.
      s.dispose();
      await settle();

      expect(s.resumable, isFalse);
      await s.start();

      expect(connector.handles, [null], reason: 'nothing reconnected');
      expect(mic.startCalls, 1, reason: 'no mic on a released audio path');
    });

    test('with no handle yet, the next start is a fresh one', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      await s.background();

      expect(s.resumable, isFalse);
      await s.start();

      expect(connector.handles, [null, null]);
    });

    test('a handle-less park is still the paid-for call', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      await s.background();

      // The pairing is the point: the Live conversation cannot be picked up,
      // but the call is parked inside its cap and already paid for, so
      // whoever holds this session must keep it.
      expect(s.resumable, isFalse);
      expect(s.parked, isTrue);
    });

    test('a park is over once the cap has run out', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      await s.background();

      clock = clock.add(kVoiceSessionCap);

      expect(s.parked, isFalse, reason: 'nothing left to continue');
    });

    test('stop leaves nothing parked', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      await s.background();
      expect(s.parked, isTrue);

      await s.stop();

      expect(s.parked, isFalse);
    });

    test('it is a no-op once the session already ended', () async {
      final s = session();
      await s.start();
      await s.stop();

      await s.background();

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

      await s.background();
      clock = clock.add(const Duration(minutes: 1));
      await s.start();
      connector.last.usage.add(turn['usageMetadata']);
      clock = clock.add(const Duration(minutes: 1));
      await s.stop();

      // Both turns, because the totals were kept — but two minutes, not
      // three: the minute spent parked is not connected time, and cost per
      // minute is read off this line.
      expect(s.entries.last.text, startsWith('usage · 2 turns · 2m 0s · '));
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
      await startAndBackground(s, connector);

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
    testWidgets('the cap is spent while away, not extended', (tester) async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await s.start();
      connector.last.pushResumption('h1');
      await tester.pump();

      // Two minutes of talking, two minutes away, then back.
      await advance(tester, const Duration(minutes: 2));
      await s.background();
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
          VoiceSession.backgroundedCode,
          VoiceSession.capReachedCode,
          VoiceSession.endedCode,
        ]),
      );
    });

    test('a start after the cap ran out while away does not connect', () async {
      final connector = FakeConnector();
      final s = session(connect: connector.call);
      await startAndBackground(s, connector);

      clock = clock.add(kVoiceSessionCap + const Duration(seconds: 1));
      await s.start();

      expect(connector.handles, [null], reason: 'never reconnected');
      expect(mic.startCalls, 1);
      expect(s.status, VoiceSessionStatus.ended);
      // The park left the call open; coming back to a dead cap is where it
      // really ends, so this is where the readout lands.
      expect(
        s.entries.map((e) => e.text),
        containsAllInOrder([
          VoiceSession.backgroundedCode,
          VoiceSession.capReachedCode,
          VoiceSession.endedCode,
        ]),
      );
      expect(s.entries.last.text, startsWith('usage · '));
      expect(s.resumable, isFalse);
    });
  });
}
