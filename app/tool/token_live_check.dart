// Live check: does a real conversation over [TokenVoiceTransport] survive the
// token window boundary with the conversation intact?
//
// Usage, from `app/`:
//   GEMINI_API_KEY=$(cat <key file>) fvm flutter test tool/token_live_check.dart
//
// It dials the real Gemini Live API, so it is deliberately NOT under `test/`
// and never runs in `fvm flutter test`. Without `GEMINI_API_KEY` it skips.
//
// It is a `flutter_test` file rather than a `dart run` script only because
// `voice_transport.dart` reaches `dart:ui` and `package:flutter/foundation`
// through `firebase_ai`; `flutter_tester` gives it those, and real sockets
// work there.
//
// It mints straight from the Gemini API instead of through `mintVoiceToken`:
// the Cloud Function verifies Firebase Auth and App Check, which this process
// has not got. The mint body below is the Function's, bar a much shorter
// window so the boundary lands inside one run — and that is exactly the seam
// [TokenVoiceTransport.connect] takes a minter for.
//
// Three things it checks, in one conversation:
//   1. a fact planted before the boundary is still known after it;
//   2. the socket crossing the boundary surfaces neither an error nor an end
//      to the session above it;
//   3. fields the token does NOT freeze still take effect — the tool below is
//      declared by the client alone, so the model calling it proves it.
//
// It also writes one exemplar of each server frame it saw to
// `test/voice/live_frames.json`, which is where the fixtures in
// `test/voice/voice_transport_test.dart` come from. The key is read from the
// environment only, never a file or an argument, and no token, key or
// resumption handle is printed or written.
import 'dart:convert';
import 'dart:io';

import 'package:drover/src/voice/voice_tools.dart';
import 'package:drover/src/voice/voice_transport.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';

/// Short enough that a boundary happens inside one run; the Function ships
/// three minutes.
const _window = Duration(seconds: 75);

/// Where the fixtures for the frame-mapping test are written.
const _fixtures = 'test/voice/live_frames.json';

