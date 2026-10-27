import 'dart:async';

import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/speech/conversation_mode.dart';
import 'package:drover/src/speech/speech_input.dart';
import 'package:drover/src/speech/speech_output.dart';
import 'package:drover/src/transcript/native_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeInput implements SpeechInput {
  var startCalls = 0;
  var stopCalls = 0;
  var cancelCalls = 0;
  Duration? lastPauseFor;
  SpeechInputStartResult startResult = const SpeechInputStartResult.started();
  SpeechInputResultListener? _onResult;
  SpeechInputStatusListener? _onStatus;
  SpeechInputErrorListener? _onError;

  @override
  Future<SpeechInputStartResult> start({
    required SpeechInputResultListener onResult,
    required SpeechInputStatusListener onStatus,
    required SpeechInputErrorListener onError,
    Duration? pauseFor,
  }) async {
    startCalls++;
    lastPauseFor = pauseFor;
    _onResult = onResult;
    _onStatus = onStatus;
    _onError = onError;
    return startResult;
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> cancel() async => cancelCalls++;

  void result(String words, {bool isFinal = false}) =>
      _onResult?.call(SpeechInputResult(words: words, isFinal: isFinal));

  void done() => _onStatus?.call(SpeechInputStatus.done);

  void error() => _onError?.call('boom');
}

/// Each utterance stays "playing" until [finish] (or [stop]) completes it.
class FakeOutput implements SpeechOutput {
  final spoken = <String>[];
  bool failSpeak = false;
  final _pending = <Completer<void>>[];
  var stopCalls = 0;

  bool get isSpeaking => _pending.isNotEmpty;

  @override
  Future<void> speak(String text, {required String localeTag}) {
    spoken.add(text);
    if (failSpeak) return Future.error(StateError('tts failed'));
    final completer = Completer<void>();
    _pending.add(completer);
    return completer.future;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _finishAll();
  }

  void finish() => _pending.removeAt(0).complete();

  void _finishAll() {
    for (final c in _pending) {
      c.complete();
    }
    _pending.clear();
  }
}

TranscriptMessage user(String text) =>
    TranscriptMessage(speaker: TranscriptSpeaker.user, text: text);

TranscriptMessage assistant(String text) =>
    TranscriptMessage(speaker: TranscriptSpeaker.assistant, text: text);

