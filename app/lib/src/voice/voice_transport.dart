import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Locale;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_ai/firebase_ai.dart';

import 'voice_tools.dart';

/// Gemini Live model named in the client setup frame — and ignored there.
///
/// Every session runs on a minted token, and the token's `fieldMask` freezes
/// `model`, so `voiceModel` in `functions/src/index.ts` is what decides which
/// model the session runs on: a mismatch here changes nothing (measured
/// 2026-09-21, see docs/voice-billing.md). It is still sent — a *wrong* value
/// is what was measured as accepted, an absent one was not — but it no longer
/// has to match anything, and moving the model means editing the Function.
const kVoiceModel = 'gemini-3.8-live';

const kVoiceSystemPrompt = '''
You are the voice concierge for drover, a phone app that manages AI coding
agents running on the user's machine. Answer in the language the user speaks.
Be brief: one or two spoken sentences. Never read out paths, IDs or code.
When asked about agents or their state, call list_agents and summarise: how
many agents there are, which are blocked (waiting for the user), which are
working, which are idle. Refer to agents by title or kind, never by id.
You can also relay messages to agents. Think of it as voicemail: the agent is busy, you leave it a message, and it calls back when it is done.
- To send a message: call draft_message with the agent and the message in the user's own words and language. Then read the returned message back to the user word for word and ask for confirmation. After an explicit yes, call send_message with the draft_id. A message is sent ONLY when send_message returns sent: true — never say it was sent otherwise; if you have not called send_message yet, say so and ask again. After a successful send, say it was sent and that you will announce when the agent finishes.
- Messages from the app arrive as text that starts with "[event]". Announce each one immediately and briefly in the user's language, then wait for the user. When an event carries questions with numbered options, read each question and its options with their numbers and ask the user for one answer per question, in order; then call answer_question ONCE with an answers entry per question, holding the chosen option numbers, or text when the user answers freely.
- Messages that start with "[focus]" say which agent's screen the user has open right now. They are context, not something to react to: never read one out and never answer it. When the user does not name an agent, that is the agent they mean.
- If the user does not name an agent and no agent screen is open, use the agent from the most recent event, or the one most recently discussed. If that is unclear, ask; never guess.
- Never invent what an agent said. Use read_agent when asked what an agent replied.
- To start a NEW agent on a project: write the task as a brief for a coding agent, in the user's language — what to do, in which project, with any constraints the user gave. Call draft_launch with the project folder name, the brief, and the agent kind if the user named one (otherwise it defaults to claude). Then say in ONE sentence what the brief asks for and that the full text is on screen, and ask for confirmation. After an explicit yes, call launch with the draft_id. An agent is started ONLY when launch returns launched: true — never say it was started otherwise. Afterwards say it is running and will call back when it is done. If launch returns brief_delivered: false, say the agent started but did not receive the brief, and offer to send it with draft_message.
''';

/// BCP-47 speech language for the app locale: Japanese speaks ja-JP,
/// everything else en-US (the two locales the app ships).
String voiceLanguageCodeFor(Locale? locale) =>
    locale?.languageCode == 'ja' ? 'ja-JP' : 'en-US';

/// The wire to the voice model, narrowed to what [VoiceSession] needs so
/// tests can drive it with a fake.
abstract interface class VoiceTransport {
  Stream<LiveServerResponse> receive();
  Future<void> sendAudio(Uint8List pcm16k);
  Future<void> sendText(String text);
  Future<void> sendToolResponse(List<FunctionResponse> responses);
  Future<void> close();
}

/// The live generation config the transport connects with. Only
/// `responseModalities` is frozen server side by the minted token; the rest
/// is the client's.
LiveGenerationConfig voiceGenerationConfig(String languageCode) =>
    LiveGenerationConfig(
      responseModalities: [ResponseModalities.audio],
      speechConfig: SpeechConfig(
        voiceName: 'Aoede',
        languageCode: languageCode,
      ),
      inputAudioTranscription: AudioTranscriptionConfig(),
      outputAudioTranscription: AudioTranscriptionConfig(),
      // Keeps the conversation inside the model's context window across a
      // resumed connection by dropping the oldest turns. Without both numbers
      // the mechanism never fires, so the prompt grows every turn and the
      // session pays the quadratic described in docs/voice-billing.md.
      //
      // 5,000 sits above where an ordinary call ends — six to eight turns
      // never reach it, so nothing about a normal conversation changes — and
      // a dense call is clipped there instead of paying for all of its audio
      // again on every later turn. 3,000 is what survives a clip, and it has
      // to stay comfortably above the per-turn floor: the system prompt and
      // the tool declarations cannot be compressed away, so a target below
      // the floor drops the conversation outright rather than trimming it.
      // drover's floor is around 1,800 tokens (measured 2026-09-21), leaving
      // roughly 1,200 tokens of actual conversation — the last few turns,
      // which is what `draft_message` → confirm → `send_message` needs to
      // still see. The floor grows with the system prompt and the tool
      // declarations, so that margin shrinks as those grow; raise
      // `targetTokens` with them.
      contextWindowCompression: ContextWindowCompressionConfig(
        triggerTokens: 5000,
        slidingWindow: SlidingWindow(targetTokens: 3000),
      ),
    );

