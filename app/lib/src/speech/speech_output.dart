import 'package:flutter/services.dart';

/// Text-to-speech for conversation mode.
abstract interface class SpeechOutput {
  /// Completes when the utterance finishes or is cut short by [stop].
  Future<void> speak(String text, {required String localeTag});

  Future<void> stop();
}

/// Speaks through the Runner's own AVSpeechSynthesizer (`DroverSpeaker` in
/// AppDelegate.swift / MainFlutterWindow.swift), which picks the best
/// installed voice for the locale and answers `speak` only once the
/// utterance has finished or been stopped.
class PlatformSpeechOutput implements SpeechOutput {
  static const _channel = MethodChannel('com.keinstn.drover/speech');

  @override
  Future<void> speak(String text, {required String localeTag}) =>
      _channel.invokeMethod<void>('speak', {'text': text, 'locale': localeTag});

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stopSpeaking');
}
