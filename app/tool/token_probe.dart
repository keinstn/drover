// Probe: can ephemeral Live API tokens carry drover's paid path?
//
// Sibling of `live_probe.dart` (same raw Live WebSocket, same StreamQueue),
// but the question is billing enforcement rather than price. If a Cloud
// Function can check a wallet and mint a short-lived token, we never need a
// relay in the audio path. Three things decide it, and the docs answer none:
//
//   Q1  what does `uses` count — session starts, or messages?
//   Q2  does session resumption survive an ephemeral token? (drover
//       reconnects on a resumption handle; a paid path that breaks that is
//       worse than no paid path)
//   Q3  does the minting side learn anything about usage?
//   Q4  does the token's model/config lock actually bind?
//
// Q1 answered its own question and raised a sharper one: `uses` turned out to
// bound only the first unhandled connect, leaving `expireTime` as the only
// real bound — which Q1 had deliberately set far away so it could not
// confound anything. So the bound itself was never measured:
//
//   E5  does `expireTime` end a session already in flight?
//   E6  does a resumption chain outlive `expireTime`?
//
// Together they decide whether a mint can serve as a metering tick.
//
// Usage:
//   GEMINI_API_KEY=$(cat <key file>) fvm dart run tool/token_probe.dart
//       [auth|q1|q2|q3|q4|e5|e6|all]
//
// `all` runs the experiments but not `auth`, which is the connection-form
// matrix and only worth running if the recipe below stops working.
//
// Two things about this endpoint are in no version of the prose docs and
// cost an hour to find, so they are recorded here:
//
//   * an ephemeral token does NOT go to `BidiGenerateContent`. It goes to
//     `BidiGenerateContentConstrained`, with `?access_token=<token name>`.
//     Everything the docs suggest — `access_token` on the plain RPC,
//     `Authorization: Token`, the token as an API key — is rejected; run
//     the `auth` sub-command to see the whole matrix.
//   * the mint field the docs call `liveConnectConstraints` is the *SDK*
//     name. Over REST it is `bidiGenerateContentSetup` plus a `fieldMask`
//     naming the frozen fields; `liveConnectConstraints` is a 400.
//
// Live model names move faster than this file does — Q4's `other` may have
// gone stale by the time it runs. `mint()` prints the response body on every
// mint regardless of status, so a bad name shows up immediately as a mint
// failure rather than a silent no-op.
//
// The key is read from the environment only — never a file, never an argument
// (arguments show up in `ps`). Minted tokens and resumption handles are
// credentials too, so only a short prefix of one is ever printed, and every
// error goes through `_scrub` because a failed handshake would otherwise put
// the whole request URI — query string included — into the log.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _model = 'models/gemini-3.1-flash-live-preview';
const _host = 'generativelanguage.googleapis.com';

late final String _key;

void main(List<String> args) async {
  final key = Platform.environment['GEMINI_API_KEY'];
  if (key == null || key.isEmpty) {
    stderr.writeln('set GEMINI_API_KEY (see the header of this file)');
    exit(2);
  }
  _key = key;
  final what = args.isEmpty ? 'all' : args.first;
  final run = {
    'auth': _auth,
    'q1': _q1,
    'q2': _q2,
    'q3': _q3,
    'q4': _q4,
    'e5': _e5,
    'e6': _e6,
  };
  if (what != 'all' && !run.containsKey(what)) {
    stderr.writeln('unknown: $what — one of ${run.keys.join('|')}, or all');
    exit(2);
  }
  for (final name in run.keys) {
    if (what == 'all' ? name == 'auth' : what != name) continue;
    _rule(name);
    try {
      await run[name]!();
    } catch (e, s) {
      say('!! $name aborted: ${_scrub(e)}');
      say(_scrub(s));
    }
  }
  exit(0);
}

void say(String line) => stdout.writeln(line);
void _rule(String title) => say('\n${'=' * 70}\n== $title\n${'=' * 70}');

/// Tokens are credentials. Enough to tell two of them apart, no more.
String _tag(String token) =>
    token.length <= 20 ? token : '${token.substring(0, 20)}…';

/// Both the API key and a minted token travel in a query string, and
/// `dart:io` puts the whole request URI into a `WebSocketException` message —
/// so printing a caught error verbatim prints the credential. Everything that
/// reports an error goes through here.
String _scrub(Object thing) => thing.toString().replaceAllMapped(
  RegExp(r"(key|access_token)=[^&\s']*"),
  (match) => '${match[1]}=<redacted>',
);

