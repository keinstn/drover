import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../agents/agent_adapter.dart';
import '../agents/agent_registry.dart';
import '../herdr/ansi_text.dart';
import '../herdr/herdr_client.dart';
import '../herdr/pane_text.dart';
import '../models/agent_info.dart';
import '../transcript/native_transcript.dart';

enum AgentEventKind { finished, blocked }

/// A status transition worth telling the voice user about.
class AgentEvent {
  const AgentEvent(this.kind, this.agent);

  final AgentEventKind kind;
  final AgentInfo agent;
}

/// What an agent is waiting on: a structured prompt or a numbered pane
/// prompt. Option N is `options[N - 1]`.
class AgentQuestion {
  const AgentQuestion({
    required this.question,
    required this.options,
    this.prompt,
    this.questionCount = 1,
  });

  /// The first question's text (structured) or the parsed prompt's heading;
  /// may be empty.
  final String question;
  final List<String> options;

  /// Non-null when the question comes from a [StructuredPromptCapability].
  final StructuredPrompt? prompt;

  /// Structured prompts can carry several questions; a pane prompt has one.
  final int questionCount;
}

/// The voice layer's view of one host's herd: everything the tools and the
/// callback announcer need. Faked in tests.
abstract interface class VoiceHerd {
  /// Latest poll snapshot.
  List<AgentInfo> get agents;

  /// The agent's last assistant prose, made speakable, or null if none.
  Future<String?> lastReply(AgentInfo agent);

  Future<AgentQuestion?> pendingQuestion(AgentInfo agent);

  Future<void> send(AgentInfo agent, String text);

  Future<void> answer(
    AgentInfo agent,
    AgentQuestion question, {
    int? option,
    String? text,
  });
}

/// Unannounced agent events for one host. HerdScreen adds; VoiceSession
/// drains.
class VoiceInbox extends ChangeNotifier {
  final _pending = <AgentEvent>[];
  final _events = StreamController<AgentEvent>.broadcast();

  List<AgentEvent> get pending => UnmodifiableListView(_pending);

  /// Every [add] also emits here, whether or not it replaced a pending one.
  Stream<AgentEvent> get events => _events.stream;

  /// Queues [event], replacing an older pending event for the same pane so
  /// the latest state wins.
  void add(AgentEvent event) {
    _pending.removeWhere((e) => e.agent.paneId == event.agent.paneId);
    _pending.add(event);
    notifyListeners();
    _events.add(event);
  }

  /// Returns and clears the pending events.
  List<AgentEvent> drain() {
    final drained = List<AgentEvent>.unmodifiable(_pending);
    _pending.clear();
    notifyListeners();
    return drained;
  }

  @override
  void dispose() {
    _events.close();
    super.dispose();
  }
}

