import 'dart:typed_data';
import 'dart:ui' show Locale;

import 'package:firebase_ai/firebase_ai.dart';

import 'voice_tools.dart';

/// Gemini Live model used for the voice assistant (Firebase AI Logic, Gemini
/// Developer API backend — no API key ships in the app).
const kVoiceModel = 'gemini-3.1-flash-live-preview';

const kVoiceSystemPrompt = '''
You are the voice concierge for drover, a phone app that manages AI coding
agents running on the user's machine. Answer in the language the user speaks.
Be brief: one or two spoken sentences. Never read out paths, IDs or code.
When asked about agents or their state, call list_agents and summarise: how
many agents there are, which are blocked (waiting for the user), which are
working, which are idle. Refer to agents by title or kind, never by id.
You can also relay messages to agents. Think of it as voicemail: the agent is busy, you leave it a message, and it calls back when it is done.
- To send a message: compose it concisely in the user's own words and language, read the exact message back to the user, and ask for confirmation. Call send_message ONLY after an explicit yes. After sending, say it was sent and that you will announce when the agent finishes; the user may end the conversation meanwhile.
- Messages from the app arrive as text that starts with "[event]". Announce each one immediately and briefly in the user's language, then wait for the user. When an event carries a question with numbered options, read the options with their numbers and ask which one; then call answer_question with the option number, or with text when the user answers freely.
- If the user does not name an agent, use the agent from the most recent event, or the one most recently discussed. If that is unclear, ask; never guess.
- Never invent what an agent said. Use read_agent when asked what an agent replied.
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

/// [VoiceTransport] over a Firebase AI [LiveSession].
class FirebaseVoiceTransport implements VoiceTransport {
  FirebaseVoiceTransport._(this._session);

  final LiveSession _session;

  /// Builds the live model for [tools] and opens the session.
  static Future<FirebaseVoiceTransport> connect({
    required List<VoiceTool> tools,
    required String languageCode,
  }) async {
    final model = FirebaseAI.googleAI().liveGenerativeModel(
      model: kVoiceModel,
      systemInstruction: Content.text(kVoiceSystemPrompt),
      tools: [voiceToolsToFirebase(tools)],
      liveGenerationConfig: LiveGenerationConfig(
        responseModalities: [ResponseModalities.audio],
        speechConfig: SpeechConfig(
          voiceName: 'Aoede',
          languageCode: languageCode,
        ),
        inputAudioTranscription: AudioTranscriptionConfig(),
        outputAudioTranscription: AudioTranscriptionConfig(),
      ),
    );
    // ponytail: no session resumption / context compression yet — a session
    // dies with the socket (~10 min server cap). Add
    // SessionResumptionConfig + ContextWindowCompressionConfig here when
    // longer conversations matter.
    return FirebaseVoiceTransport._(await model.connect());
  }

  @override
  Stream<LiveServerResponse> receive() => _session.receive();

  @override
  Future<void> sendAudio(Uint8List pcm16k) => _session.sendAudioRealtime(
    InlineDataPart('audio/pcm;rate=16000', pcm16k),
  );

  @override
  Future<void> sendText(String text) => _session.sendTextRealtime(text);

  @override
  Future<void> sendToolResponse(List<FunctionResponse> responses) =>
      _session.sendToolResponse(responses);

  @override
  Future<void> close() => _session.close();
}
