import 'dart:async';
import 'dart:math';
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

/// Turns a raw RMS of the -1..1 waveform into the 0..1 level the orb draws.
///
/// ponytail: [kVoiceLevelGain], [kVoiceLevelAttack] and [kVoiceLevelRelease]
/// are the tuning knob, not derived values — set by ear against a real
/// device. Speech RMS sits around 0.02-0.15 of full scale, so the raw number
/// barely moves without the gain, and an unsmoothed one flickers.
const kVoiceLevelGain = 6.0;

/// How far the level moves towards a louder target per window (fast attack).
const kVoiceLevelAttack = 0.5;

/// How far it moves towards a quieter one (slow release), so the orb settles
/// instead of strobing between syllables.
const kVoiceLevelRelease = 0.15;

double voiceLevelFromRms(double rms) => (rms * kVoiceLevelGain).clamp(0.0, 1.0);

/// Level of one PCM16 little-endian frame (the mic's format).
double voiceLevelFromPcm16(Uint8List bytes) {
  // ByteData, not an Int16List view: a frame off the mic stream can start at
  // an odd offset, which asInt16List refuses.
  final data = ByteData.sublistView(bytes);
  final count = data.lengthInBytes ~/ 2;
  if (count == 0) return 0;
  var sum = 0.0;
  for (var i = 0; i < count; i++) {
    final v = data.getInt16(i * 2, Endian.little) / 32768.0;
    sum += v * v;
  }
  return voiceLevelFromRms(sqrt(sum / count));
}

/// Level of one window of -1..1 samples (SoLoud's visualization format).
double voiceLevelFromWave(Float32List samples) {
  if (samples.isEmpty) return 0;
  var sum = 0.0;
  for (final v in samples) {
    sum += v * v;
  }
  return voiceLevelFromRms(sqrt(sum / samples.length));
}

/// Moves [previous] towards [target] with a fast attack and a slow release.
double smoothVoiceLevel(double previous, double target) =>
    previous +
    (target - previous) *
        (target > previous ? kVoiceLevelAttack : kVoiceLevelRelease);

/// Plays the model's PCM16 24 kHz mono audio as it streams in.
abstract interface class VoiceSpeaker {
  Future<void> init();
  void play(Uint8List pcm24k);

  /// RMS of what is actually being played, normalised to 0..1 by
  /// [voiceLevelFromRms]. Silent (never emits) where the engine gives no
  /// visualization windows.
  Stream<double> get level;

  /// Drops whatever is buffered and starts a fresh stream.
  Future<void> interrupt();
  Future<void> dispose();
}

/// [VoiceSpeaker] over a flutter_soloud buffer stream.
class SoLoudVoiceSpeaker implements VoiceSpeaker {
  AudioSource? _stream;
  var _levels = StreamController<double>.broadcast();
  StreamSubscription<AudioVisualizationData>? _vizSub;

  @override
  Stream<double> get level => _levels.stream;

  @override
  Future<void> init() async {
    if (!SoLoud.instance.isInitialized) {
      await SoLoud.instance.init(sampleRate: 24000, channels: Channels.mono);
    }
    await _open();
    // A speaker outlives one session: [dispose] closed the old controller.
    if (_levels.isClosed) _levels = StreamController<double>.broadcast();
    _listenLevels();
  }

  /// Subscribes to the mixer's wave windows, if the engine offers any. It is
  /// unconfirmed that a `setBufferStream` source produces them, so a failure
  /// here only costs the level: playback and the session carry on.
  void _listenLevels() {
    if (_vizSub != null) return;
    try {
      // Wave only: nobody reads the FFT and it costs a transform per window.
      SoLoud.instance.setVisualizationEnabled(
        true,
        kind: VisualizationKind.wave,
      );
    } catch (_) {
      return;
    }
    _vizSub = SoLoud.instance.audioVisualizationEvents.listen((data) {
      final wave = data.waveData;
      if (wave != null && !_levels.isClosed) {
        _levels.add(voiceLevelFromWave(wave));
      }
    });
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
    await _vizSub?.cancel();
    _vizSub = null;
    await _levels.close();
    await _close();
    if (SoLoud.instance.isInitialized) SoLoud.instance.deinit();
  }
}
