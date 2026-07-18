import 'dart:async';

import 'package:flutter/services.dart';
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

abstract interface class OnDeviceSpeechSupport {
  Future<bool> isSupported();
}

class PlatformOnDeviceSpeechSupport implements OnDeviceSpeechSupport {
  static const _channel = MethodChannel('com.keinstn.drover/speech');

  @override
  Future<bool> isSupported() async {
    return await _channel.invokeMethod<bool>('supportsOnDeviceRecognition') ??
        false;
  }
}

/// Adapts speech_to_text's app-wide singleton to [SpeechInput].
///
/// The plugin only supports one initialized instance, so this controller is
/// created by [DroverApp] and shared by all agent screens.
class SpeechInputController implements SpeechInput {
  SpeechInputController({
    SpeechToText? speech,
    OnDeviceSpeechSupport? onDeviceSupport,
  }) : _speech = speech ?? SpeechToText(),
       _onDeviceSupport = onDeviceSupport ?? PlatformOnDeviceSpeechSupport();

  final SpeechToText _speech;
  final OnDeviceSpeechSupport _onDeviceSupport;
  Future<bool>? _initialization;
  SpeechInputResultListener? _onResult;
  SpeechInputStatusListener? _onStatus;
  SpeechInputErrorListener? _onError;
  Timer? _listenerCleanup;
  int _request = 0;

  @override
  Future<SpeechInputStartResult> start({
    required SpeechInputResultListener onResult,
    required SpeechInputStatusListener onStatus,
    required SpeechInputErrorListener onError,
  }) async {
    final request = ++_request;
    _listenerCleanup?.cancel();
    _listenerCleanup = null;
    _onResult = onResult;
    _onStatus = onStatus;
    _onError = onError;

    final supportsOnDevice = await _supportsOnDeviceRecognition();
    if (!supportsOnDevice) {
      if (request == _request) _clearListeners();
      return const SpeechInputStartResult.failed(
        'On-device speech recognition is unavailable on this device.',
      );
    }
    if (request != _request) {
      return const SpeechInputStartResult.failed(
        'Speech recognition was canceled.',
      );
    }

    final available = await _initialize();
    if (!available) {
      if (request == _request) _clearListeners();
      return const SpeechInputStartResult.failed(
        'Speech recognition is unavailable or permission was denied.',
      );
    }
    if (request != _request) {
      return const SpeechInputStartResult.failed(
        'Speech recognition was canceled.',
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
      if (request == _request) {
        _request++;
        _clearListeners();
      }
      Object? cancellationError;
      try {
        await _speech.cancel();
      } catch (error) {
        cancellationError = error;
      }
      final cancellationDetails = cancellationError == null
          ? ''
          : ' The microphone could not be stopped: $cancellationError';
      return SpeechInputStartResult.failed(
        'On-device speech recognition is unavailable: '
        '$error$cancellationDetails',
      );
    }
  }

  Future<bool> _supportsOnDeviceRecognition() async {
    try {
      return await _onDeviceSupport.isSupported();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _initialize() async {
    final existing = _initialization;
    if (existing != null) return existing;

    final initialization = _speech.initialize(
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
            final request = _request;
            _listenerCleanup?.cancel();
            _listenerCleanup = Timer(const Duration(milliseconds: 250), () {
              if (request == _request) _clearListeners();
            });
            break;
        }
      },
    );
    _initialization = initialization;
    try {
      final available = await initialization;
      if (!available && identical(_initialization, initialization)) {
        _initialization = null;
      }
      return available;
    } catch (_) {
      if (identical(_initialization, initialization)) {
        _initialization = null;
      }
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
    _listenerCleanup?.cancel();
    _listenerCleanup = null;
    _onResult = null;
    _onStatus = null;
    _onError = null;
  }
}
