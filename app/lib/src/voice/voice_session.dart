import 'dart:async';
import 'dart:collection';
import 'dart:ui' show Locale;

import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/foundation.dart';

import '../herdr/herdr_client.dart';
import 'voice_audio.dart';
import 'voice_tools.dart';
import 'voice_transport.dart';

enum VoiceSessionStatus { idle, connecting, live, ended, error }

enum VoiceEntryKind { user, assistant, tool, system }

/// One line of the conversation log. [VoiceEntryKind.system] entries carry a
/// stable code ([VoiceSession.interruptedCode] etc.) that the screen maps to
/// l10n; the other kinds carry the spoken/called text verbatim.
class VoiceEntry {
  const VoiceEntry(this.kind, this.text);

  final VoiceEntryKind kind;
  final String text;
}

/// Drives one full-duplex voice conversation: mic -> transport -> speaker,
/// with tool calls answered from [tools]. UI-agnostic; the screen listens.
class VoiceSession extends ChangeNotifier {
  VoiceSession({
    required this._connect,
    required this._mic,
    required this._speaker,
    required this._tools,
    this.muteMicWhileSpeaking = true,
    this._now = DateTime.now,
  });

  /// Production wiring for one herdr host.
  ///
  /// The session talks to a single host; multi-host aggregation is a
  /// follow-up.
  static VoiceSession forHost(HerdrClient client, Locale? locale) {
    final tools = droverVoiceTools(client);
    return VoiceSession(
      connect: () => FirebaseVoiceTransport.connect(
        tools: tools,
        languageCode: voiceLanguageCodeFor(locale),
      ),
      mic: RecordVoiceMic(),
      speaker: SoLoudVoiceSpeaker(),
      tools: tools,
    );
  }

  static const interruptedCode = 'interrupted';
  static const goingAwayCode = 'going_away';
  static const endedCode = 'ended';

  /// [error] value when the microphone permission is missing.
  static const micPermissionDenied = 'mic_permission_denied';

  // ponytail: half-duplex gate — the iOS simulator has no echo cancellation so
  // the model hears itself. The mic is dropped while the model's audio is
  // estimated to still be playing (queued bytes at 24 kHz PCM16 mono) plus a
  // 1.5 s tail. Kills barge-in; flip muteMicWhileSpeaking to false once AEC
  // is confirmed on a real device.
  final bool muteMicWhileSpeaking;
  static const _muteTail = Duration(milliseconds: 1500);
  static const _playbackBytesPerSecond = 48000;

  final Future<VoiceTransport> Function() _connect;
  final VoiceMic _mic;
  final VoiceSpeaker _speaker;
  final List<VoiceTool> _tools;
  final DateTime Function() _now;

  VoiceTransport? _transport;
  StreamSubscription<LiveServerResponse>? _rxSub;
  StreamSubscription<Uint8List>? _micSub;

  /// Server messages are handled strictly in order: each one is chained
  /// behind the previous handler, so an awaited interrupt can't be overtaken
  /// by the next audio chunk.
  Future<void> _rx = Future.value();
  final _entries = <VoiceEntry>[];
  var _status = VoiceSessionStatus.idle;
  String? _partialUser;
  String? _partialAssistant;
  String? _error;

  /// When the model's queued audio is expected to finish playing.
  DateTime _playbackEnd = DateTime.fromMillisecondsSinceEpoch(0);

  /// True from [start] until the matching teardown; makes [stop] idempotent.
  bool _active = false;

  /// Bumped by every [start] and teardown so a [start] still awaiting a step
  /// notices it lost to a [stop] and disposes what it just created.
  int _generation = 0;
  bool _disposed = false;

  VoiceSessionStatus get status => _status;
  List<VoiceEntry> get entries => UnmodifiableListView(_entries);
  String? get partialUser => _partialUser;
  String? get partialAssistant => _partialAssistant;
  String? get error => _error;

  bool get _micMuted =>
      muteMicWhileSpeaking && _now().isBefore(_playbackEnd.add(_muteTail));

  bool _stale(int generation) => generation != _generation || !_active;

  /// Connects and goes live. Callable again after [stop]; a stopped
  /// session keeps its log and appends to it.
  Future<void> start() async {
    if (_status == VoiceSessionStatus.connecting ||
        _status == VoiceSessionStatus.live) {
      return;
    }
    final gen = ++_generation;
    _active = true;
    _setStatus(VoiceSessionStatus.connecting, error: null);
    try {
      final permitted = await _mic.hasPermission();
      if (_stale(gen)) return;
      if (!permitted) {
        await _fail(micPermissionDenied);
        return;
      }
      await _speaker.init();
      if (_stale(gen)) {
        await _speaker.dispose();
        return;
      }
      final transport = await _connect();
      if (_stale(gen)) {
        await transport.close().catchError((Object _) {});
        return;
      }
      _transport = transport;
      _rxSub = transport.receive().listen(
        (response) {
          _rx = _rx
              .then((_) => _onMessage(response))
              .catchError((Object e) => _fail('$e'));
        },
        onError: (Object e) => unawaited(_fail('$e')),
        onDone: () => unawaited(_end()),
      );
      final frames = await _mic.start();
      if (_stale(gen)) {
        await _mic.stop();
        return;
      }
      _micSub = frames.listen((data) {
        if (data.isEmpty || _transport != transport || _micMuted) return;
        // A send that races the socket closing is expected; nothing to do.
        unawaited(transport.sendAudio(data).catchError((Object _) {}));
      });
      _setStatus(VoiceSessionStatus.live);
    } catch (e) {
      if (_stale(gen)) return;
      await _fail('$e');
    }
  }