String _iso(Duration ahead) =>
    '${DateTime.now().toUtc().add(ahead).toIso8601String().split('.').first}Z';

// ---------------------------------------------------------------- minting

/// POST /v1beta/auth_tokens. Prints the request body and the response
/// verbatim (bar the token itself) — the response shape is not in the docs.
Future<String?> mint(
  Map<String, Object?> body, {
  String? label,
  String version = 'v1alpha',
}) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('https://$_host/$version/auth_tokens'),
    );
    request.headers
      ..set('x-goog-api-key', _key)
      ..contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    say('POST /$version/auth_tokens ${label ?? ''}');
    say('  request : ${jsonEncode(body)}');
    say('  HTTP ${response.statusCode}');
    say('  response: ${_redact(text)}');
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(text) as Map<String, Object?>;
    final name = decoded['name'] as String?;
    if (name == null) {
      say('  !! no "name" in the response — cannot use this token');
      return null;
    }
    say('  token   : ${_tag(name)} (${name.length} chars)');
    return name;
  } finally {
    client.close();
  }
}

String _redact(String body) {
  try {
    final map = jsonDecode(body) as Map<String, Object?>;
    final name = map['name'];
    if (name is String) map['name'] = '${_tag(name)} <redacted>';
    return jsonEncode(map);
  } catch (_) {
    return body;
  }
}

/// A plain GET, for the Q3 question of whether the token resource is even
/// addressable after minting.
Future<void> get(String path) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse('https://$_host$path'));
    request.headers.set('x-goog-api-key', _key);
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    say('GET ${path.length > 40 ? '${path.substring(0, 40)}…' : path}');
    say('  HTTP ${response.statusCode}');
    say('  ${_scrub(_redact(text.replaceAll('\n', ' ')))}');
  } catch (e) {
    say(
      'GET ${path.length > 40 ? '${path.substring(0, 40)}…' : path} '
      'threw: ${_scrub(e)}',
    );
  } finally {
    client.close();
  }
}

// ------------------------------------------------------------- connecting

/// One Live session, opened either with an ephemeral token
/// (`?access_token=`) or with the raw API key (`?key=`).
class Live {
  Live._(this._ws, this._inbox);

  final WebSocket _ws;
  final StreamQueue<Map<String, Object?>> _inbox;
  String? handle;
  int? closeCode;
  String? closeReason;

  /// When the server hung up. E5 needs the moment, not just the code.
  DateTime? closedAt;

  /// Returns null when the connection was refused; the refusal is printed
  /// either way, which is the whole point of the exercise.
  static Future<Live?> open({
    String? token,
    bool useKey = false,
    String model = _model,
    Object? sessionResumption,
    String modality = 'AUDIO',
  }) async {
    if (useKey) {
      return _attempt('key', null, model, sessionResumption, modality);
    }
    return _attempt('token', token, model, sessionResumption, modality);
  }

  static Future<Live?> _attempt(
    String style,
    String? token,
    String model,
    Object? sessionResumption,
    String modality,
  ) async {
    // An ephemeral token goes to a different RPC than an API key — see the
    // `auth` sub-command for how that was established.
    final url = style == 'key'
        ? 'wss://$_host/ws/google.ai.generativelanguage.v1beta'
              '.GenerativeService.BidiGenerateContent?key=$_key'
        : 'wss://$_host/ws/google.ai.generativelanguage.v1beta'
              '.GenerativeService.BidiGenerateContentConstrained'
              '?access_token=$token';
    WebSocket ws;
    try {
      ws = await WebSocket.connect(url).timeout(const Duration(seconds: 30));
    } catch (e) {
      say('  <- [$style] handshake refused: ${_scrub(e)}');
      return null;
    }
    final messages = StreamController<Map<String, Object?>>();
    final inbox = StreamQueue(messages.stream);
    final live = Live._(ws, inbox);
    var code = -1;
    String? reason;
    ws.listen(
      (frame) => messages.add(
        jsonDecode(frame is String ? frame : utf8.decode(frame as List<int>))
            as Map<String, Object?>,
      ),
      onDone: () {
        code = ws.closeCode ?? -1;
        reason = ws.closeReason;
        // Kept on the session too, so a socket that dies *mid-turn* (which is
        // exactly what E5 is looking for) can still be reported.
        live
          ..closeCode = code
          ..closeReason = reason
          ..closedAt = DateTime.now().toUtc();
        messages.close();
      },
      onError: messages.addError,
    );

    final setup = <String, Object?>{
      'model': model,
      'generationConfig': {
        'responseModalities': [modality],
      },
      // This model only answers in audio, and Q2 needs the *content* of the
      // answer (did the resumed session still know the planted word?), so
      // ask for a transcript of what it said.
      'outputAudioTranscription': <String, Object?>{},
      'sessionResumption': ?sessionResumption,
    };
    // A resumption handle is bearer-ish too — print enough to tell two apart.
    say(
      '  -> [$style] setup '
      '${jsonEncode(setup).replaceAllMapped(RegExp(r'"handle":"([^"]{12})[^"]*"'), (m) => '"handle":"${m[1]}… <redacted>"')}',
    );
    ws.add(jsonEncode({'setup': setup}));

