import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../agents/agent_adapter.dart';
import '../agents/agent_registry.dart';
import '../herdr/ansi_text.dart';
import '../herdr/herdr_client.dart';
import '../herdr/pane_text.dart';
import '../models/agent_info.dart';
import '../models/agent_preset.dart';
import '../transcript/native_transcript.dart';
import '../utils/path.dart';

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

  /// Starts a [kind] agent in [cwd] and hands it [brief] as its first
  /// prompt. Returns the new agent's pane and speakable title, and whether
  /// the brief was confirmed to have landed in its pane.
  Future<VoiceLaunch> launch({
    required String kind,
    required String cwd,
    required String brief,
  });
}

/// What [VoiceHerd.launch] produced: the started agent, plus whether its
/// brief was confirmed delivered (false means the agent is up but empty, so
/// the brief still has to be sent as a message).
typedef VoiceLaunch = ({String paneId, String title, bool briefDelivered});

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

/// The distinct working directories of [agents], keyed by folder name.
///
/// `foregroundCwd ?? cwd` — the same directory `list_agents` names the project
/// after and the launch sheet offers, so a folder the model spoke always
/// resolves back to the directory the user heard.
Map<String, Set<String>> _projectCwds(List<AgentInfo> agents) {
  final byFolder = <String, Set<String>>{};
  for (final agent in agents) {
    final cwd = agent.foregroundCwd ?? agent.cwd;
    byFolder.putIfAbsent(lastPathSegment(cwd).toLowerCase(), () => {}).add(cwd);
  }
  return byFolder;
}

/// Resolves a spoken project [query] to a working directory, case-insensitively
/// against the folder names of [agents]' working directories.
///
/// ponytail: voice can only name a folder that some agent already runs in —
/// dictating a path is hopeless, and probing the host's filesystem is a
/// screen feature. New folders stay in the launch sheet.
String resolveProjectCwd(List<AgentInfo> agents, String query) {
  final byFolder = _projectCwds(agents);
  final folders = byFolder.keys.join(', ');
  final cwds = byFolder[query.trim().toLowerCase()];
  if (cwds == null) {
    throw VoiceAgentLookupError(
      'no project folder matches "$query"; projects: $folders',
    );
  }
  if (cwds.length > 1) {
    throw VoiceAgentLookupError(
      'several projects are called "$query"; start it from the app. '
      'projects: $folders',
    );
  }
  return cwds.single;
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

/// Whether [pane] shows [brief], compared without any whitespace: a pane
/// hard-wraps mid-word and repaints, so neither line breaks nor the terminal
/// width can be relied on. Only the head of the brief is looked for — enough
/// to tell "prompt landed" from "pane still empty".
///
/// ponytail: the cost of a false negative is one duplicated prompt, which is
/// why the check is this loose; tighten it if double delivery is ever seen.
bool _paneHasBrief(String pane, String brief) {
  String squeeze(String s) => s.replaceAll(RegExp(r'\s+'), '');
  final fragment = squeeze(brief);
  if (fragment.isEmpty) return true;
  final head = fragment.length > 30 ? fragment.substring(0, 30) : fragment;
  return squeeze(stripAnsi(pane)).contains(head);
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
    this._sleep = Future.delayed,
  }) : _client = client,
       _readPane = readPane ?? client.readAgent;

  final HerdrClient _client;
  final List<AgentInfo> Function() _agents;
  final Future<NativeTranscript?> Function(AgentInfo) _loadTranscript;
  final Future<String> Function(String paneId) _readPane;
  final AgentAdapter? Function(AgentInfo) _adapterFor;
  final Future<void> Function(Duration) _sleep;

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

  /// How many polls a freshly started agent gets to show up as idle (one
  /// sleep plus one `agent list` round trip each, so at least a minute in
  /// wall clock), and how long its brief gets to appear in the pane before it
  /// is checked for.
  ///
  /// ponytail: fixed ceilings — a host slower than that to boot an agent gets
  /// `briefDelivered: false` and the user is told to send the brief as a
  /// message.
  static const _idleWaitPolls = 60;
  static const _idleWaitStep = Duration(seconds: 1);
  static const _briefCheckDelay = Duration(seconds: 3);

  @override
  Future<VoiceLaunch> launch({
    required String kind,
    required String cwd,
    required String brief,
  }) async {
    final preset = kAgentPresets.where((p) => p.kind == kind).firstOrNull;
    final name = preset?.bin ?? kind;
    final folder = lastPathSegment(cwd);
    final workspace = await _client.createWorkspace(label: folder, cwd: cwd);
    try {
      await _client.startAgent(
        name: name,
        kind: kind,
        paneId: workspace.paneId,
      );
    } catch (_) {
      // Same rollback as the launch sheet: never leave an empty workspace
      // behind for a start that failed.
      try {
        await _client.closeWorkspace(workspace.workspaceId);
      } catch (_) {}
      rethrow;
    }
    final paneId = workspace.paneId;
    final agent = await _awaitIdle(paneId);
    final title = agent == null ? name : voiceAgentTitle(agent);
    // Not idle within the bound: prompting now is exactly the send herdr
    // drops, so hand the brief back to the caller instead.
    if (agent == null) {
      return (paneId: paneId, title: title, briefDelivered: false);
    }
    var delivered = await _deliverBrief(paneId, brief);
    // herdr can silently drop a prompt sent right after `agent start`, even
    // with the status already reading idle (docs/herdr-notes.md), so the
    // pane is re-read and the brief sent once more if it is not there.
    if (!delivered) delivered = await _deliverBrief(paneId, brief);
    return (paneId: paneId, title: title, briefDelivered: delivered);
  }

  /// Polls until [paneId] is listed as an idle agent; null once the poll
  /// budget is spent. Sleeps before the first check: the pane cannot be idle
  /// the instant `agent start` returns.
  Future<AgentInfo?> _awaitIdle(String paneId) async {
    for (var poll = 0; poll < _idleWaitPolls; poll++) {
      await _sleep(_idleWaitStep);
      final agent = (await _client.listAgents())
          .where((a) => a.paneId == paneId)
          .firstOrNull;
      if (agent != null && agent.status == AgentStatus.idle) return agent;
    }
    return null;
  }

  /// Prompts [brief] into [paneId] and reports whether it then shows up in
  /// the pane.
  Future<bool> _deliverBrief(String paneId, String brief) async {
    await _client.prompt(paneId, brief);
    await _sleep(_briefCheckDelay);
    return _paneHasBrief(await _readPane(paneId), brief);
  }
}