// --------------------------------------------------------------- minted token

/// What one call billed for, summed over its turns.
///
/// The Live server reports `usageMetadata` on each `turnComplete` frame and
/// `firebase_ai` 4.0.0 drops it (see `docs/voice-billing.md`), so only a raw
/// socket can fill this in: [TokenVoiceTransport] does, and [VoiceSession]
/// adds up the transports one call used.
///
/// Counted, never shown. The developer readout that used to render these
/// totals as a transcript line is gone — the session receipt answers "what
/// did that cost" in credits, which is the question a user actually has, and
/// a raw token count above it was redundant as well as unshippable. The
/// accounting stays because it is how the next meter would be built and it
/// is the only thing on the device that can price a call in tokens; nothing
/// in the app reads it today. Nothing leaves the device either way, which is
/// what keeps drover's App Privacy declaration ("Usage data: No") true.
class VoiceUsage {
  /// Frames that carried usage: one per model turn.
  ///
  /// ponytail: the server puts usage on the `turnComplete` frame, so the two
  /// are counted as one. If it ever reports usage on its own frame, this
  /// drifts from the turn count and wants counting separately.
  var turns = 0;
  var promptTokens = 0;
  var responseTokens = 0;

  /// Modality ('TEXT', 'AUDIO', ...) -> tokens. Kept apart because the
  /// modalities are priced apart, and accumulated context is re-billed at the
  /// modality it arrived in — the reason this readout is worth reading.
  final promptByModality = <String, int>{};
  final responseByModality = <String, int>{};

  /// Folds one frame's `usageMetadata` in. Every field is read defensively
  /// and a value that is not the number it should be counts as nothing: a
  /// statistic must not cost a conversation.
  void add(Object? metadata) {
    if (metadata is! Map) return;
    turns++;
    promptTokens += _count(metadata['promptTokenCount']);
    responseTokens += _count(metadata['responseTokenCount']);
    _details(promptByModality, metadata['promptTokensDetails']);
    _details(responseByModality, metadata['responseTokensDetails']);
  }

  /// Takes over [other]'s totals, which is how a call that reconnected onto a
  /// second transport still reports one number.
  void absorb(VoiceUsage other) {
    turns += other.turns;
    promptTokens += other.promptTokens;
    responseTokens += other.responseTokens;
    _merge(promptByModality, other.promptByModality);
    _merge(responseByModality, other.responseByModality);
  }

  // isFinite as well as num: JSON is happy to carry 1e400, `jsonDecode`
  // hands that back as `double.infinity`, and `infinity.toInt()` throws.
  static int _count(Object? value) =>
      value is num && value.isFinite ? value.toInt() : 0;

  static void _merge(Map<String, int> into, Map<String, int> from) {
    from.forEach((key, value) => into[key] = (into[key] ?? 0) + value);
  }

  static void _details(Map<String, int> into, Object? details) {
    if (details is! List) return;
    for (final detail in details) {
      if (detail is! Map) continue;
      if (detail['modality'] case final String modality) {
        into[modality] = (into[modality] ?? 0) + _count(detail['tokenCount']);
      }
    }
  }
}

/// A transport that counts what it billed for.
///
/// Apart from [VoiceTransport] because only the raw socket sees
/// `usageMetadata`; the Firebase transport has nothing to report.
abstract interface class VoiceUsageReporter {
  VoiceUsage get usage;
}

/// The RPC an ephemeral token connects to.
///
/// NOT the documented `BidiGenerateContent`: every documented way of
/// presenting a minted token to that RPC is rejected with 1008, and the token
/// belongs on `BidiGenerateContentConstrained` as `?access_token=`
/// (measured 2026-09-18, `app/tool/token_probe.dart`).
const kVoiceLiveEndpoint =
    'wss://generativelanguage.googleapis.com/ws/'
    'google.ai.generativelanguage.v1beta.GenerativeService'
    '.BidiGenerateContentConstrained';