    try {
      final first = await inbox.next.timeout(const Duration(seconds: 30));
      if (!first.containsKey('setupComplete')) {
        say(
          '  <- [$style] first frame was not setupComplete: '
          '${jsonEncode(first)}',
        );
        await live.close();
        return null;
      }
      say('  <- [$style] setupComplete ${jsonEncode(first)}');
      return live;
    } catch (e) {
      // The socket closing before setupComplete is the interesting failure:
      // the close code and reason are the evidence.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      live
        ..closeCode = code
        ..closeReason = reason;
      say('  <- [$style] no setupComplete ($e); close $code "${reason ?? ''}"');
      await inbox.cancel();
      return null;
    }
  }

  /// One text turn. Returns the model's text, and dumps every usageMetadata
  /// and sessionResumptionUpdate it sees on the way.
  Future<String> turn(
    String prompt, {
    Duration wait = const Duration(seconds: 60),
  }) async {
    say('  -> "$prompt"');
    _ws.add(
      jsonEncode({
        'clientContent': {
          'turns': [
            {
              'role': 'user',
              'parts': [
                {'text': prompt},
              ],
            },
          ],
          'turnComplete': true,
        },
      }),
    );
    final buffer = StringBuffer();
    var done = false;
    while (!done) {
      final message = await _inbox.next.timeout(wait);
      final usage = message['usageMetadata'];
      if (usage != null) say('  <- usageMetadata ${jsonEncode(usage)}');
      // Which model actually answered — not documented on this path, so
      // print it if present rather than assume the field name. Q4 is what
      // this exists for; the setupComplete frame already prints raw, so a
      // model identifier arriving on that frame instead needs no extra code.
      final version = message['modelVersion'];
      if (version != null) say('  <- modelVersion $version');
      final update =
          message['sessionResumptionUpdate'] as Map<String, Object?>?;
      if (update != null) {
        say('  <- sessionResumptionUpdate ${_redactHandle(update)}');
        final fresh = update['newHandle'] as String?;
        if (fresh != null && fresh.isNotEmpty) handle = fresh;
      }
      if (message.containsKey('goAway')) {
        say('  <- goAway ${jsonEncode(message['goAway'])}');
      }
      final content = message['serverContent'] as Map<String, Object?>?;
      if (content != null) {
        final parts =
            (content['modelTurn'] as Map<String, Object?>?)?['parts']
                as List<Object?>? ??
            const [];
        for (final part in parts) {
          final text = (part as Map<String, Object?>)['text'];
          if (text is String) buffer.write(text);
        }
        final spoken =
            (content['outputTranscription'] as Map<String, Object?>?)?['text'];
        if (spoken is String) buffer.write(spoken);
        if (content['turnComplete'] == true) done = true;
      }
    }
    say('  <- "${buffer.toString().trim()}"');
    return buffer.toString();
  }

  String _redactHandle(Map<String, Object?> update) {
    final copy = Map<String, Object?>.from(update);
    final fresh = copy['newHandle'];
    if (fresh is String) copy['newHandle'] = '${_tag(fresh)} <redacted>';
    return jsonEncode(copy);
  }

  /// End the socket the way a lost network does. Dart refuses to *send* 1006
  /// (it is reserved for "no close frame seen"), so this is 1001 "going
  /// away" — still an unannounced end of session from the server's side.
  Future<void> drop() async {
    await _ws.close(1001).catchError((_) {});
    await _inbox.cancel();
  }

  Future<void> close() async {
    await _ws.close().catchError((_) {});
    await _inbox.cancel();
    say('  .. closed by us (${_ws.closeCode} "${_ws.closeReason ?? ''}")');
  }
}

