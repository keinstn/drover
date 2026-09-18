import 'dart:async';
import 'dart:collection';
import 'dart:ui' show Locale;

import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/foundation.dart';

import 'voice_audio.dart';
import 'voice_drafts.dart';
import 'voice_herd.dart';
import 'voice_tools.dart';
import 'voice_transport.dart';

enum VoiceSessionStatus { idle, connecting, live, ended, error }

enum VoiceEntryKind { user, assistant, tool, system, event, draft, sent }

/// One line of the conversation log. [VoiceEntryKind.system] entries carry a
/// stable code ([VoiceSession.interruptedCode] etc.) that the screen maps to
/// l10n, [VoiceEntryKind.event] entries a `finished:<title>` /
/// `blocked:<title>` code, and [VoiceEntryKind.draft] / [VoiceEntryKind.sent]
/// entries a draft id (see [VoiceSession.drafts]); the other kinds carry the
/// spoken/called text verbatim.
class VoiceEntry {
  const VoiceEntry(this.kind, this.text);

  final VoiceEntryKind kind;
  final String text;
}

/// Whether the model's own voice loops back into the microphone for good, so
/// the half-duplex gate has to stay on for the whole session.
///
/// A real device cancels the echo: [RecordVoiceMic] opens the mic with
/// `echoCancel: true`, which iOS answers with its voice-processing unit. The
/// simulator has no such unit and the model hears itself through the Mac
/// speakers, forever — only a permanent gate helps there.
///
/// Where the canceller does exist it still starts cold, which the shorter
/// [kVoiceAecWarmUp] gate covers; the two layers are independent.
///
/// ponytail: a debug build stands in for "the simulator". The app cannot ask:
/// an iOS app gets an EMPTY `Platform.environment` (measured on the simulator
/// 2026-09-13, so the usual `SIMULATOR_DEVICE_NAME` probe reads the same there
/// as on a device), and a real check would mean a new dependency or an FFI
/// `sysctl` call for one bool. In this project the proxy holds: the simulator
/// is only ever run in debug, and the device only ever gets release builds
/// through TestFlight. It errs safely — a debug build on a device keeps the
/// gate (barge-in off, today's behaviour); only `flutter run --release` on the
/// simulator gets it wrong, and that just brings the echo back in dev.
const voiceMicGateNeeded = !kReleaseMode;

/// How much of the model's own audio has to play before the warm-up gate
/// lets go, on a build that relies on the device's echo canceller.
///
/// iOS's canceller is adaptive: it needs a few seconds of the model's voice
/// to converge, and the first utterance plays right after the mic opens.
/// Measured on device 2026-09-13: the model interrupted itself on the first
/// two or three turns of a session and then never again. So the mic stays
/// gated while the model speaks until this much *model audio* has played
/// (cumulative queued playback, not wall clock — a quiet session warms up
/// slowly), and the gate gets out of the way afterwards.
///
/// ponytail: 10 s is a first guess, to be tuned on device. The trade-off is
/// that barge-in does not work for roughly the first one or two model turns
/// of a session.
const kVoiceAecWarmUp = Duration(seconds: 10);

/// Hard ceiling on one voice conversation, measured as wall clock from
/// [VoiceSession.start] — not per connection. The session reconnects across
/// Live drops (session resumption), so a per-connection cap would bound
/// nothing: an open mic streaming to a third party has to have an end.
/// Restart begins a fresh conversation and a fresh cap.
///
/// ponytail: it just ends, with no warning beforehand — the log line and the
/// Restart button are the whole story. Add a countdown only if ten minutes
/// turns out to cut real conversations short.
const kVoiceSessionCap = Duration(minutes: 10);