/// How far ahead of [VoiceToken.expiresAt] the next token is minted, so the
/// socket can be reopened the instant the server closes the expired one.
const kVoiceTokenMintLead = Duration(seconds: 15);

/// A minted Live API token and the instant the server stops honouring it.
class VoiceToken {
  const VoiceToken({required this.token, required this.expiresAt});

  /// The token's resource name, which is what `?access_token=` carries. A
  /// bearer credential: never log it.
  final String token;

  /// When the session is closed with 1011 "auth token has expired" and the
  /// token stops opening new ones.
  final DateTime expiresAt;
}

/// Removes a minted token from [text], which is on its way to a log, an error
/// string or the voice transcript.
///
/// `dart:io` puts the entire request URI into a [WebSocketException]'s
/// message, and the token rides in that URI's query string — so the failure
/// path that fires when a token expires or is refused, which this design
/// walks routinely, is exactly the one that would write a live credential
/// into the device log. The query parameter is scrubbed as well as the token
/// itself, in case the text carries a URI this caller did not mint.
String scrubVoiceToken(String text, String token) => text
    .replaceAll(token, '<token>')
    .replaceAll(RegExp(r'access_token=[^&\s,)"]+'), 'access_token=<token>');

/// Mints one token. Production calls the Cloud Function; the live check under
/// `app/tool/` mints straight from the Gemini API with a key, which is why
/// this is injectable at all.
typedef VoiceTokenMinter = Future<VoiceToken> Function();

/// `mintVoiceToken` refused because there is no credit to spend.
///
/// Its own class rather than the raw [FirebaseFunctionsException] so
/// [VoiceSession] can render its own copy for it without knowing a thing
/// about Cloud Functions.
class VoiceOutOfCredits implements Exception {
  const VoiceOutOfCredits({this.campaignOver = false});

  /// Whether the whole free campaign is spent or switched off, rather than
  /// this account's balance being empty. The two share a code and a status
  /// but not a meaning: the campaign ending is nothing the user did and
  /// nothing they can undo, so the screen must not ask them to act on it.
  final bool campaignOver;

  @override
  String toString() =>
      campaignOver ? 'VoiceOutOfCredits(campaignOver)' : 'VoiceOutOfCredits';
}

/// Asks `mintVoiceToken` for a token. Firebase Auth and App Check are carried
/// and verified by the callable itself.
///
/// [sessionId] is the conversation this mint belongs to, and every re-mint of
/// the same conversation repeats it: the Function charges the first mint under
/// an id and lets the rest through free, so a reconnect is not a second call.
Future<VoiceToken> mintVoiceTokenFromFunctions(String sessionId) async {
  try {
    final result = await FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('mintVoiceToken')
        .call<Map<String, Object?>>({'sessionId': sessionId});
    return VoiceToken(
      token: result.data['token']! as String,
      expiresAt: DateTime.parse(result.data['expireTime']! as String),
    );
  } on FirebaseFunctionsException catch (e) {
    if (e.code == 'resource-exhausted') {
      // `details` is whatever the Function attached, so it is read
      // defensively: a refusal that arrives without a reason is still a
      // refusal, and the account's own empty balance is the safer of the
      // two to assume — it is the one the user can do something about.
      final details = e.details;
      throw VoiceOutOfCredits(
        campaignOver: details is Map && details['reason'] == 'campaignOver',
      );
    }
    rethrow;
  }
}

/// [VoiceTransport] over a raw Live WebSocket opened with a minted token.
///
/// Speaks the wire protocol directly and hands [VoiceSession] ordinary
/// `firebase_ai` types, so nothing above it deals with the raw socket.
///
/// The token's expiry — not the server's own connection cap — is what ends
/// these connections, and it is expected rather than exceptional: the next
/// token is minted [kVoiceTokenMintLead] ahead, and when the socket closes at
/// expiry the transport reopens it on the stored resumption handle
/// *underneath* [receive], which never closes. The session above therefore
/// sees no drop at all: nothing is logged, and the one reconnect
/// `VoiceSession._lost` allows a genuine drop is left unspent. Any other
/// close ends the stream, exactly as before.
class TokenVoiceTransport implements VoiceTransport, VoiceUsageReporter {
  TokenVoiceTransport._(this._mint, this._setup, this._endpoint);