// ------------------------------------------------------------ experiments

/// Expiry wide enough that nothing here can be mistaken for a timeout:
/// `newSessionExpireTime` otherwise defaults to one minute, which is shorter
/// than the experiment.
Map<String, Object?> _expiries() => {
  'expireTime': _iso(const Duration(minutes: 30)),
  'newSessionExpireTime': _iso(const Duration(minutes: 25)),
};

/// Neither documented way of presenting a token worked first time, and the
/// two errors differ ("unregistered callers" vs "API key not valid"), so
/// before any of the real questions: find a form the endpoint accepts.
/// Failed setups start no session, so this is free.
Future<void> _auth() async {
  say('-- control: the raw API key on this path and model');
  final control = await Live.open(useKey: true);
  if (control == null) {
    say('  !! the API key itself does not work — nothing below means anything');
    return;
  }
  await control.close();

  // Vary the mint body too: the first round used a 25-minute
  // `newSessionExpireTime` against a documented default of one minute, and a
  // token the server considered malformed would look exactly like this.
  final bodies = <String, Map<String, Object?>>{
    'defaults (uses only)': {'uses': 1},
    'empty body': {},
    'documented defaults': {
      'uses': 1,
      'expireTime': _iso(const Duration(minutes: 30)),
      'newSessionExpireTime': _iso(const Duration(minutes: 1)),
    },
    'constrained (snake_case)': {
      'uses': 1,
      'live_connect_constraints': {
        'model': _model,
        'config': {
          'response_modalities': ['AUDIO'],
        },
      },
    },
    'constrained (camelCase)': {
      'uses': 1,
      'liveConnectConstraints': {
        'model': _model,
        'config': {
          'responseModalities': ['AUDIO'],
        },
      },
    },
  };

  for (final mintVersion in const ['v1alpha', 'v1beta']) {
    for (final body in bodies.entries) {
      say('\n-- mint: ${body.key} on $mintVersion');
      final token = await mint(body.value, version: mintVersion);
      if (token == null) continue;
      final bare = token.split('/').last;
      for (final version in const ['v1beta', 'v1alpha']) {
        // `js-genai` routes an `auth_tokens/…` key to a *different* RPC,
        // `BidiGenerateContentConstrained`, with `?access_token=`. That is
        // in no version of the prose docs.
        for (final entry in {
          'Constrained access_token': (
            'BidiGenerateContentConstrained',
            '?access_token=$token',
            null,
          ),
          'Constrained key': (
            'BidiGenerateContentConstrained',
            '?key=$token',
            null,
          ),
          'plain access_token': (
            'BidiGenerateContent',
            '?access_token=$token',
            null,
          ),
          'plain Authorization: Token': (
            'BidiGenerateContent',
            '',
            {'Authorization': 'Token $bare'},
          ),
        }.entries) {
          final (method, query, headers) = entry.value;
          final path =
              '/ws/google.ai.generativelanguage.$version'
              '.GenerativeService.$method';
          final outcome = await _handshake('wss://$_host$path$query', headers);
          say('  ws=$version ${entry.key.padRight(28)} $outcome');
          if (outcome.startsWith('OK')) {
            say(
              '\n  ** accepted: mint=$mintVersion ${body.key}'
              ' + ws=$version + ${entry.key}',
            );
            return;
          }
        }
      }
    }
  }
  say('\n  ** no form of the minted token was accepted');
}

/// Opens a socket, sends a minimal setup, and reports only what came back.
Future<String> _handshake(String url, Map<String, String>? headers) async {
  WebSocket ws;
  try {
    ws = await WebSocket.connect(
      url,
      headers: headers,
    ).timeout(const Duration(seconds: 20));
  } catch (e) {
    return 'handshake refused: ${_scrub(e)}';
  }
  final done = Completer<String>();
  ws.listen(
    (frame) {
      final text = frame is String ? frame : utf8.decode(frame as List<int>);
      if (!done.isCompleted) {
        done.complete(
          text.contains('setupComplete') ? 'OK $text' : 'frame: $text',
        );
      }
    },
    onDone: () {
      if (!done.isCompleted) {
        done.complete('close ${ws.closeCode} "${ws.closeReason ?? ''}"');
      }
    },
    onError: (Object e) {
      if (!done.isCompleted) done.complete('error: $e');
    },
  );
  ws.add(
    jsonEncode({
      'setup': {
        'model': _model,
        'generationConfig': {
          'responseModalities': ['AUDIO'],
        },
      },
    }),
  );
  final result = await done.future.timeout(
    const Duration(seconds: 20),
    onTimeout: () => 'timeout with no frame and no close',
  );
  await ws.close().catchError((_) {});
  return result;
}

