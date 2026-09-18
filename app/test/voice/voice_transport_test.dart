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
  final tokens = <String>[];
  final setups = <Map<String, Object?>>[];
  final received = <Map<String, Object?>>[];
  WebSocket? socket;

  String get endpoint => 'ws://${_server.address.address}:${_server.port}/live';

  void push(Object frame) => socket!.add(jsonEncode(frame));

  /// Ends the window exactly as the real server does when the token behind
  /// the connection expires (measured 2026-09-18).
  Future<void> expire() => socket!.close(1011, 'auth token has expired');

  Future<void> stop() => _server.close(force: true);
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
}