  static const _handshakeTimeout = Duration(seconds: 30);

  /// Opens a session on a freshly minted token.
  ///
  /// [mint] mints every token this transport uses, including the ones it
  /// reopens with at a window boundary; production passes a closure over the
  /// conversation's session id (see [VoiceSession.forHerd]), which is what
  /// keeps one conversation to one debit. [endpoint] and [onRawFrame] are
  /// seams for the live check under `app/tool/` and for tests; nothing in the
  /// app passes them. [onRawFrame] sees every server frame as it arrived,
  /// which is where the test fixtures come from.
  static Future<TokenVoiceTransport> connect({
    required List<VoiceTool> tools,
    required String languageCode,
    required VoiceTokenMinter mint,
    String? resumeHandle,
    String endpoint = kVoiceLiveEndpoint,
    void Function(String frame)? onRawFrame,
  }) async {
    final config = voiceGenerationConfig(languageCode);
    final firebaseTools = [voiceToolsToFirebase(tools)];
    // The same setup `LiveSession` sends, bar the Firebase model path. Only
    // `model` and `generationConfig.responseModalities` are frozen by the
    // token, so the prompt, tools, speech config, transcription and
    // compression below are all still the client's to send.
    Map<String, Object?> setup(String? handle) => {
      'model': 'models/$kVoiceModel',
      'system_instruction': Content.text(kVoiceSystemPrompt).toJson(),
      'tools': firebaseTools.map((t) => t.toJson()).toList(),
      'session_resumption': handle == null
          ? <String, Object?>{}
          : {'handle': handle},
      'generation_config': config.toJson(),
      'input_audio_transcription': <String, Object?>{},
      'output_audio_transcription': <String, Object?>{},
      'contextWindowCompression': config.contextWindowCompression!.toJson(),
    };
    final transport = TokenVoiceTransport._(mint, setup, endpoint)
      .._onRawFrame = onRawFrame
      // Seeded, not waited for: without it the first window of a transport
      // built by `VoiceSession._lost` has no handle of its own, so a token
      // expiry arriving before the server's first update would end the
      // session instead of crossing invisibly.
      .._handle = resumeHandle;
    await transport._open(resumeHandle);
    return transport;
  }

  final VoiceTokenMinter _mint;
  final Map<String, Object?> Function(String? handle) _setup;
  final String _endpoint;
  void Function(String frame)? _onRawFrame;

  /// Survives every reconnect: closing it is what tells the session the
  /// conversation is over.
  final _out = StreamController<LiveServerResponse>();

  WebSocket? _socket;

  /// Latest handle the server offered, tracked here as well as in the session
  /// because the expiry reconnect happens behind the session's back.
  String? _handle;

  /// Minted ahead of the boundary by [_mintTimer], spent by the next [_open].
  VoiceToken? _nextToken;
  Timer? _mintTimer;
  var _closed = false;

  /// What this transport has billed for so far, across every window it
  /// reopened on its own.
  @override
  final usage = VoiceUsage();

  /// Server frames seen on the current socket. A window that ends after
  /// carrying nothing is not a window boundary, whatever it closes with, and
  /// resuming it would be a mint-and-reconnect loop against a token the
  /// server refuses on sight.
  var _framesThisWindow = 0;

  /// Opens one window. Everything that can throw is inside the try, because
  /// every error out of here is scrubbed before it leaves: `dart:io` puts the
  /// whole request URI — token and all — into a [WebSocketException], and
  /// [VoiceSession] renders what it catches into the on-screen transcript.
  Future<void> _open(String? handle) async {
    final token = _nextToken ?? await _mint();
    _nextToken = null;
    WebSocket? socket;
    try {
      final opened = await WebSocket.connect(
        '$_endpoint?access_token=${token.token}',
      );
      socket = opened;
      final ready = Completer<void>();
      opened.listen(
        (frame) => _onFrame(frame, ready),
        onDone: () => _onDone(opened, ready),
        onError: (Object e) {
          if (!ready.isCompleted) {
            ready.completeError(e);
            return;
          }
          // After the handshake there is nobody left to hand a socket error
          // to but the session, and a hard transport failure must not reach
          // it as an ordinary end of conversation. Same as firebase_ai's own
          // session: add the error, then let it close. Scrubbed like every
          // other way out of here — whether a given `dart:io` error type
          // happens to carry the request URI is not a thing the code on the
          // other side of this stream should have to know.
          if (_out.isClosed) return;
          _out.addError(StateError(scrubVoiceToken('$e', token.token)));
          unawaited(_out.close());
        },
      );
      opened.add(jsonEncode({'setup': _setup(handle)}));
      await ready.future.timeout(_handshakeTimeout);
      // A close that landed while this window was opening: the session is
      // gone and this socket must not outlive it. Thrown rather than
      // returned, so neither `connect` nor `_reopen` is handed a transport
      // with no socket under it.
      if (_closed) {
        await opened.close().catchError((Object _) {});
        throw StateError('closed while connecting');
      }
      _socket = opened;
      _framesThisWindow = 0;
      _armMint(token);
    } catch (e) {
      await socket?.close().catchError((Object _) {});
      throw StateError(scrubVoiceToken('$e', token.token));
    }
  }