/// Q1: does `uses` count session starts or messages? Several turns on one
/// token, then a second connect — plus a `uses: 2` control, because a
/// rejection on its own could be anything.
Future<void> _q1() async {
  final token = await mint({'uses': 1, ..._expiries()}, label: '(uses: 1)');
  if (token == null) return;

  say('\n-- connect #1 with the uses:1 token, three turns');
  final live = await Live.open(token: token, sessionResumption: {});
  if (live == null) return;
  for (final prompt in const [
    'Reply with the single word one.',
    'Reply with the single word two.',
    'Reply with the single word three.',
  ]) {
    await live.turn(prompt);
  }
  final handle = live.handle;
  say('  handle captured: ${handle == null ? 'NONE' : _tag(handle)}');
  await live.close();

  say('\n-- connect #2: same uses:1 token, NO resumption handle');
  final again = await Live.open(token: token, sessionResumption: {});
  if (again != null) {
    say('  !! accepted — a second session start on a spent uses:1 token');
    await again.close();
  }

  // If a spent token can be resumed over and over, `uses` bounds nothing but
  // the *first* connect and the real bound on a session is `expireTime`.
  var carried = handle;
  for (var round = 3; round <= 5 && carried != null; round++) {
    say('\n-- connect #$round: same spent uses:1 token, WITH a handle');
    final resumed = await Live.open(
      token: token,
      sessionResumption: {'handle': carried},
    );
    if (resumed == null) break;
    await resumed.turn('Reply with the single word $round.');
    await resumed.turn('Reply with the single word more.');
    carried = resumed.handle ?? carried;
    await resumed.close();
  }

  say('\n-- how far out will the mint let expireTime go?');
  for (final ahead in const [Duration(hours: 1), Duration(hours: 24)]) {
    await mint({
      'uses': 1,
      'expireTime': _iso(ahead),
    }, label: '(expireTime +${ahead.inHours}h)');
  }

  say('\n-- control: a uses:2 token, same expiries, close and reconnect');
  final two = await mint({'uses': 2, ..._expiries()}, label: '(uses: 2)');
  if (two == null) return;
  final first = await Live.open(token: two);
  if (first == null) return;
  await first.turn('Reply with the single word one.');
  await first.close();
  final second = await Live.open(token: two);
  if (second != null) {
    say('  .. second session start on the uses:2 token was accepted');
    await second.close();
  }
}

/// Q2: does resumption survive the token? The fresh-token-with-old-handle
/// case is the one that can kill the design.
Future<void> _q2() async {
  final token = await mint({'uses': 2, ..._expiries()}, label: '(uses: 2)');
  if (token == null) return;

  say('\n-- session 1: plant a word, capture a handle, drop the socket');
  final live = await Live.open(token: token, sessionResumption: {});
  if (live == null) return;
  await live.turn(
    'Remember this word: pomegranate. Reply with the single word ok.',
  );
  // The first turn never carries a sessionResumptionUpdate (observed in q1),
  // so a second turn is needed before there is a handle to drop back to.
  await live.turn('Reply with the single word ready.');
  final handle = live.handle;
  say('  handle captured: ${handle == null ? 'NONE' : _tag(handle)}');
  await live.drop();
  say('  .. socket dropped without a close handshake');
  if (handle == null) return;

  say('\n-- resume A: the SAME token, old handle');
  final same = await Live.open(
    token: token,
    sessionResumption: {'handle': handle},
  );
  if (same != null) {
    // Accepted is not the same as resumed: ask for the planted word.
    await same.turn('What word did I ask you to remember? Reply with it.');
    await same.close();
  }

  say('\n-- resume B: a FRESHLY minted token, same old handle');
  final fresh = await mint({'uses': 1, ..._expiries()}, label: '(fresh)');
  if (fresh == null) return;
  final other = await Live.open(
    token: fresh,
    sessionResumption: {'handle': handle},
  );
  if (other != null) {
    await other.turn('What word did I ask you to remember? Reply with it.');
    await other.close();
  }
}