void main() {
  group('speakableText', () {
    test('drops code fences, tables and bare URLs', () {
      const md =
          'Before\n```dart\nfinal x = 1;\n```\n'
          '| a | b |\n|---|---|\n| 1 | 2 |\n'
          'See https://example.com now';
      expect(speakableText(md), 'Before\nSee now');
    });

    test('strips block and inline markers', () {
      const md =
          '## Title\n- **bold** item\n1. *em* and _under_\n> quoted\n'
          'Run `just test` per [the docs](https://x.y). ~~old~~';
      expect(
        speakableText(md),
        'Title\nbold item\nem and under\nquoted\n'
        'Run just test per the docs. old',
      );
    });

    test('keeps snake_case identifiers', () {
      expect(speakableText('call my_func_name now'), 'call my_func_name now');
    });
  });

  group('ConversationController', () {
    late FakeInput input;
    late FakeOutput output;
    late List<String> sent;
    late bool sendResult;
    late ConversationController controller;

    setUp(() {
      input = FakeInput();
      output = FakeOutput();
      sent = [];
      sendResult = true;
      controller = ConversationController(
        input: input,
        output: output,
        send: (text) async {
          sent.add(text);
          return sendResult;
        },
        localeTag: 'ja-JP',
      );
    });

    Future<void> startTurn(String text) async {
      controller.start(text);
      await pumpEventQueue();
    }

    test('speaks only new replies after the anchor, across fresh '
        'instances on every poll', () async {
      await startTurn('Be brief');
      expect(sent, ['Be brief']);
      expect(controller.phase, ConversationPhase.waiting);

      List<TranscriptEntry> poll(List<String> replies) => [
        user('old question'),
        assistant('Old answer.'),
        user('<wrapper>Be brief</wrapper>'),
        const TranscriptThinking('hmm'),
        const TranscriptToolUse(name: 'Bash', input: {}),
        for (final r in replies) assistant(r),
      ];

      controller.onUpdate(poll(['First.']), AgentStatus.working);
      await pumpEventQueue();
      controller.onUpdate(poll(['First.']), AgentStatus.working);
      await pumpEventQueue();
      expect(output.spoken, ['First.']);
      expect(controller.phase, ConversationPhase.speaking);

      controller.onUpdate(
        poll(['First.', 'Second. Third.']),
        AgentStatus.working,
      );
      output.finish();
      await pumpEventQueue();
      output.finish();
      await pumpEventQueue();
      expect(output.spoken, ['First.', 'Second. Third.'], reason: 'one each');
      expect(controller.phase, ConversationPhase.waiting);
      expect(input.startCalls, 0, reason: 'agent still working');

      controller.onUpdate(poll(['First.', 'Second. Third.']), AgentStatus.idle);
      await pumpEventQueue();
      expect(output.spoken, ['First.', 'Second. Third.']);
      expect(controller.phase, ConversationPhase.listening);
      expect(input.lastPauseFor, const Duration(seconds: 4));
    });

    test('speaks nothing until the sent user message appears', () async {
      await startTurn('hello');
      controller.onUpdate([
        user('earlier'),
        assistant('Stale.'),
      ], AgentStatus.working);
      await pumpEventQueue();
      expect(output.spoken, isEmpty);
    });

    test('idle before working does not re-listen early', () async {
      await startTurn('hello');
      controller.onUpdate([assistant('Previous.')], AgentStatus.idle);
      await pumpEventQueue();
      expect(controller.phase, ConversationPhase.waiting);
      expect(input.startCalls, 0);

      controller.onUpdate([user('hello')], AgentStatus.working);
      controller.onUpdate([user('hello')], AgentStatus.idle);
      await pumpEventQueue();
      expect(controller.phase, ConversationPhase.listening);
      expect(input.startCalls, 1);
    });

    test('an all-code reply still ends the turn', () async {
      await startTurn('hello');
      controller.onUpdate([
        user('hello'),
        assistant('```\nprint(1)\n```'),
      ], AgentStatus.idle);
      await pumpEventQueue();
      expect(output.spoken, isEmpty);
      expect(controller.phase, ConversationPhase.listening);
    });

    test('a repeated text waits for its own new user message', () async {
      final history = [user('OK'), assistant('Old.')];
      controller.onUpdate(history, AgentStatus.idle);
      await startTurn('OK');

      // The poll before the send lands still ends with the old "OK".
      controller.onUpdate(history, AgentStatus.working);
      await pumpEventQueue();
      expect(output.spoken, isEmpty);

      controller.onUpdate([
        ...history,
        user('OK'),
        assistant('New.'),
      ], AgentStatus.working);
      await pumpEventQueue();
      expect(output.spoken, ['New.']);
    });

    test('restarting the mode does not re-speak history', () async {
      await startTurn('Be brief');
      final history = [user('Be brief'), assistant('Got it.')];
      controller.onUpdate(history, AgentStatus.idle);
      await pumpEventQueue();
      output.finish();
      await pumpEventQueue();
      expect(output.spoken, ['Got it.']);

      controller.stop();
      // The screen seeds the latest poll before starting again.
      controller.onUpdate(history, AgentStatus.idle);
      await startTurn('Be brief');
      controller.onUpdate(history, AgentStatus.idle);
      await pumpEventQueue();
      expect(output.spoken, ['Got it.']);
      expect(controller.phase, ConversationPhase.waiting);

      controller.onUpdate([
        ...history,
        user('Be brief'),
        assistant('Again.'),
      ], AgentStatus.working);
      await pumpEventQueue();
      expect(output.spoken, ['Got it.', 'Again.']);
    });

    test('tap while waiting does nothing while the agent works', () async {
      await startTurn('hello');
      controller.onUpdate([user('hello')], AgentStatus.working);
      controller.tap();
      await pumpEventQueue();
      expect(controller.phase, ConversationPhase.waiting);
      expect(input.startCalls, 0);
    });

    test('tap while waiting listens', () async {
      await startTurn('hello');
      expect(controller.phase, ConversationPhase.waiting);
      controller.tap();
      await pumpEventQueue();
      expect(controller.phase, ConversationPhase.listening);
      expect(input.startCalls, 1);
    });

    test('waits for queued speech to drain before listening', () async {
      await startTurn('hello');
      controller.onUpdate([
        user('hello'),
        assistant('Done.'),
      ], AgentStatus.idle);
      await pumpEventQueue();
      expect(controller.phase, ConversationPhase.speaking);
      expect(input.startCalls, 0);
      output.finish();
      await pumpEventQueue();
      expect(controller.phase, ConversationPhase.listening);
    });

    test('a final result sends the words verbatim', () async {
      await startTurn('hello');
      controller.onUpdate([user('hello')], AgentStatus.working);
      controller.onUpdate([user('hello')], AgentStatus.idle);
      await pumpEventQueue();

      input.result('fix the');
      expect(controller.partialWords, 'fix the');
      input.result('fix the bug', isFinal: true);
      await pumpEventQueue();
      expect(sent, ['hello', 'fix the bug']);
      expect(controller.phase, ConversationPhase.waiting);
      input.done();
      await pumpEventQueue();
      expect(sent, hasLength(2));
    });

    test('blocked pauses, stops speech and refuses to send', () async {
      await startTurn('hello');
      controller.onUpdate([
        user('hello'),
        assistant('Working on it.'),
      ], AgentStatus.working);
      await pumpEventQueue();
      expect(output.isSpeaking, isTrue);

      controller.onUpdate([
        user('hello'),
        assistant('Working on it.'),
      ], AgentStatus.blocked);
      await pumpEventQueue();
      expect(output.isSpeaking, isFalse);
      expect(controller.phase, ConversationPhase.paused);
      expect(controller.pauseReason, ConversationPauseReason.blocked);

      controller.tap();
      await pumpEventQueue();
      expect(controller.phase, ConversationPhase.listening);
      input.result('approve it', isFinal: true);
      await pumpEventQueue();
      expect(sent, ['hello']);
      expect(controller.phase, ConversationPhase.paused);
      expect(controller.pauseReason, ConversationPauseReason.blocked);
    });

    test('no speech pauses without resending or restarting', () async {
      await startTurn('hello');
      controller.onUpdate([user('hello')], AgentStatus.working);
      controller.onUpdate([user('hello')], AgentStatus.idle);
      await pumpEventQueue();
      expect(input.startCalls, 1);

      input.done();
      await pumpEventQueue();
      expect(controller.phase, ConversationPhase.paused);
      expect(controller.pauseReason, ConversationPauseReason.noSpeech);
      controller.onUpdate([user('hello')], AgentStatus.idle);
      await pumpEventQueue();
      expect(sent, ['hello']);
      expect(input.startCalls, 1);
    });

    test('failed send and failed STT start pause with error', () async {
      sendResult = false;
      await startTurn('hello');
      expect(controller.pauseReason, ConversationPauseReason.error);

      input.startResult = const SpeechInputStartResult.failed('no mic');
      controller.tap();
      await pumpEventQueue();
      expect(controller.phase, ConversationPhase.paused);
      expect(controller.pauseReason, ConversationPauseReason.error);
    });

    test('STT error pauses with error', () async {
      sendResult = false;
      await startTurn('hello');
      controller.tap();
      await pumpEventQueue();
      input.error();
      expect(controller.pauseReason, ConversationPauseReason.error);
    });

    test('a speak failure clears the queue and pauses with error', () async {
      output.failSpeak = true;
      await startTurn('hello');
      controller.onUpdate([
        user('hello'),
        assistant('One. Two.'),
        assistant('Three.'),
      ], AgentStatus.working);
      await pumpEventQueue();
      expect(output.spoken, ['One. Two.']);
      expect(controller.phase, ConversationPhase.paused);
      expect(controller.pauseReason, ConversationPauseReason.error);

      output.failSpeak = false;
      controller.onUpdate([
        user('hello'),
        assistant('One. Two.'),
        assistant('Three.'),
      ], AgentStatus.idle);
      await pumpEventQueue();
      expect(output.spoken, ['One. Two.'], reason: 'rest of the queue dropped');
      expect(input.startCalls, 0);
    });

    test('tap while speaking stops speech and listens', () async {
      await startTurn('hello');
      controller.onUpdate([
        user('hello'),
        assistant('One. Two.'),
        assistant('Three.'),
      ], AgentStatus.working);
      await pumpEventQueue();
      expect(output.spoken, ['One. Two.']);

      controller.tap();
      await pumpEventQueue();
      expect(output.stopCalls, greaterThan(0));
      expect(output.spoken, ['One. Two.'], reason: 'rest of the queue dropped');
      expect(controller.phase, ConversationPhase.listening);
    });

    test('tap while listening sends what was heard', () async {
      sendResult = false;
      await startTurn('hello');
      sendResult = true;
      controller.tap();
      await pumpEventQueue();
      input.result('ship it');
      controller.tap();
      await pumpEventQueue();
      expect(input.stopCalls, 1);
      expect(sent, ['hello', 'ship it']);
      expect(controller.phase, ConversationPhase.waiting);
    });

    test('stop and dispose stop both STT and TTS', () async {
      await startTurn('hello');
      controller.onUpdate([
        user('hello'),
        assistant('Talking.'),
      ], AgentStatus.working);
      await pumpEventQueue();
      controller.stop();
      await pumpEventQueue();
      expect(controller.phase, ConversationPhase.off);
      expect(output.isSpeaking, isFalse);
      expect(input.cancelCalls, 1);

      // Late polls after stop are ignored.
      controller.onUpdate([
        user('hello'),
        assistant('Talking. More.'),
      ], AgentStatus.idle);
      await pumpEventQueue();
      expect(output.spoken, ['Talking.']);
      expect(input.startCalls, 0);

      final cancels = input.cancelCalls;
      final stops = output.stopCalls;
      controller.dispose();
      expect(input.cancelCalls, cancels + 1);
      expect(output.stopCalls, stops + 1);
    });
  });
}