/// Drives one full-duplex voice conversation: mic -> transport -> speaker,
/// with tool calls answered from [tools]. UI-agnostic; the screen listens.
class VoiceSession extends ChangeNotifier {
  VoiceSession({
    required this._connect,
    required this._mic,
    required this._speaker,
    required this._tools,
    this._herd,
    this._inbox,
    VoiceDrafts? drafts,
    this.muteMicWhileSpeaking = true,
    this.aecWarmUp = Duration.zero,
    this._now = DateTime.now,
    this._sleep = Future.delayed,
  }) : drafts = drafts ?? VoiceDrafts() {
    _draftsSub = this.drafts.events.listen((event) {
      _entries.add(
        VoiceEntry(switch (event.kind) {
          VoiceDraftEventKind.drafted => VoiceEntryKind.draft,
          VoiceDraftEventKind.sent => VoiceEntryKind.sent,
        }, event.draft.id),
      );
      _notify();
    });
    // Busy flips carry no event, and the screen listens to the session, not
    // to the drafts: forward them so a card can grey its button while its
    // delivery is in flight.
    this.drafts.addListener(_notify);
  }

  /// Production wiring for one herdr host.
  ///
  /// ponytail: the session talks to a single host; multi-host aggregation is
  /// a follow-up.
  static VoiceSession forHerd({
    required VoiceHerd herd,
    required VoiceInbox inbox,
    required Locale? locale,
  }) {
    final drafts = VoiceDrafts();
    final tools = droverVoiceTools(herd, drafts);
    return VoiceSession(
      // One const decides which wire the conversation runs on; see
      // [kVoiceUseMintedToken].
      connect: (resumeHandle) => kVoiceUseMintedToken
          ? TokenVoiceTransport.connect(
              tools: tools,
              languageCode: voiceLanguageCodeFor(locale),
              resumeHandle: resumeHandle,
            )
          : FirebaseVoiceTransport.connect(
              tools: tools,
              languageCode: voiceLanguageCodeFor(locale),
              resumeHandle: resumeHandle,
            ),
      mic: RecordVoiceMic(),
      speaker: SoLoudVoiceSpeaker(),
      muteMicWhileSpeaking: voiceMicGateNeeded,
      aecWarmUp: kVoiceAecWarmUp,
      tools: tools,
      herd: herd,
      inbox: inbox,
      drafts: drafts,
    );
  }

  static const interruptedCode = 'interrupted';
  static const goingAwayCode = 'going_away';
  static const endedCode = 'ended';

  /// System code logged when the dropped connection was resumed and the
  /// conversation carried on.
  static const resumedCode = 'resumed';

  /// System code logged when an agent event could not be read for announcing.
  static const announceFailedCode = 'announce_failed';

  /// System code logged when the session ends with a draft still pending.
  static const unsentDraftsCode = 'unsent_drafts';

  /// System code logged when [sendDraft] failed.
  static const sendFailedCode = 'send_failed';

  /// System code logged when [launchDraft] failed.
  static const launchFailedCode = 'launch_failed';

  /// System code logged when [kVoiceSessionCap] ran out and the session ended
  /// itself.
  static const capReachedCode = 'cap_reached';

  /// System code logged when the app left the foreground and [background]
  /// ended the session: iOS silently kills the microphone on backgrounding,
  /// so an open mic streaming to a third party must not survive it.
  static const backgroundedCode = 'backgrounded';

  /// Drafts of this session; the screen renders them and can act on a
  /// pending one via [sendDraft] / [launchDraft].
  final VoiceDrafts drafts;

  /// [error] value when the microphone permission is missing.
  static const micPermissionDenied = 'mic_permission_denied';

  /// Permanent half-duplex gate: the mic is dropped while the model's audio
  /// is estimated to still be playing (queued bytes at 24 kHz PCM16 mono)
  /// plus a 1.5 s tail, so the model cannot hear itself. It also kills
  /// barge-in, so production only turns it on where echo cancellation is
  /// missing altogether — see [voiceMicGateNeeded]. Defaults to on: a caller
  /// that has not thought about echo gets the safe half-duplex behaviour.
  final bool muteMicWhileSpeaking;

  /// Temporary half-duplex gate for a device whose echo canceller exists but
  /// starts cold: the same drop applies while less than this much model audio
  /// has played since [start], and stops applying once it has. Zero (the
  /// default) means no warm-up gate; production passes [kVoiceAecWarmUp].
  /// Combines with [muteMicWhileSpeaking] by OR.
  final Duration aecWarmUp;
  static const _muteTail = Duration(milliseconds: 1500);
  static const _playbackBytesPerSecond = 48000;

