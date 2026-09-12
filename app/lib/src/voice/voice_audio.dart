import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:record/record.dart';

/// Microphone producing PCM16 16 kHz mono frames.
abstract interface class VoiceMic {
  Future<bool> hasPermission();
  Future<Stream<Uint8List>> start();
  Future<void> stop();
  Future<void> dispose();
}

/// [VoiceMic] over the `record` plugin.
class RecordVoiceMic implements VoiceMic {
  final _recorder = AudioRecorder();

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start() => _recorder.startStream(
    const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      echoCancel: true,
      iosConfig: IosRecordConfig(
        categoryOptions: [
          IosAudioCategoryOption.defaultToSpeaker,
          IosAudioCategoryOption.allowBluetooth,
        ],
      ),
    ),
  );

  @override
  Future<void> stop() async {
    await _recorder.stop();
    // Hands the audio session back so other audio resumes; `ios` is null
    // elsewhere.
    await _recorder.ios?.setAudioSessionActive(false);
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}

/// Plays the model's PCM16 24 kHz mono audio as it streams in.
abstract interface class VoiceSpeaker {
  Future<void> init();
  void play(Uint8List pcm24k);

  /// Drops whatever is buffered and starts a fresh stream.
  Future<void> interrupt();
  Future<void> dispose();
}

/// [VoiceSpeaker] over a flutter_soloud buffer stream.
class SoLoudVoiceSpeaker implements VoiceSpeaker {
  AudioSource? _stream;

  @override
  Future<void> init() async {
    if (!SoLoud.instance.isInitialized) {
      await SoLoud.instance.init(sampleRate: 24000, channels: Channels.mono);
    }
    await _open();
  }

  Future<void> _open() async {
    final stream = SoLoud.instance.setBufferStream(
      bufferingType: BufferingType.released,
      bufferingTimeNeeds: 0,
      sampleRate: 24000,
      channels: Channels.mono,
      format: BufferType.s16le,
    );
    _stream = stream;
    SoLoud.instance.play(stream);
  }

  Future<void> _close() async {
    final stream = _stream;
    _stream = null;
    if (stream == null) return;
    // Stops the handle and frees the native buffer in one go.
    await SoLoud.instance.disposeSource(stream);
  }

  @override
  void play(Uint8List pcm24k) {
    final stream = _stream;
    if (stream != null) SoLoud.instance.addAudioDataStream(stream, pcm24k);
  }

  @override
  Future<void> interrupt() async {
    await _close();
    await _open();
  }

  /// Ends the stream and shuts the engine down: voice is SoLoud's only user,
  /// and a running engine holds the audio device. [init] brings it back.
  @override
  Future<void> dispose() async {
    await _close();
    if (SoLoud.instance.isInitialized) SoLoud.instance.deinit();
  }
}