/// Q3: does the minting side learn anything? usageMetadata over a token is
/// covered by Q1/Q2; this is the "is there any server-side usage report"
/// half. Nothing in the docs suggests there is — so ask and record the error.
Future<void> _q3() async {
  final token = await mint({'uses': 1, ..._expiries()}, label: '(for lookup)');
  if (token == null) return;
  for (final path in [
    '/v1beta/auth_tokens',
    '/v1alpha/auth_tokens',
    '/v1beta/$token',
    '/v1alpha/$token',
  ]) {
    await get(path);
  }
}

/// Q4: not just whether the model lock is enforced, but which model actually
/// serves a locked session — this is drover's real migration question, since
/// `gemini-3.1-flash-live-preview` (`_model`, still what shipped app builds
/// send) is now the legacy preview of `gemini-3.8-live` (`other`), the
/// documented "New Stable" replacement in the same pricing row. If a Cloud
/// Function can mint a token locked to the new model while the client setup
/// still names the old one, the model can be migrated server-side with no app
/// release. The mint below locks to `other`; the connect below asks for
/// `_model` and takes a real turn, printing any model identifier the server
/// reports on its frames — that identifier is the answer, not just whether
/// the connection was accepted. `liveConnectConstraints` is the *SDK* name;
/// over REST the field is `bidiGenerateContentSetup` plus a `fieldMask`
/// saying which of its fields are frozen (from js-genai's
/// `convertBidiSetupToTokenSetup`) — the prose docs name neither.
Future<void> _q4() async {
  const other = 'models/gemini-3.8-live';
  final token = await mint({
    'uses': 3,
    ..._expiries(),
    'bidiGenerateContentSetup': {
      'model': other,
      'generationConfig': {
        'responseModalities': ['AUDIO'],
      },
    },
    'fieldMask': 'model,generationConfig.responseModalities',
  }, label: '(locked to $other)');
  if (token == null) return;

  // Positive control, and the reference for what modelVersion prints when
  // the client's request and the lock actually agree — without this, a
  // failure on the mismatched connect below can't be told apart from
  // "$other just doesn't serve over ephemeral tokens".
  say('\n-- connect asking for the locked model ($other) itself');
  final matched = await Live.open(token: token, model: other);
  if (matched != null) {
    await matched.turn('Reply with the single word one.');
    await matched.close();
  }

  say('\n-- connect asking for $_model, on a token locked to $other');
  final locked = await Live.open(token: token, model: _model);
  if (locked != null) {
    await locked.turn('Reply with the single word one.');
    await locked.close();
  }

  // setupComplete above is ambiguous by itself: the server may have honoured
  // the client's model, or run the locked one instead — that is exactly what
  // the modelVersion print inside turn() above is for. A model that cannot
  // exist separates the two a different way: accepted means the field is
  // ignored outright, model mismatch or not.
  say('\n-- connect asking for a NONEXISTENT model, on the locked token');
  final nonsense = await Live.open(token: token, model: 'models/not-a-model');
  if (nonsense != null) {
    say('  .. accepted despite a nonexistent model');
    await nonsense.close();
  }

  say('\n-- control: the same nonexistent model on an UNCONSTRAINED token');
  final loose = await mint({'uses': 1, ..._expiries()}, label: '(no lock)');
  if (loose == null) return;
  final control = await Live.open(token: loose, model: 'models/not-a-model');
  if (control != null) {
    say('  .. accepted — setup does not validate the model at all');
    await control.close();
  }
}

/// Wall-clock offset from the moment a token was set to expire. Negative is
/// before expiry, positive after — every E5/E6 line is stamped with it.
String _at(DateTime expiry, {DateTime? now}) {
  final moment = now ?? DateTime.now().toUtc();
  final delta = moment.difference(expiry).inMilliseconds / 1000;
  return '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)}s';
}