void main() {
  final key = Platform.environment['GEMINI_API_KEY'];

  test(
    'a conversation over TokenVoiceTransport survives the token window',
    () async {
      if (key == null || key.isEmpty) {
        fail('set GEMINI_API_KEY (see the header of this file)');
      }

      final raw = <String>[];
      // In a teardown, so a run that fails halfway still leaves behind the
      // frames it did see.
      addTearDown(() => _writeFixtures(raw));
      var errored = false;
      var closed = false;

      // One tool, declared only by the client: the token's fieldMask freezes
      // `model` and `generationConfig.responseModalities` and nothing else,
      // so a call to this is the proof that unmasked client fields bind.
      var toolCalls = 0;
      final tools = [
        VoiceTool(
          name: 'favourite_colour',
          description: 'Returns the drover mascot\'s favourite colour.',
          parameters: const {},
          run: (_) async {
            toolCalls++;
            return {'colour': 'ultramarine'};
          },
        ),
      ];

      // The FIRST token's expiry: the transport mints the next one ahead of
      // the boundary, and waiting for that one's would step over two windows.
      DateTime? expiry;
      final transport = await TokenVoiceTransport.connect(
        tools: tools,
        languageCode: 'en-US',
        mint: () async {
          final token = await _mint(key, _window);
          expiry ??= token.expiresAt;
          _say(
            'minted a token expiring at ${token.expiresAt.toIso8601String()}',
          );
          return token;
        },
        onRawFrame: raw.add,
      );

      // One turn's worth of the model's speech, as the server transcribes it.
      final spoken = StringBuffer();
      var turnComplete = false;
      transport.receive().listen(
        (response) async {
          final message = response.message;
          if (message is LiveServerContent) {
            if (message.outputTranscription?.text case final text?) {
              spoken.write(text);
            }
            if (message.turnComplete == true) turnComplete = true;
          }
          if (message is LiveServerToolCall) {
            await transport.sendToolResponse(
              await runVoiceToolCalls(message.functionCalls ?? const [], tools),
            );
          }
        },
        onError: (Object e) {
          errored = true;
          _say('!! the session surfaced an error: $e');
        },
        onDone: () {
          closed = true;
          _say('!! the session ended');
        },
      );

      Future<String> turn(String prompt) async {
        spoken.clear();
        turnComplete = false;
        _say('-> $prompt');
        await transport.sendText(prompt);
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        while (!turnComplete && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          if (errored || closed) break;
        }
        final said = spoken.toString().trim();
        _say('<- $said');
        return said;
      }

      await turn(
        'Remember this word: pomegranate. Reply with the single word ok.',
      );
      // A resumption handle only arrives after a turn or two, and the
      // boundary crossing needs one.
      await turn('Reply with the single word ready.');
      final colour = await turn(
        'Call the favourite_colour tool and tell me the colour it returns.',
      );
      expect(
        toolCalls,
        greaterThan(0),
        reason:
            'the client-declared tool never bound — an unmasked field was '
            'dropped by the constrained endpoint',
      );
      expect(colour.toLowerCase(), contains('ultramarine'));

      final boundary = expiry!.add(const Duration(seconds: 10));
      _say('waiting for the window to end at ${expiry!.toIso8601String()}');
      while (DateTime.now().toUtc().isBefore(boundary)) {
        await Future<void>.delayed(const Duration(seconds: 5));
      }
      _say('past the boundary; errored=$errored closed=$closed');

      final recalled = await turn(
        'What word did I ask you to remember? Reply with just that word.',
      );

      expect(errored, isFalse, reason: 'the boundary surfaced as an error');
      expect(closed, isFalse, reason: 'the boundary ended the session');
      expect(recalled.toLowerCase(), contains('pomegranate'));

      await transport.close();
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

void _say(String line) => stdout.writeln('[live] $line');

/// The same mint the Cloud Function sends, with a shorter window.
Future<VoiceToken> _mint(String key, Duration window) async {
  final expire = DateTime.now().toUtc().add(window);
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse(
        'https://generativelanguage.googleapis.com/v1alpha/auth_tokens',
      ),
    );
    request.headers
      ..set('x-goog-api-key', key)
      ..contentType = ContentType.json;
    request.write(
      jsonEncode({
        'uses': 1,
        'expireTime': _iso(expire),
        'newSessionExpireTime': _iso(
          expire.subtract(const Duration(seconds: 20)),
        ),
        'bidiGenerateContentSetup': {
          'model': 'models/$kVoiceModel',
          'generationConfig': {
            'responseModalities': ['AUDIO'],
          },
        },
        'fieldMask': 'model,generationConfig.responseModalities',
      }),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      // Status only, like the Function's own failure log: the error body
      // echoes the request back.
      throw StateError('mint failed: HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(body) as Map<String, Object?>;
    return VoiceToken(
      token: decoded['name']! as String,
      expiresAt: DateTime.parse(
        decoded['expireTime'] as String? ?? _iso(expire),
      ),
    );
  } finally {
    client.close();
  }
}

String _iso(DateTime moment) =>
    '${moment.toUtc().toIso8601String().split('.').first}Z';

/// Writes one exemplar of each frame shape the mapper handles.
///
/// Verbatim except for two redactions, both marked in the file: a resumption
/// handle is a credential, and an audio payload is a megabyte of base64.
void _writeFixtures(List<String> raw) {
  final wanted = <String, bool Function(Map<String, Object?>)>{
    'audioContent': (f) =>
        _content(f)?['modelTurn'] != null &&
        jsonEncode(_content(f)).contains('inlineData'),
    'outputTranscription': (f) => _content(f)?['outputTranscription'] != null,
    'inputTranscription': (f) => _content(f)?['inputTranscription'] != null,
    'turnComplete': (f) => _content(f)?['turnComplete'] == true,
    'toolCall': (f) => f['toolCall'] != null,
    'sessionResumptionUpdate': (f) => f['sessionResumptionUpdate'] != null,
  };
  final picked = <String, Object?>{};
  for (final entry in wanted.entries) {
    for (final frame in raw) {
      final decoded = jsonDecode(frame) as Map<String, Object?>;
      if (!entry.value(decoded)) continue;
      picked[entry.key] = _redact(decoded);
      break;
    }
  }
  File(_fixtures).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(picked)}\n',
  );
  _say('wrote ${picked.length} fixture frames to $_fixtures');
  for (final missing in wanted.keys.where((k) => !picked.containsKey(k))) {
    _say('!! no $missing frame was seen');
  }
}

Map<String, Object?>? _content(Map<String, Object?> frame) =>
    frame['serverContent'] as Map<String, Object?>?;

Map<String, Object?> _redact(Map<String, Object?> frame) {
  final json = jsonDecode(jsonEncode(frame)) as Map<String, Object?>;
  if (json['sessionResumptionUpdate'] case final Map<String, Object?> update) {
    if (update['newHandle'] is String) {
      update['newHandle'] = 'REDACTED-HANDLE';
    }
  }
  final parts =
      (_content(json)?['modelTurn'] as Map<String, Object?>?)?['parts']
          as List<Object?>?;
  for (final part in parts ?? const []) {
    final data = (part! as Map<String, Object?>)['inlineData'];
    if (data is Map<String, Object?> && data['data'] is String) {
      // Kept a multiple of four so it still decodes as base64.
      final encoded = data['data']! as String;
      data['data'] = encoded.substring(0, encoded.length.clamp(0, 64));
      data['_truncated'] = true;
    }
  }
  return json;
}
