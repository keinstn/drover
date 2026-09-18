// Probe: what does Gemini Live actually report as usage?
//
// `firebase_ai` 4.0.0 never surfaces `usageMetadata` on the Live path (see
// "Why the direct connection cannot enforce a balance" in docs/voice-billing.md),
// so the app cannot measure what a voice session costs. This talks to the Live
// API directly, over the same raw WebSocket a metering relay would hold, and
// dumps every usage report verbatim.
//
// The question it exists to answer: is re-billed accumulated context reported
// per modality (audio vs text), or only as a total? That is a 4x spread on the
// dominant cost term, and every price depends on it. What it found is written
// up under "Before setting a price" in docs/voice-billing.md.
//
// The key is read from the environment only — never a file, never an argument
// (arguments show up in `ps`):
//
//   GEMINI_API_KEY=<key> fvm dart run tool/live_probe.dart [turns] [speech.wav]
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _model = 'models/gemini-3.1-flash-live-preview';
const _host = 'generativelanguage.googleapis.com';
const _path =
    '/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';

/// Short prompts, so the replies stay short and the probe stays cheap. The
/// content does not matter; the turn count does, since that is what drives
/// context re-billing.
const _prompts = [
  'Say the word ready.',
  'Say the word two.',
  'Say the word three.',
  'Say the word four.',
  'Say the word five.',
];

Future<void> main(List<String> args) async {
  final key = Platform.environment['GEMINI_API_KEY'];
  if (key == null || key.isEmpty) {
    stderr.writeln('set GEMINI_API_KEY (see the header of this file)');
    exit(2);
  }
  final turns = int.tryParse(args.isEmpty ? '' : args.first) ?? 3;
  // Optional: a PCM16 16 kHz mono WAV to speak on every turn, which is what
  // the app actually sends. Without it the turns are text, which prices
  // differently and cannot answer how audio history is re-billed.
  //   say -o turn.wav --file-format=WAVE --data-format=LEI16@16000 "..."
  final pcm = args.length > 1
      ? _pcmFromWav(File(args[1]).readAsBytesSync())
      : null;

  final ws = await WebSocket.connect('wss://$_host$_path?key=$key');
  final messages = StreamController<Map<String, Object?>>();
  ws.listen(
    (frame) {
      final text = frame is String ? frame : utf8.decode(frame as List<int>);
      messages.add(jsonDecode(text) as Map<String, Object?>);
    },
    onDone: () {
      stdout.writeln('socket closed: ${ws.closeCode} ${ws.closeReason ?? ''}');
      messages.close();
    },
    onError: messages.addError,
  );
  final inbox = StreamQueue(messages.stream);

  // Audio out, like the app: an audio response is what makes output tokens
  // audio tokens, which is half of what we are trying to price.
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

  final setup = await inbox.next.timeout(const Duration(seconds: 30));
  if (!setup.containsKey('setupComplete')) {
    stderr.writeln('setup failed: ${jsonEncode(setup)}');
    await ws.close();
    exit(1);
  }
  stdout.writeln('connected: $_model\n');

  final encoder = const JsonEncoder.withIndent('  ');
  for (var turn = 1; turn <= turns; turn++) {
    if (pcm != null) {
      // 100 ms per frame, the way a real client streams it.
      const frame = 3200;
      for (var at = 0; at < pcm.length; at += frame) {
        final end = at + frame < pcm.length ? at + frame : pcm.length;
        ws.add(
          jsonEncode({
            'realtimeInput': {
              'audio': {
                'data': base64Encode(pcm.sublist(at, end)),
                'mimeType': 'audio/pcm;rate=16000',
              },
            },
          }),
        );
        // Paced like a microphone. Dumping the whole clip at once gets the
        // socket closed with 1008 on a realtime endpoint.
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      // A second of silence, so automatic VAD closes the turn. Do NOT send
      // `audioStreamEnd`: that ends the session's audio stream for good, and
      // the socket closes before a second turn can be spoken.
      final silence = List<int>.filled(frame, 0);
      for (var i = 0; i < 10; i++) {
        ws.add(
          jsonEncode({
            'realtimeInput': {
              'audio': {
                'data': base64Encode(silence),
                'mimeType': 'audio/pcm;rate=16000',
              },
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } else {
      ws.add(
        jsonEncode({
          'clientContent': {
            'turns': [
              {
                'role': 'user',
                'parts': [
                  {'text': _prompts[(turn - 1) % _prompts.length]},
                ],
              },
            ],
            'turnComplete': true,
          },
        }),
      );
    }

    var audioParts = 0;
    var sawTurnComplete = false;
    var sawUsage = false;
    while (!(sawTurnComplete && sawUsage)) {
      final message = await inbox.next.timeout(const Duration(seconds: 60));
      final usage = message['usageMetadata'];
      if (usage != null) {
        sawUsage = true;
        stdout.writeln('--- turn $turn · usageMetadata ---');
        stdout.writeln(encoder.convert(usage));
      }
      final content = message['serverContent'] as Map<String, Object?>?;
      if (content != null) {
        final modelTurn = content['modelTurn'] as Map<String, Object?>?;
        audioParts += (modelTurn?['parts'] as List<Object?>? ?? []).length;
        if (content['turnComplete'] == true) sawTurnComplete = true;
      }
      // Worth seeing raw, but neither ends the turn.
      if (message.containsKey('goAway') ||
          message.containsKey('sessionResumptionUpdate')) {
        stdout.writeln(
          '    (${encoder.convert(message).replaceAll('\n', ' ')})',
        );
      }
    }
    // Confirms the reply really was audio, so the response tokens above are
    // audio tokens.
    stdout.writeln('turn $turn: $audioParts audio parts\n');
  }

  await ws.close();
}

/// Minimal pull-based reader over a broadcast-free stream — `package:async`'s
/// StreamQueue is not a dependency of this package and one probe does not
/// justify adding it.
class StreamQueue<T> {
  StreamQueue(Stream<T> stream) {
    stream.listen(
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

  final _buffered = <T>[];
  final _waiting = <Completer<T>>[];

  Future<T> get next {
    if (_buffered.isNotEmpty) return Future.value(_buffered.removeAt(0));
    final completer = Completer<T>();
    _waiting.add(completer);
    return completer.future;
  }
}

/// The PCM payload of a WAV file. `say` writes a padding (`FLLR`) chunk before
/// the data, so the header is not the canonical 44 bytes and the chunks have
/// to be walked.
List<int> _pcmFromWav(List<int> bytes) {
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  var at = 12; // past "RIFF" <size> "WAVE"
  while (at + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(at, at + 4));
    final size = data.getUint32(at + 4, Endian.little);
    if (id == 'data') return bytes.sublist(at + 8, at + 8 + size);
    at += 8 + size + (size % 2);
  }
  throw StateError('no data chunk in the WAV');
}