  /// Mints the next token shortly before this one expires, so the reconnect
  /// at the boundary costs a socket and not a round trip to the Function. A
  /// failure is swallowed: [_open] mints on demand.
  void _armMint(VoiceToken token) {
    _mintTimer?.cancel();
    final ahead =
        token.expiresAt.difference(DateTime.now()) - kVoiceTokenMintLead;
    _mintTimer = Timer(ahead.isNegative ? Duration.zero : ahead, () async {
      try {
        _nextToken = await _mint();
      } catch (_) {}
    });
  }

  void _onFrame(Object? frame, Completer<void> ready) {
    try {
      _readFrame(frame, ready);
    } catch (e) {
      // The boundary firebase_ai's own session keeps: a frame that will not
      // parse becomes a stream error the session can fail on, rather than an
      // unhandled zone error that leaves it wedged and silent.
      if (!ready.isCompleted) {
        ready.completeError(e);
      } else if (!_out.isClosed) {
        _out.addError(e);
      }
    }
  }

  void _readFrame(Object? frame, Completer<void> ready) {
    final text = frame is String ? frame : utf8.decode(frame! as List<int>);
    _onRawFrame?.call(text);
    final json = jsonDecode(text) as Map<String, Object?>;
    // LiveServerSetupComplete is not exported by firebase_ai and the session
    // has nothing to do with it, so it is swallowed here and only opens the
    // handshake gate.
    if (json.containsKey('setupComplete')) {
      if (!ready.isCompleted) ready.complete();
      return;
    }
    // A top-level sibling of `serverContent`, and read inside a guard of its
    // own as well as [VoiceUsage.add]'s: whatever the server puts here,
    // counting it must not turn into a stream error that ends the call.
    try {
      usage.add(json['usageMetadata']);
    } catch (_) {}
    // After the mapping, so an error frame — which throws — is not counted as
    // a window that carried something.
    final message = voiceServerMessage(json);
    _framesThisWindow++;
    if (message == null || _out.isClosed) return;
    if (message is SessionResumptionUpdate &&
        message.resumable == true &&
        (message.newHandle ?? '').isNotEmpty) {
      _handle = message.newHandle;
    }
    _out.add(LiveServerResponse(message: message));
  }

  void _onDone(WebSocket socket, Completer<void> ready) {
    if (!ready.isCompleted) {
      ready.completeError(
        StateError(
          'live socket closed before setup: '
          '${socket.closeCode} ${socket.closeReason}',
        ),
      );
      return;
    }
    if (!identical(socket, _socket) || _closed || _out.isClosed) return;
    _socket = null;
    // The window ended. Expected, so it stays invisible to the session — but
    // only with a handle to resume on: without one there is no conversation
    // to carry over, and ending is honest.
    //
    // ponytail: matched on the close the server actually sends. A different
    // wording falls through to the ordinary drop path, which reconnects once
    // on the session's own handle — one spent budget, not a broken session.
    // And the reconnect itself is uncapped: a server that kept handing out
    // already-expiring tokens would mint and reopen in a loop, bounded only
    // by [kVoiceSessionCap]. Add a backoff if that ever happens; a counter
    // for a case that means the mint's clock is broken would be guesswork.
    if (_handle != null &&
        _framesThisWindow > 0 &&
        socket.closeCode == 1011 &&
        (socket.closeReason ?? '').toLowerCase().contains('expire')) {
      unawaited(_reopen());
      return;
    }
    unawaited(_out.close());
  }