  final Future<VoiceTransport> Function(String? resumeHandle) _connect;
  final VoiceMic _mic;
  final VoiceSpeaker _speaker;
  final List<VoiceTool> _tools;
  final VoiceHerd? _herd;
  final VoiceInbox? _inbox;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _sleep;

  VoiceTransport? _transport;
  StreamSubscription<LiveServerResponse>? _rxSub;
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<AgentEvent>? _inboxSub;
  StreamSubscription<VoiceDraftEvent>? _draftsSub;
  StreamSubscription<double>? _speakerLevelSub;

  /// Announcements are chained like [_rx] so two events read back in order,
  /// but on their own chain: reading an agent's state goes over SSH and must
  /// not hold up audio from the server.
  Future<void> _announcing = Future.value();

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

  /// Model audio queued since the mic was started, against [aecWarmUp].
  int _playedBytesSinceStart = 0;

  /// True from [start] until the matching teardown; makes [stop] idempotent.
  bool _active = false;

  /// Bumped by every [start], reconnect and teardown so a connect still in
  /// flight notices it lost to a [stop] and disposes what it just created.
  int _generation = 0;

  /// What this call has billed for, summed over every transport it used and
  /// read back by [_end] behind [kVoiceUsageReadout]. Reset by [start], so a
  /// Restart measures its own conversation.
  var _usage = VoiceUsage();
  DateTime? _usageStart;

  /// Latest resumption handle the server offered. While it is set a dropped
  /// connection is resumed instead of ending the session.
  String? _resumeHandle;
  bool _disposed = false;

  /// Armed by [start], cancelled by [_teardown]; survives reconnects because
  /// [_lost] never goes back through [start].
  Timer? _capTimer;

  /// Fires [_notify] at [_playbackEnd] so listeners see [speaking] flip back.
  /// Re-armed per audio chunk; cancelled with [_capTimer].
  Timer? _playbackTimer;

  /// Live audio level, 0..1: the mic while the user talks, the speaker while
  /// the model does. Deliberately NOT on this [ChangeNotifier] — windows
  /// arrive tens of times a second and would rebuild the whole screen.
  ValueListenable<double> get level => _level;
  final _level = ValueNotifier<double>(0);

  void _setLevel(double target) {
    if (!_disposed) _level.value = smoothVoiceLevel(_level.value, target);
  }

  VoiceSessionStatus get status => _status;
  List<VoiceEntry> get entries => UnmodifiableListView(_entries);
  String? get partialUser => _partialUser;
  String? get partialAssistant => _partialAssistant;
  String? get error => _error;

  /// Whether the model's audio is still queued at the speaker. The transcript
  /// can finish seconds before the audio does, so the orb keys on this.
  bool get speaking => _active && _now().isBefore(_playbackEnd);

  bool get _micMuted =>
      (muteMicWhileSpeaking || !_aecWarmedUp) &&
      _now().isBefore(_playbackEnd.add(_muteTail));

