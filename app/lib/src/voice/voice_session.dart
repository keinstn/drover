import 'dart:async';
import 'dart:collection';
import 'dart:ui' show Locale;

import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/agent_info.dart';
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
/// A call that ended for good — [VoiceSession.stop], this cap, an error —
/// begins a fresh conversation and a fresh cap next time it is started. A
/// [VoiceSession.background] does not: the deadline is absolute, so the time
/// spent away is spent, and the [VoiceSession.start] that comes back
/// continues the same call on what is left of it — Restart and returning to
/// the foreground alike.
///
/// Five minutes rather than ten because this cap is what bounds the cost of a
/// call, and cost grows with speech seconds *times* turn count: halving the
/// cap quarters the worst case. A call is meant to be "what is my herd doing"
/// or a message left for an agent, not a working session.
///
/// `voiceTokenLifetimeMs` in `functions/src/index.ts` must stay longer than
/// this, so a minted token outlives the session it was minted for and no
/// window boundary ever falls inside a conversation.
///
/// ponytail: it just ends, with no warning beforehand — the log line and the
/// Restart button are the whole story. Add a countdown only if five minutes
/// turns out to cut real conversations short.
const kVoiceSessionCap = Duration(minutes: 5);

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
      connect: (resumeHandle, sessionId) => TokenVoiceTransport.connect(
        tools: tools,
        languageCode: voiceLanguageCodeFor(locale),
        resumeHandle: resumeHandle,
        // Every mint this transport makes — the first one and each re-mint
        // at a token boundary — carries the conversation's id, so the
        // Function charges the call once. A reconnect that builds a NEW
        // transport gets the same id through [_connect].
        mint: () => mintVoiceTokenFromFunctions(sessionId),
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

  /// System code logged when the conversation carried on after an
  /// interruption — a dropped connection that was resumed, or a [background]
  /// that [start] continued.
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

  /// [error] value when `mintVoiceToken` refused because the account is out
  /// of voice credits.
  static const outOfCredits = 'out_of_credits';

  /// [error] value when `mintVoiceToken` refused because the free campaign
  /// itself is over. Apart from [outOfCredits] because it is not the user's
  /// balance and not theirs to fix, and the screen says so differently.
  static const campaignOver = 'campaign_over';

  /// The [error] value for a failed connect: a refused mint gets its own copy
  /// on screen, everything else renders as itself.
  static String _failure(Object error) => switch (error) {
    VoiceOutOfCredits(campaignOver: true) => campaignOver,
    VoiceOutOfCredits() => outOfCredits,
    _ => '$error',
  };

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

  final Future<VoiceTransport> Function(String? resumeHandle, String sessionId)
  _connect;
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

  /// The end currently running, awaited by [start]. [_teardown] drops
  /// [_active] first but the status stays [VoiceSessionStatus.live] until the
  /// end has released the mic, the socket and the speaker — a start arriving
  /// in that window (leave the screen and come straight back) must wait it
  /// out rather than be swallowed by the "already live" early return.
  Future<void> _ending = Future.value();

  /// What this call has billed for, summed over every transport it used and
  /// read back behind [kVoiceUsageReadout]. Reset by a [start] that begins a
  /// call, so a Restart measures its own — but not by one that resumes a
  /// parked call, which bills on across the gap.
  var _usage = VoiceUsage();

  /// How long this call has actually been connected, summed over its
  /// segments — a parked call resumes into a new one, and the time spent
  /// away is not call time. Cost per minute is read off this line
  /// (`docs/voice-billing.md`), so counting the gap would under-report it.
  var _connected = Duration.zero;

  /// How long this call was actually connected, summed over its segments.
  /// Settled by the time [finished] turns true: [_teardown] folds the last
  /// segment in before the status flips, so the screen's receipt reads a
  /// final number rather than one still ticking.
  Duration get connected => _connected;

  /// When the current segment began; null while nothing is connected.
  DateTime? _segmentStart;

  /// Identifies this conversation to `mintVoiceToken`, which charges the
  /// first mint under an id and lets the re-mints — a token boundary, a
  /// dropped connection — through free. Fresh per [start], so a Restart is a
  /// new call and pays for itself.
  var _sessionId = '';

  /// Latest resumption handle the server offered. While it is set a dropped
  /// connection is resumed instead of ending the session.
  String? _resumeHandle;

  /// Set by [background], cleared by [start], [stop], [_fail] and [dispose]:
  /// the difference between an end that parks the call and one that finishes
  /// it. It is what the cap deadline, the usage totals and the quiet end in
  /// [_endAndSettle] all key on. Paired with [_resumeHandle] by [resumable],
  /// which answers the narrower question of whether the Live *conversation*
  /// can be picked up too.
  bool _suspended = false;
  bool _disposed = false;

  /// Whether this call is over for good, set by the one path that closes a
  /// call out. The status alone cannot answer it: a [background] that parks
  /// the call also lands on [VoiceSessionStatus.ended], and so would a
  /// receipt for a call that is about to carry on. Cleared by the [start]
  /// that begins the next call.
  bool get finished => _finished;
  bool _finished = false;

  /// Armed by [start], cancelled by [_teardown]; survives reconnects because
  /// [_lost] never goes back through [start].
  Timer? _capTimer;

  /// When [kVoiceSessionCap] runs out, fixed at the [start] that began the
  /// call. Every [start] that resumes a parked call re-arms [_capTimer] for
  /// what is left of it, so the time spent away is spent, not given back.
  /// Keyed on the park, never on [resumable]: a call parked before the server
  /// ever offered a handle is still the same call, and a deadline that only
  /// survived a resumable park would hand it a whole fresh cap.
  DateTime? _capDeadline;

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

  /// Whether the next [start] would continue this conversation rather than
  /// begin one: the session was parked by [background] *and* the server had
  /// offered a handle to resume it on.
  bool get resumable => _suspended && _resumeHandle != null;

  /// Whether this is still the same call, parked and inside its cap — which
  /// is the billing question, not [resumable]'s question of whether the Live
  /// *conversation* can be picked up again. [start] keeps [_sessionId] for
  /// any park, handle or none, so continuing one re-mints inside the
  /// server's reuse window and costs nothing; a session thrown away while
  /// this holds buys a second credit for a call already paid for. Once the
  /// cap has passed there is nothing left to continue: the next call is a
  /// new one and pays.
  bool get parked => _suspended && (_capDeadline?.isAfter(_now()) ?? false);

  bool _stale(int generation) => generation != _generation || !_active;

  /// Connects and goes live. Callable again after [stop]; a stopped
  /// session keeps its log and appends to it. While [resumable] it continues
  /// the parked conversation instead of beginning one — same handle, same
  /// usage totals, and only what is left of [kVoiceSessionCap] — whether it
  /// is Restart or re-entering the screen that calls it.
  Future<void> start() async {
    // A disposed session has already released its mic and speaker, and
    // [HerdScreen] can drop one while a pushed [VoiceScreen] still holds the
    // object and acts on its [resumable].
    if (_disposed) return;
    // [_active], not the status: an end still tearing down leaves the status
    // live while it releases the mic, the socket and the speaker.
    if (_active) return;
    // Which is what this waits out — bounded, because [_teardown] bounds
    // every release it awaits. Both come from the same gesture pair —
    // `paused` then `resumed`, or leaving the screen and coming straight
    // back — and a start dropped here would land the user on "Ended".
    await _ending;
    if (_disposed ||
        _active ||
        _status == VoiceSessionStatus.connecting ||
        _status == VoiceSessionStatus.live) {
      return;
    }
    // Two different questions, and only the first one bounds the call: is
    // this the same call (parked, so its cap and its usage carry on), and can
    // the same Live conversation be picked up (which needs a handle, and only
    // decides what [_connect] is given). Both marks are consumed here —
    // one park buys one resume.
    //
    // The raw mark, not the [parked] getter: that one asks whether the park
    // is *still* good, which is the very thing the deadline below works out.
    final wasParked = _suspended;
    final continuing = resumable;
    _suspended = false;
    // A conversation the server is not restoring begins knowing nothing, so
    // what the last one was told about the focus is forgotten with it —
    // left behind it would read as agreement, and the new conversation would
    // never hear which screen is open.
    if (!continuing) _sentFocusPaneId = null;
    final deadline =
        (wasParked ? _capDeadline : null) ?? _now().add(kVoiceSessionCap);
    _capDeadline = deadline;
    if (!deadline.isAfter(_now())) {
      // Came back after the cap ran out while away. Nothing is active, so
      // there is nothing to tear down — but the park left the call open, and
      // this is where it really ends.
      _resumeHandle = null;
      _entries.add(const VoiceEntry(VoiceEntryKind.system, capReachedCode));
      _closeOut();
      return;
    }
    final gen = ++_generation;
    _active = true;
    _finished = false;
    if (!wasParked) {
      _usage = VoiceUsage();
      _connected = Duration.zero;
      // One conversation, one id, however many times it reconnects — and so
      // one debit. Resuming a parked call is the same conversation and keeps
      // its id; a Restart is a new one and pays again.
      //
      // ponytail: a start that mints and then fails to open the socket has
      // paid for nothing, and the retry — a fresh id — pays again. Reusing
      // the id when the last attempt never went live would make that retry
      // free, inside the window the Function already charged for; worth doing
      // if it ever bites, but it is state to carry for a case that costs one
      // credit.
      _sessionId = const Uuid().v4();
    }
    _segmentStart = _now();
    _capTimer?.cancel();
    _capTimer = Timer(deadline.difference(_now()), () {
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
      // Only a resumable park carries the handle: after any other end — the
      // cap, a stop — a handle left behind would silently resume the
      // conversation that end was meant to finish.
      final transport = await _connect(
        continuing ? _resumeHandle : null,
        _sessionId,
      );
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
      // Logged here, not before the connect: the suspension wrote its
      // [endedCode], and only a continuation that actually got back on the
      // wire may claim the conversation carried on. Same line the drop-and-
      // reconnect path uses — to the reader the two are the same event.
      if (continuing) {
        _entries.add(const VoiceEntry(VoiceEntryKind.system, resumedCode));
      }
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
      // _failure maps a refused mint to [outOfCredits] so the screen can say
      // so; everything else keeps its own text. The stale-handle case needs
      // no clearing here — only a resumable park passes the handle at all.
      await _fail(_failure(e));
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
    // The one place a transport is known good, on the first connect and on
    // every resume alike. Anything the model has not been told about the
    // focus goes out here: a hint that fell into the null window this
    // connect closes, or the screen that was already open when the call
    // began.
    _syncFocus();
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
      final transport = await _connect(handle, _sessionId);
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
      await _fail(_failure(e));
    }
  }

  /// Keeps a released transport's totals before it goes: a reconnect builds
  /// a fresh one, and what the call cost is the sum over all of them.
  void _takeUsage(VoiceTransport? transport) {
    if (transport case final VoiceUsageReporter reporter) {
      _usage.absorb(reporter.usage);
    }
  }

  /// Tears everything down and drops the conversation with it — the user's
  /// explicit End, and the only end that throws the conversation away: the
  /// next [start] is a fresh call, on a fresh cap and a fresh usage total,
  /// wherever it is pressed. [background] parks it instead. Safe to call
  /// repeatedly.
  Future<void> stop() async {
    // Off before the end, because [_end] keeps the handle only for a
    // suspension.
    _suspended = false;
    await _end();
  }

  /// Ends the session because the app left the foreground: iOS silently kills
  /// the microphone on backgrounding, so an open mic streaming to a third
  /// party must not survive it. The only end that parks a conversation rather
  /// than dropping it, and the only one the user did not ask for.
  ///
  /// The audio path and the socket go, but the resumption handle survives the
  /// teardown, so [start] continues where this left off for what is left of
  /// [kVoiceSessionCap]. No-op unless the session is currently active: an
  /// observer can fire after the session already ended on its own (a manual
  /// stop, an error, the cap) and must not log a spurious line then — and two
  /// screens observe the lifecycle, so one backgrounding can arrive twice.
  Future<void> background() async {
    if (!_active) return;
    _suspended = true;
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

  /// Which agent's screen the user has open, or null when none is: where
  /// the user actually is, as [focusAgent] and [releaseFocus] report it and
  /// whether or not anything has reached the wire yet.
  AgentInfo? _focusAgent;

  /// The pane the model was last *told* about, written only once a send has
  /// actually gone out. The pair is the whole mechanism: [_syncFocus] speaks
  /// whenever the two disagree and says nothing while they agree, so a hint
  /// that never made it — the socket was gone, the send threw — is not
  /// recorded as delivered and the next connect says it again. Forgotten by
  /// a [start] that opens a conversation the server is not restoring, which
  /// has been told nothing.
  ///
  /// ponytail: "told" is never confirmed, and the live config compacts the
  /// context window by dropping the oldest turns
  /// ([voiceGenerationConfig]), so a focus injected early in a long call can
  /// fall out of the model's context while this still records it as known.
  /// Re-send it periodically if a long call is ever seen forgetting which
  /// screen is open.
  String? _sentFocusPaneId;

  /// Reports that the user is now looking at [agent]'s screen, so an unnamed
  /// agent resolves to the one in front of the user rather than to the most
  /// recent event's — see the `[focus]` bullet in [kVoiceSystemPrompt]. A
  /// pane that already has the focus is a no-op, so the screens may call
  /// this on every build rather than only on a change.
  ///
  /// Reports rather than sends: what goes on the wire is [_syncFocus]'s
  /// business, and it may be nothing (the model already knows) or may happen
  /// later (on the next connect).
  ///
  /// Deliberately logs no [VoiceEntry]: focus is navigation, not
  /// conversation, and a transcript line on every screen change would bury
  /// the conversation it is meant to help.
  void focusAgent(AgentInfo agent) {
    if (_focusAgent?.paneId == agent.paneId) return;
    _focusAgent = agent;
    _syncFocus();
  }

  /// Reports that [paneId]'s screen is gone — unless the focus has already
  /// moved on. The guard is what makes a switch between two agents work: the
  /// bottom bar builds the incoming screen before the outgoing one is
  /// disposed, so the release arrives second and would otherwise undo the
  /// focus the incoming screen just set.
  void releaseFocus(String paneId) {
    if (_focusAgent?.paneId != paneId) return;
    _focusAgent = null;
    _syncFocus();
  }

  /// Tells the model where the user is, unless that is already what it was
  /// told. Queued on [_announcing] behind whatever else is being said and
  /// gated on [_awaitPlaybackEnd] for the same reason [_announce] is: Gemini
  /// Live treats injected text as a barge-in, and a hint sent mid-sentence
  /// cuts the model off.
  ///
  /// Everything is read at send time rather than captured when queued, so
  /// coalescing falls out of the same comparison: a run of switches says
  /// only where the user ended up, and a screen opened and left again while
  /// one hint waits out the playback agrees with what the model was told by
  /// the time the wait ends, so nothing is sent at all — the two cancel
  /// instead of barging in twice to say nothing changed.
  ///
  /// A send that finds no transport — the window a reconnect leaves open —
  /// or that fails leaves [_sentFocusPaneId] alone, which is exactly what
  /// makes [_bind] pick the hint up on the other side of the reconnect.
  void _syncFocus() {
    _announcing = _announcing.then((_) async {
      if (!_active || _focusAgent?.paneId == _sentFocusPaneId) return;
      if (!await _awaitPlaybackEnd()) return;
      final agent = _focusAgent;
      if (agent?.paneId == _sentFocusPaneId) return;
      final transport = _transport;
      if (transport == null) return;
      try {
        await transport.sendText(
          agent == null
              ? "[focus] The user is no longer looking at any agent's screen."
              : '[focus] The user is now looking at '
                    "${voiceAgentTitle(agent)}'s screen.",
        );
      } catch (_) {
        // Swallowed on purpose, and twice over: an error escaping here would
        // reject [_announcing] and silence every announcement behind it, and
        // the unrecorded send is retried by the next [_bind] anyway.
        return;
      }
      _sentFocusPaneId = agent?.paneId;
    });
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
  /// the mic or speaker is still being released. The conversation goes with
  /// it — a stale handle only ever surfaces as a connect failure, so keeping
  /// one would make Restart loop on it. Parked in [_ending] like [_end], so a
  /// start racing this teardown cannot overtake the error it is about to
  /// report.
  Future<void> _fail(String message) => _ending = _failAndSettle(message);

  Future<void> _failAndSettle(String message) async {
    if (!_active) return;
    await _teardown();
    _resumeHandle = null;
    _suspended = false;
    // A call that died still burned tokens, and a cost measurement that drops
    // exactly the calls that went wrong measures the wrong population.
    _appendUsage();
    _setStatus(VoiceSessionStatus.error, error: message);
  }

  /// Logs what this call billed for, once, at whichever end it reached.
  ///
  /// Carries its own text rather than a code: the screen renders an unknown
  /// system code as it stands, and a developer readout is not worth two
  /// locales.
  void _appendUsage() {
    if (!kVoiceUsageReadout) return;
    final line = voiceUsageLine(_usage, _connected);
    _entries.add(VoiceEntry(VoiceEntryKind.system, line));
    debugPrint(line);
  }

  /// Ends the session. The future is parked in [_ending] so a [start] that
  /// arrives mid-teardown waits for it instead of racing it.
  Future<void> _end() => _ending = _endAndSettle();

  Future<void> _endAndSettle() async {
    // The raw mark rather than the [parked] getter: this runs as the call is
    // being put down, and what it needs to know is whether a park asked for
    // it, not whether that park is still worth resuming.
    final wasParked = _suspended;
    await _teardown();
    // After the teardown, not before: a SessionResumptionUpdate already
    // queued on the [_rx] chain can land while it runs and re-arm the handle.
    // A handle must not outlive the conversation it belongs to — left behind
    // by, say, the cap, a later park would stitch the killed conversation
    // back onto the next call.
    if (!wasParked) _resumeHandle = null;
    if (_status == VoiceSessionStatus.ended ||
        _status == VoiceSessionStatus.error) {
      return;
    }
    // A parked call is not over: no "Session ended", no warning about drafts
    // it is about to come back and send, and no usage readout — that lands
    // once, at the end that finishes the call, and covers all of it. The
    // status still flips, because the screen and [start] both key on it.
    if (wasParked) {
      _setStatus(VoiceSessionStatus.ended);
      return;
    }
    _closeOut();
  }

  /// The lines that close a call out: that it ended, any draft left unsent,
  /// and what the whole call billed for.
  void _closeOut() {
    _entries.add(const VoiceEntry(VoiceEntryKind.system, endedCode));
    if (drafts.pending.isNotEmpty) {
      _entries.add(const VoiceEntry(VoiceEntryKind.system, unsentDraftsCode));
    }
    _appendUsage();
    _finished = true;
    _setStatus(VoiceSessionStatus.ended);
  }

  Future<void> _teardown() async {
    if (!_active) return;
    _active = false;
    // Counted here, where the call stopped being connected — not after the
    // releases below, which are awaited and can take seconds.
    final segment = _segmentStart;
    if (segment != null) {
      _connected += _now().difference(segment);
      _segmentStart = null;
    }
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
      await _bounded(_mic.stop());
    } catch (_) {}
    _takeUsage(transport);
    try {
      await _bounded(transport?.close());
    } catch (_) {}
    await _bounded(_speaker.dispose());
  }

  /// How long one release is given before the teardown carries on without it.
  static const _releaseBound = Duration(seconds: 3);

  /// Bounds [work], which is a release that may never complete: `close()` on
  /// a dead socket is documented to hang (see `voice_transport.dart`), and an
  /// end that never finishes strands every later [start] on [_ending] — the
  /// session then reads live forever, the herd screen keeps handing it back,
  /// and the screen wake is never released.
  ///
  /// Not once [dispose] has run: nothing can start a disposed session again,
  /// so a hung release there strands nobody — and dispose's teardown is
  /// fire-and-forget, so the bound's timer would outlive whatever dropped the
  /// session (a widget test fails on exactly that).
  ///
  /// ponytail: what hangs is leaked, not recovered — the mic engine or the
  /// socket stays as it is and the next call builds fresh ones beside it, and
  /// a teardown of three wedged releases takes 9 s before the next start gets
  /// through. A leak beats a session that can never be started again; give it
  /// a real release path if one ever shows up on device. Errors are left to
  /// the caller, as before.
  Future<void> _bounded(Future<void>? work) {
    final release = work ?? Future<void>.value();
    if (_disposed) return release;
    return release.timeout(_releaseBound, onTimeout: () {});
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
    // Over, not parked: a disposed session must not read [resumable] true and
    // invite a [start] onto a mic and speaker it has already released.
    _suspended = false;
    _resumeHandle = null;
    // Set before the end below, not after it: [_bounded] reads it, and the
    // only thing it changes here is that [_teardown] skips zeroing a [_level]
    // this same call is about to dispose.
    _disposed = true;
    unawaited(
      _end().then((_) async {
        await _mic.dispose();
        await _draftsSub?.cancel();
        drafts.dispose();
        _level.dispose();
      }),
    );
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