/// E5: does `expireTime` end a session that is already in flight? Q1 pushed
/// the expiries far past the experiment on purpose, so the bound itself was
/// never measured — and the "mint per N minutes as a meter tick" design now
/// rests on it. Take a turn every 20s straight across the boundary.
Future<void> _e5() async {
  final expiry = DateTime.now().toUtc().add(const Duration(seconds: 75));
  final token = await mint({
    'uses': 1,
    'expireTime': '${expiry.toIso8601String().split('.').first}Z',
    'newSessionExpireTime':
        '${expiry.subtract(const Duration(seconds: 15)).toIso8601String().split('.').first}Z',
  }, label: '(expires in 75s)');
  if (token == null) return;

  say('\n-- open at ${_at(expiry)}, then a turn every 20s across expiry');
  final live = await Live.open(token: token, sessionResumption: {});
  if (live == null) return;

  for (var turn = 1; turn <= 7; turn++) {
    say('  [${_at(expiry)}] turn $turn');
    try {
      await live.turn(
        'Reply with the single word $turn.',
        wait: const Duration(seconds: 45),
      );
    } catch (e) {
      final shut = live.closedAt;
      say(
        '  [${_at(expiry)}] turn $turn FAILED: $e\n'
        '     close ${live.closeCode} "${live.closeReason ?? ''}" at '
        '${shut == null ? 'never — socket still open' : _at(expiry, now: shut)}',
      );
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 20));
  }
  say('  [${_at(expiry)}] still answering — expireTime did not stop it');
  await live.close();
}

/// E6: does a resumption chain outlive `expireTime`? The sharper version of
/// E5, and the one that decides whether a mint can be a meter tick. If an
/// expired token still resumes, one wallet check buys unbounded usage.
Future<void> _e6() async {
  final expiry = DateTime.now().toUtc().add(const Duration(seconds: 60));
  final token = await mint({
    'uses': 1,
    'expireTime': '${expiry.toIso8601String().split('.').first}Z',
    'newSessionExpireTime':
        '${expiry.subtract(const Duration(seconds: 20)).toIso8601String().split('.').first}Z',
  }, label: '(expires in 60s)');
  if (token == null) return;

  say('\n-- session 1 at ${_at(expiry)}: two turns, capture a handle');
  final live = await Live.open(token: token, sessionResumption: {});
  if (live == null) return;
  await live.turn('Remember this word: pomegranate. Reply with the word ok.');
  await live.turn('Reply with the single word ready.');
  final handle = live.handle;
  say('  [${_at(expiry)}] handle: ${handle == null ? 'NONE' : _tag(handle)}');
  await live.drop();
  if (handle == null) return;

  say('\n-- waiting for the token to expire');
  while (DateTime.now().toUtc().isBefore(
    expiry.add(const Duration(seconds: 20)),
  )) {
    await Future<void>.delayed(const Duration(seconds: 5));
  }

  say('\n-- resume on the EXPIRED token, old handle [${_at(expiry)}]');
  final stale = await Live.open(
    token: token,
    sessionResumption: {'handle': handle},
  );
  if (stale != null) {
    say('  !! the expired token still opened a session');
    await stale.turn('What word did I ask you to remember? Reply with it.');
    await stale.close();
  }

  say('\n-- resume on a FRESH token, same old handle [${_at(expiry)}]');
  final fresh = await mint({'uses': 1, ..._expiries()}, label: '(fresh)');
  if (fresh == null) return;
  final revived = await Live.open(
    token: fresh,
    sessionResumption: {'handle': handle},
  );
  if (revived != null) {
    await revived.turn('What word did I ask you to remember? Reply with it.');
    await revived.close();
  }
}

// ----------------------------------------------------------------- plumbing

/// Same minimal pull-based queue as `live_probe.dart` — `package:async` is
/// not a dependency of this package and one probe does not justify adding it.
class StreamQueue<T> {
  StreamQueue(Stream<T> stream) {
    _subscription = stream.listen(
      (event) {
        if (_waiting.isNotEmpty) {
          _waiting.removeAt(0).complete(event);
        } else {
          _buffered.add(event);
        }
      },
      onError: (Object error) {
        if (_waiting.isNotEmpty) _waiting.removeAt(0).completeError(error);
      },
      onDone: () {
        for (final completer in _waiting) {
          completer.completeError(StateError('socket closed'));
        }
        _waiting.clear();
      },
    );
  }

  late final StreamSubscription<T> _subscription;
  final _buffered = <T>[];
  final _waiting = <Completer<T>>[];

  Future<T> get next {
    if (_buffered.isNotEmpty) return Future.value(_buffered.removeAt(0));
    final completer = Completer<T>();
    _waiting.add(completer);
    return completer.future;
  }

  Future<void> cancel() => _subscription.cancel();
}
