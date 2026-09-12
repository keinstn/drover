import 'dart:async';
import 'dart:typed_data';

import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/voice/voice_audio.dart';
import 'package:drover/src/voice/voice_herd.dart';
import 'package:drover/src/voice/voice_transport.dart';
import 'package:firebase_ai/firebase_ai.dart';

class FakeTransport implements VoiceTransport {
  final server = StreamController<LiveServerResponse>();
  final sentAudio = <Uint8List>[];
  final sentText = <String>[];
  final toolResponses = <List<FunctionResponse>>[];
  var closeCalls = 0;

  void push(LiveServerMessage message) =>
      server.add(LiveServerResponse(message: message));

  /// Offers [handle] as a resumption handle, as the server does periodically.
  void pushResumption(String handle, {bool resumable = true}) =>
      push(SessionResumptionUpdate(newHandle: handle, resumable: resumable));

  @override
  Stream<LiveServerResponse> receive() => server.stream;

  @override
  Future<void> sendAudio(Uint8List pcm16k) async => sentAudio.add(pcm16k);

  @override
  Future<void> sendText(String text) async => sentText.add(text);

  @override
  Future<void> sendToolResponse(List<FunctionResponse> responses) async =>
      toolResponses.add(responses);

  @override
  Future<void> close() async {
    closeCalls++;
    // Not awaited: once the session cancelled its subscription, close()
    // returns a root-zone future that never resolves under FakeAsync.
    if (!server.isClosed) unawaited(server.close());
  }
}

/// Hands out a fresh [FakeTransport] per connect and records the resumption
/// handle each one was asked for.
class FakeConnector {
  final transports = <FakeTransport>[];
  final handles = <String?>[];

  /// When set, the connect at that index (0-based) throws instead.
  final throwAt = <int>{};

  FakeTransport get last => transports.last;

  Future<VoiceTransport> call(String? resumeHandle) async {
    final index = handles.length;
    handles.add(resumeHandle);
    if (throwAt.contains(index)) throw StateError('handle refused');
    final transport = FakeTransport();
    transports.add(transport);
    return transport;
  }
}

class FakeMic implements VoiceMic {
  FakeMic({this.permitted = true});

  final bool permitted;
  // Broadcast so a restarted session can listen again.
  final frames = StreamController<Uint8List>.broadcast();
  var startCalls = 0;
  var stopCalls = 0;
  var disposeCalls = 0;

  @override
  Future<bool> hasPermission() async => permitted;

  @override
  Future<Stream<Uint8List>> start() async {
    startCalls++;
    return frames.stream;
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> dispose() async => disposeCalls++;
}

class FakeSpeaker implements VoiceSpeaker {
  FakeSpeaker({this.interruptGate, this.disposeGate, this.interruptError});

  /// When set, [interrupt]/[dispose] wait for the gate before completing.
  final Completer<void>? interruptGate;
  final Completer<void>? disposeGate;

  /// When set, [interrupt] throws it.
  final Object? interruptError;
  final played = <Uint8List>[];
  var initCalls = 0;
  var interruptCalls = 0;
  var disposeCalls = 0;

  @override
  Future<void> init() async => initCalls++;

  @override
  void play(Uint8List pcm24k) => played.add(pcm24k);

  @override
  Future<void> interrupt() async {
    interruptCalls++;
    if (interruptError != null) throw interruptError!;
    await interruptGate?.future;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await disposeGate?.future;
  }
}

/// A model turn carrying one audio chunk of [bytes] bytes (24 kHz PCM16 mono:
/// 48000 bytes per second).
LiveServerContent audioChunk({int bytes = 3}) => LiveServerContent(
  modelTurn: Content('model', [
    InlineDataPart('audio/pcm;rate=24000', Uint8List(bytes)),
  ]),
);

/// An [AgentInfo] with only the fields the voice layer looks at.
AgentInfo fakeAgent({
  String paneId = 'w:p1',
  String? kind = 'claude',
  String? name,
  String? title,
  AgentStatus status = AgentStatus.idle,
  String cwd = '/tmp/proj',
  String? foregroundCwd,
}) => AgentInfo(
  paneId: paneId,
  workspaceId: 'w',
  tabId: 'w:t1',
  agent: kind,
  name: name,
  status: status,
  cwd: cwd,
  foregroundCwd: foregroundCwd,
  focused: false,
  terminalTitle: title,
);

/// A scripted [VoiceHerd] that records what the tools and announcer ask of
/// it.
class FakeVoiceHerd implements VoiceHerd {
  FakeVoiceHerd({this.agents = const []});

  @override
  List<AgentInfo> agents;

  /// paneId -> last reply; a missing key answers null.
  final replies = <String, String>{};

  /// paneId -> pending question; a missing key answers null.
  final questions = <String, AgentQuestion>{};

  /// When set, [lastReply] and [pendingQuestion] throw it.
  Object? readError;

  final sent = <(AgentInfo, String)>[];
  final answered = <(AgentInfo, AgentQuestion, int?, String?)>[];

  @override
  Future<String?> lastReply(AgentInfo agent) async {
    if (readError != null) throw readError!;
    return replies[agent.paneId];
  }

  @override
  Future<AgentQuestion?> pendingQuestion(AgentInfo agent) async {
    if (readError != null) throw readError!;
    return questions[agent.paneId];
  }

  /// When set, [send] throws it instead of recording.
  Object? sendError;

  /// When set, [send] waits for it before returning.
  Completer<void>? sendGate;

  @override
  Future<void> send(AgentInfo agent, String text) async {
    if (sendError != null) throw sendError!;
    sent.add((agent, text));
    await sendGate?.future;
  }

  @override
  Future<void> answer(
    AgentInfo agent,
    AgentQuestion question, {
    int? option,
    String? text,
  }) async => answered.add((agent, question, option, text));

  /// (kind, cwd, brief) per [launch] call.
  final launched = <(String, String, String)>[];

  /// When set, [launch] throws it instead of recording.
  Object? launchError;

  /// What [launch] reports about the brief.
  bool briefDelivered = true;

  /// When set, [launch] waits for it before returning — the in-flight window
  /// a second launch must not slip into.
  Completer<void>? launchGate;

  @override
  Future<VoiceLaunch> launch({
    required String kind,
    required String cwd,
    required String brief,
  }) async {
    if (launchError != null) throw launchError!;
    launched.add((kind, cwd, brief));
    await launchGate?.future;
    return (paneId: 'w:new', title: kind, briefDelivered: briefDelivered);
  }
}
