import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drover/src/voice/voice_transport.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';

/// Just enough Live server to drive [TokenVoiceTransport]: a real WebSocket
/// on loopback that records the token and setup of every connection, answers
/// `setupComplete`, and lets a test push frames or end a token window the way
/// the real server does.
///
/// Real sockets rather than a faked [WebSocket] because the behaviour under
/// test *is* socket behaviour — a close code and its reason.
class _FakeLive {
  _FakeLive(this._server);

  static Future<_FakeLive> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final live = _FakeLive(server);
    server.listen((request) async {
      final token = request.uri.queryParameters['access_token'] ?? '';
      live.tokens.add(token);
      if (live.rejectHandshake) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      live.socket = socket;
      socket.listen((frame) {
        final json = jsonDecode(frame as String) as Map<String, Object?>;
        if (json['setup'] case final Map<String, Object?> setup) {
          live.setups.add(setup);
          // A token the server refuses closes without ever completing setup.
          if (live.refuse.contains(token)) {
            socket.close(1008, 'Request contains an invalid argument.');
            return;
          }
          socket.add(jsonEncode({'setupComplete': <String, Object?>{}}));
          return;
        }
        live.received.add(json);
      });
    });
    return live;
  }

  final HttpServer _server;

  /// Tokens to refuse at setup, by value.
  final refuse = <String>{};

  /// Refuses the WebSocket upgrade itself, as a rejected token does.
  var rejectHandshake = false;
  final tokens = <String>[];
  final setups = <Map<String, Object?>>[];
  final received = <Map<String, Object?>>[];
  WebSocket? socket;

  String get endpoint => 'ws://${_server.address.address}:${_server.port}/live';

  void push(Object frame) => socket!.add(jsonEncode(frame));

  /// Ends the window exactly as the real server does when the token behind
  /// the connection expires (measured 2026-09-18).
  Future<void> expire() => socket!.close(1011, 'auth token has expired');

  /// Kills the TCP connections under the sockets, which is a transport
  /// failure rather than a close handshake. Idempotent.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _server.close(force: true);
  }

  var _stopped = false;
}

/// Hands out `token-1`, `token-2`, … each expiring soon enough that the
/// transport's pre-mint fires straight away.
class _FakeMinter {
  var minted = 0;

  Future<VoiceToken> call() async {
    minted++;
    return VoiceToken(
      token: 'token-$minted',
      expiresAt: DateTime.now().toUtc().add(const Duration(milliseconds: 50)),
    );
  }
}

