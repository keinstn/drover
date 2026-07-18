import 'dart:async';

import 'package:drover/src/speech/speech_input.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_to_text.dart';

class FakeSpeechToText extends SpeechToText {
  FakeSpeechToText() : super.withMethodChannel();

  final initializationResults = <Future<bool>>[];
  Object? listenError;
  var initializeCalls = 0;
  var listenCalls = 0;
  var cancelCalls = 0;

  @override
  Future<bool> initialize({
    SpeechErrorListener? onError,
    SpeechStatusListener? onStatus,
    debugLogging = false,
    Duration finalTimeout = SpeechToText.defaultFinalTimeout,
    List<SpeechConfigOption>? options,
  }) {
    initializeCalls++;
    return initializationResults.removeAt(0);
  }

  @override
  Future<void> listen({
    SpeechResultListener? onResult,
    Duration? listenFor,
    Duration? pauseFor,
    String? localeId,
    SpeechSoundLevelChange? onSoundLevelChange,
    cancelOnError = false,
    partialResults = true,
    onDevice = false,
    ListenMode listenMode = ListenMode.confirmation,
    sampleRate = 0,
    SpeechListenOptions? listenOptions,
  }) async {
    listenCalls++;
    final error = listenError;
    if (error != null) throw error;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }
}

void main() {
  void ignoreResult(SpeechInputResult _) {}
  void ignoreStatus(SpeechInputStatus _) {}
  void ignoreError(String _) {}

  test('retries initialization after an unavailable result', () async {
    final speech = FakeSpeechToText()
      ..initializationResults.addAll([Future.value(false), Future.value(true)]);
    final input = SpeechInputController(speech: speech);

    final first = await input.start(
      onResult: ignoreResult,
      onStatus: ignoreStatus,
      onError: ignoreError,
    );
    final second = await input.start(
      onResult: ignoreResult,
      onStatus: ignoreStatus,
      onError: ignoreError,
    );

    expect(first.started, isFalse);
    expect(second.started, isTrue);
    expect(speech.initializeCalls, 2);
    expect(speech.listenCalls, 1);
  });

  test(
    'does not start listening after cancellation during initialization',
    () async {
      final initialization = Completer<bool>();
      final speech = FakeSpeechToText()
        ..initializationResults.add(initialization.future);
      final input = SpeechInputController(speech: speech);

      final starting = input.start(
        onResult: ignoreResult,
        onStatus: ignoreStatus,
        onError: ignoreError,
      );
      await input.cancel();
      initialization.complete(true);
      final result = await starting;

      expect(result.started, isFalse);
      expect(speech.listenCalls, 0);
      expect(speech.cancelCalls, 1);
    },
  );

  test('cancels the recognizer when on-device startup throws', () async {
    final speech = FakeSpeechToText()
      ..initializationResults.add(Future.value(true))
      ..listenError = StateError('on-device recognition unavailable');
    final input = SpeechInputController(speech: speech);

    final result = await input.start(
      onResult: ignoreResult,
      onStatus: ignoreStatus,
      onError: ignoreError,
    );

    expect(result.started, isFalse);
    expect(result.errorMessage, contains('on-device recognition unavailable'));
    expect(speech.cancelCalls, 1);
  });
}