/// Thrown by [resolveAgent] when a spoken name matches no agent, or several.
class VoiceAgentLookupError implements Exception {
  const VoiceAgentLookupError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// How an agent is named in speech and tool payloads.
String voiceAgentTitle(AgentInfo agent) =>
    agent.sessionTitle ?? agent.name ?? agent.agent ?? 'agent';

/// Finds the agent the user meant by [query], case-insensitively: an exact
/// match on session title, name or kind wins; otherwise a unique substring
/// match on those.
AgentInfo resolveAgent(List<AgentInfo> agents, String query) {
  final q = query.trim().toLowerCase();
  List<String> namesOf(AgentInfo a) => [
    for (final n in [a.sessionTitle, a.name, a.agent])
      if (n != null) n.toLowerCase(),
  ];
  final exact = agents.where((a) => namesOf(a).contains(q)).toList();
  if (exact.length == 1) return exact.single;
  final matches = exact.isNotEmpty
      ? exact
      : agents.where((a) => namesOf(a).any((n) => n.contains(q))).toList();
  String titles(List<AgentInfo> list) => list.map(voiceAgentTitle).join(', ');
  if (matches.isEmpty) {
    throw VoiceAgentLookupError(
      'no agent matches "$query"; agents: ${titles(agents)}',
    );
  }
  if (matches.length > 1) {
    throw VoiceAgentLookupError('ambiguous: ${titles(matches)}');
  }
  return matches.single;
}

const _speakableMax = 600;
final _fence = RegExp(r'```[\s\S]*?(```|$)');
final _lineMarkers = RegExp(
  r'^\s*(#{1,6}\s+|[-*+]\s+|\d+[.)]\s+)',
  multiLine: true,
);

/// Markdown prose reduced to something a voice can read: code fences are
/// replaced by "(code omitted)", heading markers and list bullets dropped,
/// whitespace collapsed, and the result capped at 600 characters.
String speakable(String text) {
  var s = text.replaceAll(_fence, ' (code omitted) ');
  s = s.replaceAll(_lineMarkers, '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.length > _speakableMax) s = '${s.substring(0, _speakableMax)}…';
  return s;
}

/// One text block for the model, one paragraph per event, each starting with
/// "[event]" so the system prompt can tell it apart from the user's speech.
Future<String> announceEvents(List<AgentEvent> events, VoiceHerd herd) async {
  final paragraphs = <String>[];
  for (final event in events) {
    final agent = event.agent;
    final who = 'Agent "${voiceAgentTitle(agent)}" (${agent.agent ?? 'agent'})';
    switch (event.kind) {
      case AgentEventKind.finished:
        final reply = await herd.lastReply(agent) ?? 'no reply text';
        paragraphs.add('[event] $who finished. Last reply: "$reply"');
      case AgentEventKind.blocked:
        final question = await herd.pendingQuestion(agent);
        if (question == null) {
          paragraphs.add(
            '[event] $who is blocked waiting for input the app could not '
            'parse; tell the user to open it in the app.',
          );
          continue;
        }
        final options = [
          for (var i = 0; i < question.options.length; i++)
            '${i + 1}) ${question.options[i]}',
        ].join(' ');
        final more = question.questionCount > 1
            ? ' This prompt has ${question.questionCount} questions; only the '
                  'first can be answered by voice.'
            : '';
        paragraphs.add(
          '[event] $who is waiting for you. Question: "${question.question}" '
          'Options: $options Ask the user which option (or a free-text '
          'answer), then call answer_question.$more',
        );
    }
  }
  return paragraphs.join('\n\n');
}

/// [VoiceHerd] over a real [HerdrClient] plus HerdScreen's poll snapshot and
/// per-pane native history.
class HerdVoiceHerd implements VoiceHerd {
  HerdVoiceHerd({
    required HerdrClient client,
    required this._agents,
    required this._loadTranscript,
    Future<String> Function(String paneId)? readPane,
    this._adapterFor = resolveAgentAdapter,
  }) : _client = client,
       _readPane = readPane ?? client.readAgent;

  final HerdrClient _client;
  final List<AgentInfo> Function() _agents;
  final Future<NativeTranscript?> Function(AgentInfo) _loadTranscript;
  final Future<String> Function(String paneId) _readPane;
  final AgentAdapter? Function(AgentInfo) _adapterFor;

  @override
  List<AgentInfo> get agents => _agents();

  @override
  Future<String?> lastReply(AgentInfo agent) async {
    final transcript = await _loadTranscript(agent);
    // The newest message must be the agent's: a trailing user message means
    // the agent has not replied to it yet.
    final last = transcript?.entries.whereType<TranscriptMessage>().lastOrNull;
    if (last == null || last.speaker != TranscriptSpeaker.assistant) {
      return null;
    }
    return speakable(last.text);
  }

  @override
  Future<AgentQuestion?> pendingQuestion(AgentInfo agent) async {
    final capability = _adapterFor(agent)?.structuredPrompt;
    if (capability != null) {
      final transcript = await _loadTranscript(agent);
      final prompt = transcript == null
          ? null
          : capability.pendingPrompt(transcript);
      if (prompt != null && prompt.questions.isNotEmpty) {
        final first = prompt.questions.first;
        return AgentQuestion(
          question: first.question,
          options: [for (final o in first.options) o.label],
          prompt: prompt,
          questionCount: prompt.questions.length,
        );
      }
    }
    final parsed = parsePromptOptions(stripAnsi(await _readPane(agent.paneId)));
    if (parsed == null) return null;
    return AgentQuestion(
      question: parsed.question ?? '',
      options: [for (final o in parsed.options) o.label],
    );
  }

  @override
  Future<void> send(AgentInfo agent, String text) =>
      _client.prompt(agent.paneId, text);

  @override
  Future<void> answer(
    AgentInfo agent,
    AgentQuestion question, {
    int? option,
    String? text,
  }) async {
    if ((option == null) == (text == null)) {
      throw ArgumentError('give exactly one of option or text');
    }
    if (option != null) {
      RangeError.checkValueInInterval(
        option,
        1,
        question.options.length,
        'option',
      );
    }
    final prompt = question.prompt;
    if (prompt == null) {
      await _client.prompt(agent.paneId, option != null ? '$option' : text!);
      return;
    }
    // ponytail: only the first question of a multi-question prompt is read
    // out, and Claude's submitter needs every question answered in order —
    // so those stay in the app until the voice flow can walk all of them.
    if (question.questionCount > 1) {
      throw StateError('multi-question prompts must be answered in the app');
    }
    await _adapterFor(agent)!.structuredPrompt!.submit(
      client: _client,
      paneId: agent.paneId,
      prompt: prompt,
      answers: [
        StructuredPromptAnswer(
          selectedIndexes: option != null ? [option - 1] : const [],
          customText: text,
        ),
      ],
    );
  }
}