void main() {
  late _FakeLive live;
  late _FakeMinter minter;

  setUp(() async {
    live = await _FakeLive.start();
    minter = _FakeMinter();
  });

  tearDown(() => live.stop());

  Future<TokenVoiceTransport> connect({String? resumeHandle}) =>
      TokenVoiceTransport.connect(
        tools: const [],
        languageCode: 'en-US',
        resumeHandle: resumeHandle,
        mint: minter.call,
        endpoint: live.endpoint,
      );

  /// Polls until [test] holds; real sockets means real asynchrony.
  Future<void> until(bool Function() test, {String? reason}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!test()) {
      if (DateTime.now().isAfter(deadline)) fail(reason ?? 'timed out');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('connect opens on a minted token and sends the client setup', () async {
    final transport = await connect();
    addTearDown(transport.close);

    expect(live.tokens, ['token-1']);
    final setup = live.setups.single;
    expect(setup['model'], 'models/$kVoiceModel');
    // Everything the token does not freeze is still the client's to send.
    expect(setup['system_instruction'], isNotNull);
    expect(setup['tools'], isNotNull);
    expect(setup['output_audio_transcription'], isNotNull);
    expect(setup['contextWindowCompression'], isNotNull);
    expect(setup['session_resumption'], <String, Object?>{});
    expect(
      (setup['generation_config']! as Map<String, Object?>)['speechConfig'],
      isNotNull,
    );
  });

  test('a resume handle goes into the setup', () async {
    final transport = await connect(resumeHandle: 'handle-0');
    addTearDown(transport.close);

    expect(live.setups.single['session_resumption'], {'handle': 'handle-0'});
  });

  test('a refused token fails the connect instead of looking live', () async {
    live.refuse.add('token-1');
    await expectLater(connect(), throwsA(isA<StateError>()));
  });

  test('a refused handshake never carries the token out', () async {
    // dart:io puts the whole request URI into a WebSocketException, and
    // VoiceSession renders what it catches into the transcript on screen.
    live.rejectHandshake = true;
    await expectLater(
      connect(),
      throwsA(
        isA<StateError>()
            .having((e) => e.message, 'message', isNot(contains('token-1')))
            .having((e) => e.message, 'message', contains('<token>')),
      ),
    );
  });

  test('an expiry close reconnects on the held token and handle, without '
      'surfacing an error or ending the session', () async {
    final transport = await connect();
    addTearDown(transport.close);

    Object? error;
    var done = false;
    final seen = <LiveServerMessage>[];
    transport.receive().listen(
      (r) => seen.add(r.message),
      onError: (Object e) => error = e,
      onDone: () => done = true,
    );

    live.push({
      'sessionResumptionUpdate': {'newHandle': 'handle-1', 'resumable': true},
    });
    await until(() => seen.length == 1);
    // The next token is minted before the window ends, so the reconnect
    // costs a socket and not a round trip.
    await until(() => minter.minted >= 2, reason: 'no token was pre-minted');

    await live.expire();
    await until(() => live.setups.length == 2, reason: 'never reconnected');

    // The window boundary is invisible above the transport: the stream it
    // hands VoiceSession neither errors nor ends, so `_lost` never runs and
    // the one reconnect it allows a genuine drop is left unspent.
    expect(error, isNull);
    expect(done, isFalse);
    // Reconnected on the pre-minted token and the handle the server gave.
    expect(live.tokens, ['token-1', 'token-2']);
    expect(live.setups.last['session_resumption'], {'handle': 'handle-1'});

    // And the conversation carries on over the same stream.
    live.push({
      'serverContent': {'turnComplete': true},
    });
    await until(() => seen.length == 2);
    expect(seen.last, isA<LiveServerContent>());
  });

  test('the handle the caller passed crosses the first boundary', () async {
    // A transport VoiceSession rebuilt after a genuine drop starts on the
    // session's handle; without it, an expiry before the server's own first
    // update would end the session instead of crossing invisibly.
    final transport = await connect(resumeHandle: 'handle-0');
    addTearDown(transport.close);

    var done = false;
    final seen = <LiveServerMessage>[];
    transport.receive().listen(
      (r) => seen.add(r.message),
      onDone: () => done = true,
    );

    live.push({
      'serverContent': {'turnComplete': true},
    });
    await until(() => seen.length == 1);
    await live.expire();

    await until(() => live.setups.length == 2, reason: 'never reconnected');
    expect(done, isFalse);
    expect(live.setups.last['session_resumption'], {'handle': 'handle-0'});
  });

  test(
    'a server error frame reaches the session and ends its window',
    () async {
      final transport = await connect(resumeHandle: 'handle-0');
      addTearDown(transport.close);

      Object? error;
      var done = false;
      transport.receive().listen(
        (_) {},
        onError: (Object e) => error = e,
        onDone: () => done = true,
      );
      live.push({
        'error': {'code': 429, 'message': 'resource exhausted'},
      });

      // Dropping it would leave the session waiting, microphone open, for a
      // turn that is never coming.
      await until(() => error != null, reason: 'the error frame was dropped');

      // And it does not count as a window that carried a conversation, so the
      // close that follows is not treated as a boundary to resume across.
      await live.expire();
      await until(() => done);
      expect(live.setups, hasLength(1));
    },
  );

  test('a frame that will not parse becomes a stream error', () async {
    final transport = await connect();
    addTearDown(transport.close);

    Object? error;
    transport.receive().listen((_) {}, onError: (Object e) => error = e);
    live.socket!.add('not json');

    await until(() => error != null, reason: 'the bad frame vanished');
  });

  test('a failed reconnect is handed up as an error, not an end', () async {
    final transport = await connect();
    addTearDown(transport.close);

    Object? error;
    var done = false;
    transport.receive().listen(
      (_) {},
      onError: (Object e) => error = e,
      onDone: () => done = true,
    );

    live.push({
      'sessionResumptionUpdate': {'newHandle': 'handle-1', 'resumable': true},
    });
    await until(() => minter.minted >= 2);
    // The next window is refused. The session has to hear about it — it still
    // has its own reconnect to spend — rather than see the call simply end.
    live.refuse.add('token-2');
    await live.expire();

    await until(() => error != null, reason: 'the failure was swallowed');
    await until(() => done);
    expect('$error', isNot(contains('token-2')));
  });

  test('any other close ends the stream, as a genuine drop must', () async {
    final transport = await connect();
    addTearDown(transport.close);

    var done = false;
    transport.receive().listen((_) {}, onDone: () => done = true);
    await live.socket!.close(1001, 'going away');

    await until(() => done, reason: 'the drop never reached the session');
    expect(live.setups, hasLength(1));
  });

  test('a window that carried nothing is not resumed again', () async {
    final transport = await connect();
    addTearDown(transport.close);

    var seen = 0;
    var done = false;
    transport.receive().listen((_) => seen++, onDone: () => done = true);

    live.push({
      'sessionResumptionUpdate': {'newHandle': 'handle-1', 'resumable': true},
    });
    await until(() => seen == 1);
    await live.expire();
    await until(() => live.setups.length == 2);

    // The second window dies having carried nothing. A token the server
    // refuses on sight looks exactly like this, and resuming it again would
    // be a mint-and-reconnect loop, so the drop goes up to the session.
    await live.expire();
    await until(() => done, reason: 'the transport kept reconnecting');
    expect(live.setups, hasLength(2));
  });

  test('an expiry close with no handle yet ends the stream', () async {
    final transport = await connect();
    addTearDown(transport.close);

    var done = false;
    transport.receive().listen((_) {}, onDone: () => done = true);
    await live.expire();

    await until(() => done);
    expect(live.setups, hasLength(1));
  });

  test('client frames go out in the shapes the Live API expects', () async {
    final transport = await connect();
    addTearDown(transport.close);

    await transport.sendText('hello');
    await transport.sendAudio(Uint8List.fromList([1, 2, 3]));
    await transport.sendToolResponse([
      const FunctionResponse('list_agents', {'agents': []}, id: 'call-1'),
    ]);
    await until(() => live.received.length == 3);

    expect(live.received[0], {
      'realtime_input': {'text': 'hello'},
    });
    expect(
      (live.received[1]['realtime_input']! as Map<String, Object?>)['audio'],
      {
        'mimeType': 'audio/pcm;rate=16000',
        'data': base64Encode([1, 2, 3]),
      },
    );
    expect(live.received[2], {
      'toolResponse': {
        'functionResponses': [
          {
            'name': 'list_agents',
            'response': {'agents': <Object?>[]},
            'id': 'call-1',
          },
        ],
      },
    });
  });

  group('frames captured from a real session', () {
    // Written verbatim by `tool/token_live_check.dart` against
    // `gemini-3.1-flash-live-preview` on 2026-09-18, bar two redactions the
    // file marks: the resumption handle (a credential) and the tail of the
    // audio payload. Nothing here is hand-written — a mapper tested against
    // invented JSON only proves the invention self-consistent, and a wrong
    // key in the audio branch fails silently: the session simply never
    // plays anything.
    late Map<String, Object?> frames;

    setUpAll(() {
      frames =
          jsonDecode(File('test/voice/live_frames.json').readAsStringSync())
              as Map<String, Object?>;
    });

    /// Pushes the captured frame [name] and returns what the session got.
    Future<LiveServerMessage> replay(String name) async {
      final transport = await connect();
      addTearDown(transport.close);
      final seen = <LiveServerMessage>[];
      transport.receive().listen((r) => seen.add(r.message));
      live.push(frames[name]!);
      await until(() => seen.isNotEmpty, reason: '$name mapped to nothing');
      return seen.single;
    }

    test('a model turn carries its audio and the transcript of it', () async {
      // One frame, both branches: the server sends the audio and its
      // transcription together.
      final message = await replay('audioContent') as LiveServerContent;

      final part = message.modelTurn!.parts.single as InlineDataPart;
      expect(part.mimeType, 'audio/pcm;rate=24000');
      expect(part.bytes, isNotEmpty);
      expect(message.outputTranscription?.text, 'ok');
    });

    test('the end of a turn is carried, and its usage left off it', () async {
      // This frame also carries `usageMetadata` — the field the SDK never
      // surfaces, and the reason a raw socket is worth having. The transport
      // counts it off the raw frame; the mapping must stay clear of it.
      final message = await replay('turnComplete') as LiveServerContent;

      expect(message.turnComplete, isTrue);
      expect(message.modelTurn, isNull);
    });

    test('usage is summed over the turns of a call', () async {
      final transport = await connect();
      addTearDown(transport.close);
      transport.receive().listen((_) {});

      // The captured turn replayed three times, with frames that carry no
      // usage in between: a longer capture would need a live session, and
      // identical turns already tell a sum (2946) from the last report (982)
      // or the largest one.
      live.push(frames['audioContent']!);
      live.push(frames['turnComplete']!);
      live.push(frames['audioContent']!);
      live.push(frames['turnComplete']!);
      live.push(frames['turnComplete']!);
      await until(() => transport.usage.turns == 3, reason: 'no usage seen');

      expect(transport.usage.promptTokens, 982 * 3);
      expect(transport.usage.responseTokens, 20 * 3);
      // Asserted against the totals independently: in the capture the
      // modality details (742 + 201) do not add up to promptTokenCount.
      expect(transport.usage.promptByModality, {
        'TEXT': 742 * 3,
        'AUDIO': 201 * 3,
      });
      expect(transport.usage.responseByModality, {'AUDIO': 20 * 3});
    });

    test('usage of an unexpected shape is skipped, not fatal', () async {
      final transport = await connect();
      addTearDown(transport.close);
      final seen = <LiveServerMessage>[];
      transport.receive().listen(
        (r) => seen.add(r.message),
        onError: (Object e) => fail('the readout ended the call: $e'),
      );

      live.push({
        'serverContent': {'turnComplete': true},
        'usageMetadata': {
          'promptTokenCount': 'lots',
          'promptTokensDetails': {'modality': 'TEXT'},
        },
      });
      // Raw, because `jsonEncode` will not write this one: a JSON number too
      // big to hold decodes as `double.infinity`, whose `toInt()` throws —
      // the one shape that could take the readout's path into the stream.
      live.socket!.add(
        '{"serverContent":{"turnComplete":true},'
        '"usageMetadata":{"promptTokenCount":1e400}}',
      );
      live.push(frames['turnComplete']!);
      await until(() => seen.length == 3, reason: 'the turns stopped coming');

      // Counted as turns, with nothing readable taken off them.
      expect(transport.usage.turns, 3);
      expect(transport.usage.promptTokens, 982);
      expect(transport.usage.promptByModality, {'TEXT': 742, 'AUDIO': 201});
    });

    test('a tool call keeps its name, arguments and id', () async {
      final message = await replay('toolCall') as LiveServerToolCall;

      final call = message.functionCalls!.single;
      expect(call.name, 'favourite_colour');
      expect(call.args, isEmpty);
      expect(call.id, isNotNull);
    });

    test('a resumption update carries the handle to reconnect on', () async {
      final message = await replay('sessionResumptionUpdate');

      expect(
        message,
        isA<SessionResumptionUpdate>()
            .having((u) => u.resumable, 'resumable', isTrue)
            .having((u) => u.newHandle, 'newHandle', isNotEmpty),
      );
    });

    test('every captured frame maps to something', () async {
      // A shape added to the file by a later capture gets a mapping or a
      // failing test, rather than being silently dropped.
      for (final name in frames.keys) {
        expect(
          voiceServerMessage(frames[name]! as Map<String, Object?>),
          isNotNull,
          reason: '$name was dropped by the mapper',
        );
      }
    });
  });
}
