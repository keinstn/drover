import 'package:speech_to_text/speech_to_text.dart';

class SpeechInputResult {
  const SpeechInputResult({required this.words, required this.isFinal});

  final String words;
  final bool isFinal;
}

enum SpeechInputStatus { listening, stopped, done }

typedef SpeechInputResultListener = void Function(SpeechInputResult result);
typedef SpeechInputStatusListener = void Function(SpeechInputStatus status);
typedef SpeechInputErrorListener = void Function(String message);

class SpeechInputStartResult {
  const SpeechInputStartResult._(this.errorMessage);

  const SpeechInputStartResult.started() : this._(null);

  const SpeechInputStartResult.failed(String message) : this._(message);

  final String? errorMessage;

  bool get started => errorMessage == null;
}

/// App-scoped interface for a single speech recognition service.
abstract interface class SpeechInput {
  Future<SpeechInputStartResult> start({
    required SpeechInputResultListener onResult,
    required SpeechInputStatusListener onStatus,
    required SpeechInputErrorListener onError,
  });

  Future<void> stop();

  Future<void> cancel();
}

/// Adapts speech_to_text's app-wide singleton to [SpeechInput].
///
/// The plugin only supports one initialized instance, so this controller is
/// created by [DroverApp] and shared by all agent screens.
class SpeechInputController implements SpeechInput {
  SpeechInputController({SpeechToText? speech})
    : _speech = speech ?? SpeechToText();

  final SpeechToText _speech;
  Future<bool>? _initialization;
  SpeechInputResultListener? _onResult;
  SpeechInputStatusListener? _onStatus;
  SpeechInputErrorListener? _onError;
  int _request = 0;

  @override
  Future<SpeechInputStartResult> start({
    required SpeechInputResultListener onResult,
    required SpeechInputStatusListener onStatus,
    required SpeechInputErrorListener onError,
  }) async {
    final request = ++_request;
    _onResult = onResult;
    _onStatus = onStatus;
    _onError = onError;

    final available = await _initialize();
    if (!available) {
      if (request == _request) _clearListeners();
      return const SpeechInputStartResult.failed(
        'Speech recognition is unavailable or permission was denied.',
      );
    }

    try {
      await _speech.listen(
        onResult: (result) {
          _onResult?.call(
            SpeechInputResult(
              words: result.recognizedWords,
              isFinal: result.finalResult,
            ),
          );
        },
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          partialResults: true,
          autoPunctuation: true,
          cancelOnError: true,
          onDevice: true,
        ),
      );
      if (request != _request) {
        await _speech.cancel();
        return const SpeechInputStartResult.failed(
          'Speech recognition was canceled.',
        );
      }
      return const SpeechInputStartResult.started();
    } catch (error) {
      if (request == _request) _clearListeners();
      return SpeechInputStartResult.failed(
        'On-device speech recognition is unavailable: $error',
      );
    }
  }

  Future<bool> _initialize() async {
    try {
      return await (_initialization ??= _speech.initialize(
        onError: (error) {
          _onError?.call('Speech recognition failed: ${error.errorMsg}');
          _clearListeners();
        },
        onStatus: (status) {
          switch (status) {
            case SpeechToText.listeningStatus:
              _onStatus?.call(SpeechInputStatus.listening);
              break;
            case SpeechToText.notListeningStatus:
              _onStatus?.call(SpeechInputStatus.stopped);
              break;
            case SpeechToText.doneStatus:
              _onStatus?.call(SpeechInputStatus.done);
              _clearListeners();
              break;
          }
        },
      ));
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() async {
    _request++;
    _clearListeners();
    await _speech.cancel();
  }

  void _clearListeners() {
    _onResult = null;
    _onStatus = null;
    _onError = null;
  }
}