  /// Tears everything down. Safe to call repeatedly.
  Future<void> stop() => _end();

  Future<void> _onMessage(LiveServerResponse response) async {
    final message = response.message;
    switch (message) {
      case LiveServerContent():
        var changed = false;
        if (message.interrupted == true) {
          _playbackEnd = _now();
          await _speaker.interrupt();
          _entries.add(
            const VoiceEntry(VoiceEntryKind.system, interruptedCode),
          );
          changed = true;
        }
        for (final part in message.modelTurn?.parts ?? const <Part>[]) {
          if (part is InlineDataPart && part.mimeType.startsWith('audio')) {
            _queuePlayback(part.bytes);
          }
        }
        changed |= message.inputTranscription?.text != null;
        changed |= message.outputTranscription?.text != null;
        _partialUser = _accumulate(
          VoiceEntryKind.user,
          _partialUser,
          message.inputTranscription,
        );
        _partialAssistant = _accumulate(
          VoiceEntryKind.assistant,
          _partialAssistant,
          message.outputTranscription,
        );
        if (message.turnComplete == true) {
          _flush(VoiceEntryKind.user, _partialUser);
          _flush(VoiceEntryKind.assistant, _partialAssistant);
          _partialUser = null;
          _partialAssistant = null;
          changed = true;
        }
        // Audio-only chunks arrive many times a second; nothing to redraw.
        if (changed) _notify();
      case LiveServerToolCall():
        // The user's transcription usually arrives after the model already
        // decided to call a tool; flush it first so the log reads in order.
        _flush(VoiceEntryKind.user, _partialUser);
        _partialUser = null;
        final calls = message.functionCalls ?? const <FunctionCall>[];
        for (final call in calls) {
          _entries.add(VoiceEntry(VoiceEntryKind.tool, call.name));
        }
        _notify();
        final responses = await runVoiceToolCalls(calls, _tools);
        // Ignored on purpose: the only failure mode is a socket that closed
        // while the tool ran, which onDone/onError already report.
        await _transport?.sendToolResponse(responses).catchError((Object _) {});
      case GoingAwayNotice():
        _entries.add(const VoiceEntry(VoiceEntryKind.system, goingAwayCode));
        _notify();
      default:
        break;
    }
  }

  /// Plays [bytes] and extends the playback estimate the mic gate keys on.
  void _queuePlayback(Uint8List bytes) {
    _speaker.play(bytes);
    final now = _now();
    final base = _playbackEnd.isAfter(now) ? _playbackEnd : now;
    _playbackEnd = base.add(
      Duration(microseconds: bytes.length * 1000000 ~/ _playbackBytesPerSecond),
    );
  }

  /// Appends [t]'s text to [partial]; a finished transcription becomes an
  /// entry and clears the partial.
  String? _accumulate(VoiceEntryKind kind, String? partial, Transcription? t) {
    final text = t?.text;
    if (text == null) return partial;
    final next = (partial ?? '') + text;
    if (t!.finished == true) {
      _flush(kind, next);
      return null;
    }
    return next;
  }

  void _flush(VoiceEntryKind kind, String? text) {
    if (text != null && text.isNotEmpty) _entries.add(VoiceEntry(kind, text));
  }

  /// Tears down first, then reports: the screen must not offer Restart while
  /// the mic or speaker is still being released.
  Future<void> _fail(String message) async {
    if (!_active) return;
    await _teardown();
    _setStatus(VoiceSessionStatus.error, error: message);
  }

  Future<void> _end() async {
    await _teardown();
    if (_status != VoiceSessionStatus.ended &&
        _status != VoiceSessionStatus.error) {
      _entries.add(const VoiceEntry(VoiceEntryKind.system, endedCode));
      _setStatus(VoiceSessionStatus.ended);
    }
  }

  Future<void> _teardown() async {
    if (!_active) return;
    _active = false;
    _generation++;
    final transport = _transport;
    _transport = null;
    // Not awaited: cancel() hands back a root-zone completed future that
    // never resolves under flutter_test's FakeAsync, and delivery stops
    // synchronously anyway.
    unawaited(_micSub?.cancel());
    _micSub = null;
    unawaited(_rxSub?.cancel());
    _rxSub = null;
    _playbackEnd = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await _mic.stop();
    } catch (_) {}
    try {
      await transport?.close();
    } catch (_) {}
    await _speaker.dispose();
  }

  void _setStatus(VoiceSessionStatus status, {String? error}) {
    _status = status;
    _error = error;
    _notify();
  }

  // Messages already in flight can land after dispose; a disposed notifier
  // throws on notify.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_end().then((_) => _mic.dispose()));
    _disposed = true;
    super.dispose();
  }
}