  Future<void> _reopen() async {
    try {
      await _open(_handle);
    } catch (e) {
      // Reconnecting under the session failed; hand the drop up so it takes
      // its ordinary one reconnect, and ends if that fails too.
      if (_out.isClosed) return;
      _out.addError(e);
      unawaited(_out.close());
    }
  }

  /// Sends one client frame, or drops it if the socket is between windows.
  ///
  /// ponytail: a tool response that lands in that gap is lost and the model
  /// waits for it. The gap is one socket setup wide; buffer if it bites.
  Future<void> _send(Map<String, Object?> frame) async =>
      _socket?.add(jsonEncode(frame));

  @override
  Stream<LiveServerResponse> receive() => _out.stream;

  @override
  Future<void> sendAudio(Uint8List pcm16k) => _send({
    'realtime_input': {
      'audio': {
        'mimeType': 'audio/pcm;rate=16000',
        'data': base64Encode(pcm16k),
      },
    },
  });

  @override
  Future<void> sendText(String text) => _send({
    'realtime_input': {'text': text},
  });

  @override
  Future<void> sendToolResponse(List<FunctionResponse> responses) => _send({
    'toolResponse': {
      'functionResponses': [
        for (final r in responses)
          {
            'name': r.name,
            'response': r.response,
            if (r.id != null) 'id': r.id,
          },
      ],
    },
  });

  @override
  Future<void> close() async {
    _closed = true;
    _mintTimer?.cancel();
    final socket = _socket;
    _socket = null;
    await socket?.close().catchError((Object _) {});
    // Not awaited: the session cancels its subscription before closing the
    // transport, and closing a single-subscription controller nobody listens
    // to hands back a future that never completes.
    if (!_out.isClosed) unawaited(_out.close());
  }
}

/// Maps one decoded Live server frame onto the `firebase_ai` message the
/// session consumes, or null for a frame it has nothing to do with.
///
/// A re-implementation of the package's own `parseServerResponse`, which is
/// not exported; the types and their constructors are. Only the frames
/// [VoiceSession] acts on are mapped.
LiveServerMessage? voiceServerMessage(Map<String, Object?> json) {
  // Thrown rather than returned, exactly as the package's parser does: the
  // server reporting an error has to reach the session, or it sits with an
  // open microphone waiting for a turn that will never come.
  if (json['error'] case final Object error) {
    throw StateError('live server error: ${jsonEncode(error)}');
  }
  if (json['serverContent'] case final Map<String, Object?> content) {
    return LiveServerContent(
      modelTurn: switch (content['modelTurn']) {
        final Map<String, Object?> turn => Content(turn['role'] as String?, [
          for (final part in turn['parts'] as List<Object?>? ?? const [])
            ?_voicePart(part! as Map<String, Object?>),
        ]),
        _ => null,
      },
      turnComplete: content['turnComplete'] as bool?,
      interrupted: content['interrupted'] as bool?,
      inputTranscription: _voiceTranscription(content['inputTranscription']),
      outputTranscription: _voiceTranscription(content['outputTranscription']),
    );
  }
  if (json['toolCall'] case final Map<String, Object?> call) {
    return LiveServerToolCall(
      functionCalls: [
        for (final c in call['functionCalls'] as List<Object?>? ?? const [])
          FunctionCall(
            (c! as Map<String, Object?>)['name']! as String,
            ((c as Map<String, Object?>)['args'] as Map<String, Object?>?) ??
                const {},
            id: c['id'] as String?,
          ),
      ],
    );
  }
  if (json['goAway'] case final Map<String, Object?> goAway) {
    return GoingAwayNotice(timeLeft: goAway['timeLeft'] as String?);
  }
  if (json['sessionResumptionUpdate'] case final Map<String, Object?> update) {
    return SessionResumptionUpdate(
      newHandle: update['newHandle'] as String?,
      resumable: update['resumable'] as bool?,
      lastConsumedClientMessageIndex:
          update['lastConsumedClientMessageIndex'] as int?,
    );
  }
  return null;
}

Part? _voicePart(Map<String, Object?> part) {
  if (part['inlineData'] case final Map<String, Object?> data) {
    return InlineDataPart(
      data['mimeType']! as String,
      base64Decode(data['data']! as String),
    );
  }
  if (part['text'] case final String text) return TextPart(text);
  return null;
}

Transcription? _voiceTranscription(Object? json) => switch (json) {
  final Map<String, Object?> t => Transcription(
    text: t['text'] as String?,
    finished: t['finished'] as bool?,
  ),
  _ => null,
};