  /// Whether [aecWarmUp] worth of model audio has played, so the device's
  /// echo canceller has had the input it needs to converge.
  bool get _aecWarmedUp =>
      _playedBytesSinceStart >=
      aecWarmUp.inMicroseconds * _playbackBytesPerSecond ~/ 1000000;

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
    _usage = VoiceUsage();
    _usageStart = _now();
    _capTimer?.cancel();
    _capTimer = Timer(kVoiceSessionCap, () {
      _entries.add(const VoiceEntry(VoiceEntryKind.system, capReachedCode));
      unawaited(_end());
    });
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
      // Strictly after init(): the speaker hands out a fresh stream there.
      _speakerLevelSub = _speaker.level.listen((value) {
        if (speaking) _setLevel(value);
      });
      final transport = await _connect(_resumeHandle);
      if (_stale(gen)) {
        await transport.close().catchError((Object _) {});
        return;
      }
      _bind(transport, gen);
      // The mic engine restarts here, so the device's echo canceller starts
      // cold again and the warm-up gate has to re-earn its way out.
      _playedBytesSinceStart = 0;
      final frames = await _mic.start();
      if (_stale(gen)) {
        await _mic.stop();
        return;
      }
      _micSub = frames.listen((data) {
        if (data.isEmpty) return;
        // Level before the gate, frames after. The output path owns the
        // level while the model plays ([speaking]), so the two never fight
        // and echo can't reach it. What is left gated is the 1.5 s mute
        // tail, a conservative AEC guard that runs *after* the speaker
        // stopped — what the mic hears there is the room, not the model, and
        // it is exactly when the user starts replying. So the tail still
        // drops the frames, but no longer freezes the orb.
        if (!speaking) _setLevel(voiceLevelFromPcm16(data));
        if (_micMuted) return;
        // Read live: the transport is swapped on a resume, and is null while
        // reconnecting, when frames are simply dropped.
        final current = _transport;
        if (current == null) return;
        // A send that races the socket closing is expected; nothing to do.
        unawaited(current.sendAudio(data).catchError((Object _) {}));
      });
      final inbox = _inbox;
      if (inbox != null) {
        // Events that queued up before the conversation started go out as
        // one block; later ones are announced as they arrive — unless a
        // reconnect is in flight, when they stay pending until it lands.
        _announce(inbox.drain());
        _inboxSub = inbox.events.listen((_) {
          if (_transport != null) _announce(inbox.drain());
        });
      }
      _setStatus(VoiceSessionStatus.live);
    } catch (e) {
      if (_stale(gen)) return;
      // A stale handle only surfaces as a connect failure; dropping it makes
      // Restart start fresh instead of looping on it.
      _resumeHandle = null;
      await _fail('$e');
    }
  }

  /// Makes [transport] the current one and routes its messages into [_rx].
  void _bind(VoiceTransport transport, int gen) {
    _transport = transport;
    _rxSub = transport.receive().listen(
      (response) {
        _rx = _rx
            .then((_) => _onMessage(response))
            .catchError((Object e) => _fail('$e'));
      },
      onError: (Object e) => unawaited(_lost(gen, '$e')),
      onDone: () => unawaited(_lost(gen, null)),
    );
  }

  /// The connection dropped ([error] null when it closed cleanly). The server
  /// caps every connection at a few minutes, so with a resumption handle this
  /// reconnects once and carries the conversation on — mic and speaker stay
  /// up throughout. Without one, the session ends as it always has.
  Future<void> _lost(int gen, String? error) async {
    if (_stale(gen)) return;
    // Consumed, not reused: a connection that opens and closes again right
    // away (the server does this when the API credits run out) would
    // otherwise reconnect in a tight loop. The resumed connection re-arms
    // this within seconds via its own SessionResumptionUpdate.
    final handle = _resumeHandle;
    _resumeHandle = null;
    // Only a live session resumes: a drop during [start] would race the mic
    // and inbox wiring that is still being set up behind this callback.
    if (handle == null || _status != VoiceSessionStatus.live) {
      await (error == null ? _end() : _fail(error));
      return;
    }
    // Bumped before the first await so the error/done pair of one drop can
    // only reconnect once.
    final next = ++_generation;
    unawaited(_rxSub?.cancel());
    _rxSub = null;
    final dropped = _transport;
    _transport = null;
    _setStatus(VoiceSessionStatus.connecting);
    try {
      try {
        _takeUsage(dropped);
        await dropped?.close();
      } catch (_) {}
      final transport = await _connect(handle);
      if (_stale(next)) {
        await transport.close().catchError((Object _) {});
        return;
      }
      _bind(transport, next);
      _entries.add(const VoiceEntry(VoiceEntryKind.system, resumedCode));
      _setStatus(VoiceSessionStatus.live);
      final inbox = _inbox;
      if (inbox != null) _announce(inbox.drain());
    } catch (e) {
      if (_stale(next)) return;
      // The handle was refused; Restart starts fresh (it was consumed above).
      await _fail('$e');
    }
  }

  /// Keeps a released transport's totals before it goes: a reconnect builds
  /// a fresh one, and what the call cost is the sum over all of them.
  void _takeUsage(VoiceTransport? transport) {
    if (transport case final VoiceUsageReporter reporter) {
      _usage.absorb(reporter.usage);
    }
  }

  /// Tears everything down. Safe to call repeatedly.
  Future<void> stop() => _end();

  /// Ends the session because the app left the foreground. No-op unless the
  /// session is currently active: the caller is a lifecycle observer that
  /// can fire after the session already ended on its own (a manual stop, an
  /// error, the cap) and must not log a spurious backgrounding line then.
  Future<void> background() async {
    if (!_active) return;
    _entries.add(const VoiceEntry(VoiceEntryKind.system, backgroundedCode));
    await _end();
  }

  /// Sends the pending draft [id] to its agent — the manual fallback when the
  /// model never called send_message. Needs only the herd, so it works after
  /// the live session ended. A failure is logged as [sendFailedCode] and the
  /// draft stays pending.
  Future<void> sendDraft(String id) async {
    final draft = drafts.byId(id);
    final herd = _herd;
    if (draft is! MessageDraft ||
        !drafts.isPending(draft) ||
        drafts.isBusy(draft)) {
      return;
    }
    drafts.markBusy(draft);
    try {
      if (herd == null) throw StateError('no herd');
      await herd.send(draft.agent, draft.message);
      drafts.markSent(draft);
    } catch (_) {
      _entries.add(const VoiceEntry(VoiceEntryKind.system, sendFailedCode));
      _notify();
    } finally {
      drafts.release(draft);
    }
  }

  Future<void> _onMessage(LiveServerResponse response) async {
    final message = response.message;
    switch (message) {
      case LiveServerContent():
        var changed = false;
        if (message.interrupted == true) {
          _playbackEnd = _now();
          // Still armed for the ORIGINAL end of the turn we just dropped —
          // seconds away, because Gemini streams audio faster than realtime.
          // Left alone it would zero the level mid-sentence while the user
          // talks. Safe to cancel here: the [_queuePlayback] loop below
          // re-arms it for any audio in this same message.
          _playbackTimer?.cancel();
          _playbackTimer = null;
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
        // Audio-only chunks arrive many times a second; nothing to redraw
        // here ([_queuePlayback] notifies once, when speaking begins).
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
      case SessionResumptionUpdate():
        final handle = message.newHandle;
        if (message.resumable == true && handle != null && handle.isNotEmpty) {
          _resumeHandle = handle;
        }
      default:
        break;
    }
  }

  /// Tells the model about [events] as injected text, logging one entry per
  /// event. A failed read logs [announceFailedCode] and leaves the session
  /// live; a send after the session ended is dropped. An announcement that
  /// outlives a reconnect goes to the new transport.
  ///
  /// ponytail: one parked in [_awaitPlaybackEnd] when the socket drops is
  /// logged but never spoken — its send finds no transport. Rare enough to
  /// leave; re-queue it on the inbox if it bites.
  void _announce(List<AgentEvent> events) {
    final herd = _herd;
    if (events.isEmpty || herd == null) return;
    _announcing = _announcing.then((_) async {
      if (!_active) return;
      try {
        final text = await announceEvents(events, herd);
        if (!_active) return;
        for (final event in events) {
          _entries.add(
            VoiceEntry(
              VoiceEntryKind.event,
              '${event.kind.name}:${voiceAgentTitle(event.agent)}',
            ),
          );
        }
        _notify();
        if (!await _awaitPlaybackEnd()) return;
        await _transport?.sendText(text);
      } catch (_) {
        if (!_active) return;
        _entries.add(
          const VoiceEntry(VoiceEntryKind.system, announceFailedCode),
        );
        _notify();
      }
    });
  }

  static const _announceWaitBound = Duration(seconds: 20);
  static const _announceWaitStep = Duration(milliseconds: 200);

  /// Waits until the model's estimated playback (plus [_muteTail]) is over:
  /// Gemini Live treats injected text like user speech and barges in, so an
  /// announcement sent mid-sentence cuts the model off. Returns false once
  /// the session is no longer active. Bounded so a wedged estimate can never
  /// hold an announcement back forever.
  ///
  /// ponytail: estimate-based (queued bytes at 24 kHz), the same guess the
  /// mic gate uses — the speaker's buffer stream gives no playback position.
  Future<bool> _awaitPlaybackEnd() async {
    final deadline = _now().add(_announceWaitBound);
    while (_now().isBefore(_playbackEnd.add(_muteTail)) &&
        _now().isBefore(deadline)) {
      await _sleep(_announceWaitStep);
      if (!_active) return false;
    }
    return _active;
  }

  /// Plays [bytes] and extends the playback estimate the mic gate and
  /// [speaking] key on. Notifies only when speaking begins; the end is
  /// reported by [_playbackTimer].
  ///
  /// ponytail: bytes an [interrupt] later drops still count towards
  /// [aecWarmUp], so the warm-up ends a little early after an interrupted
  /// turn. Track what actually reached the speaker if that turns out to
  /// matter.
  void _queuePlayback(Uint8List bytes) {
    _speaker.play(bytes);
    _playedBytesSinceStart += bytes.length;
    final now = _now();
    final wasSpeaking = speaking;
    final base = _playbackEnd.isAfter(now) ? _playbackEnd : now;
    _playbackEnd = base.add(
      Duration(microseconds: bytes.length * 1000000 ~/ _playbackBytesPerSecond),
    );
    _playbackTimer?.cancel();
    _playbackTimer = Timer(_playbackEnd.difference(now), () {
      // Neither path writes during the mute tail that follows, so without
      // this the level would freeze at its last value for 1.5 s.
      if (!_disposed) _level.value = 0;
      _notify();
    });
    if (!wasSpeaking) _notify();
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
      if (drafts.pending.isNotEmpty) {
        _entries.add(const VoiceEntry(VoiceEntryKind.system, unsentDraftsCode));
      }
      if (kVoiceUsageReadout) {
        // Carries its own text rather than a code: the screen renders an
        // unknown system code as it stands, and a developer readout is not
        // worth two locales.
        final line = voiceUsageLine(
          _usage,
          _now().difference(_usageStart ?? _now()),
        );
        _entries.add(VoiceEntry(VoiceEntryKind.system, line));
        debugPrint(line);
      }
      _setStatus(VoiceSessionStatus.ended);
    }
  }

  Future<void> _teardown() async {
    if (!_active) return;
    _active = false;
    // Cancelled before the first await: dispose() does not await _end(), and
    // a timer left armed would fire into a torn-down session.
    _capTimer?.cancel();
    _capTimer = null;
    _playbackTimer?.cancel();
    _playbackTimer = null;
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
    unawaited(_inboxSub?.cancel());
    _inboxSub = null;
    unawaited(_speakerLevelSub?.cancel());
    _speakerLevelSub = null;
    _playbackEnd = DateTime.fromMillisecondsSinceEpoch(0);
    if (!_disposed) _level.value = 0;
    try {
      await _mic.stop();
    } catch (_) {}
    _takeUsage(transport);
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
    unawaited(
      _end().then((_) async {
        await _mic.dispose();
        await _draftsSub?.cancel();
        drafts.dispose();
        _level.dispose();
      }),
    );
    _disposed = true;
    super.dispose();
  }

  /// Starts the pending launch draft [id] — the manual fallback when the
  /// model never called launch. Needs only the herd, so it works after the
  /// live session ended. A failure is logged as [launchFailedCode] and the
  /// draft stays pending.
  Future<void> launchDraft(String id) async {
    final draft = drafts.byId(id);
    final herd = _herd;
    if (draft is! LaunchDraft ||
        !drafts.isPending(draft) ||
        drafts.isBusy(draft)) {
      return;
    }
    drafts.markBusy(draft);
    try {
      if (herd == null) throw StateError('no herd');
      await herd.launch(kind: draft.kind, cwd: draft.cwd, brief: draft.brief);
      drafts.markSent(draft);
    } catch (_) {
      _entries.add(const VoiceEntry(VoiceEntryKind.system, launchFailedCode));
      _notify();
    } finally {
      drafts.release(draft);
    }
  }
}
