import 'package:firebase_ai/firebase_ai.dart';

import '../models/agent_preset.dart';
import '../utils/path.dart';
import 'voice_drafts.dart';
import 'voice_herd.dart';

/// One function the voice model may call.
///
/// Data-boundary rule: tool results cross into Google's Gemini Live API, so
/// they carry only agent status and short prose — never raw terminal output,
/// transcripts, code or full paths (a project is named by its folder only).
/// Keep that promise in every tool added here; the settings copy tells the
/// user exactly this.
class VoiceTool {
  const VoiceTool({
    required this.name,
    required this.description,
    required this.parameters,
    this.optionalParameters = const [],
    required this.run,
  });

  final String name;
  final String description;
  final Map<String, Schema> parameters;

  /// Names in [parameters] the model may omit.
  final List<String> optionalParameters;
  final Future<Map<String, Object?>> Function(Map<String, Object?> args) run;
}

/// The agent kinds [droverVoiceTools] accepts, for prompts and errors.
final _kinds = kAgentPresets.map((p) => p.kind).join(', ');

/// The tools drover exposes to the voice assistant for one herdr host.
///
/// Sending and launching are two-step (draft_message / draft_launch, then
/// send_message / launch with the draft id) so the app, not the model's
/// narration, decides whether anything happened: on device the model was
/// observed saying "sent" without ever calling the tool.
List<VoiceTool> droverVoiceTools(VoiceHerd herd, VoiceDrafts drafts) {
  final agentParam = Schema.string(
    description: 'The agent, by its title, name or kind (e.g. "claude").',
  );
  return [
    VoiceTool(
      name: 'list_agents',
      description:
          'Lists the coding agents running on the herdr host with their '
          'status (idle, working, blocked, done) and project folder name.',
      parameters: const {},
      run: (_) async => {
        'agents': [
          for (final a in herd.agents)
            {
              'title': voiceAgentTitle(a),
              'kind': a.agent,
              'status': a.status.name,
              'project': lastPathSegment(a.foregroundCwd ?? a.cwd),
            },
        ],
      },
    ),
    VoiceTool(
      name: 'read_agent',
      description:
          'Reads one agent: its status and the text of its last reply, if '
          'it has replied since the user last wrote to it.',
      parameters: {'agent': agentParam},
      run: (args) async {
        final agent = resolveAgent(herd.agents, '${args['agent']}');
        return {
          'agent': voiceAgentTitle(agent),
          'status': agent.status.name,
          'last_reply': await herd.lastReply(agent),
        };
      },
    ),
    VoiceTool(
      name: 'draft_message',
      description:
          'Prepare a message for an agent. Nothing is sent yet. Read the '
          'returned message back to the user word for word and ask for '
          'confirmation; after an explicit yes call send_message with the '
          'draft_id.',
      parameters: {
        'agent': agentParam,
        'message': Schema.string(
          description: "The message, in the user's own words and language.",
        ),
      },
      run: (args) async {
        final agent = resolveAgent(herd.agents, '${args['agent']}');
        final draft = drafts.add(agent, '${args['message']}');
        return {
          'draft_id': draft.id,
          'agent': voiceAgentTitle(agent),
          'message': draft.message,
        };
      },
    ),
    VoiceTool(
      name: 'send_message',
      description:
          'Sends a drafted message to its agent, like leaving voicemail. '
          'Call ONLY after the user explicitly confirmed the read-back. The '
          'message is sent only when this returns sent: true.',
      parameters: {
        'draft_id': Schema.string(
          description: 'The draft_id returned by draft_message.',
        ),
      },
      run: (args) async {
        final id = '${args['draft_id']}';
        final draft = drafts.byId(id);
        if (draft is! MessageDraft) {
          return {'error': 'unknown draft_id $id; call draft_message first'};
        }
        if (!drafts.isPending(draft)) {
          // Already delivered (by an earlier call or the screen's Send
          // button): never send twice, and let the model say so.
          return {'error': 'draft $id was already sent; do not send it again'};
        }
        if (drafts.isBusy(draft)) {
          return {'error': 'draft $id is already being sent; wait for it'};
        }
        // A throw here propagates as an error payload and leaves the draft
        // pending, so the user can still send it from the screen.
        drafts.markBusy(draft);
        try {
          await herd.send(draft.agent, draft.message);
          drafts.markSent(draft);
        } finally {
          drafts.release(draft);
        }
        return {
          'sent': true,
          'agent': voiceAgentTitle(draft.agent),
          'message': draft.message,
        };
      },
    ),
    VoiceTool(
      name: 'draft_launch',
      description:
          'Prepare to start a NEW coding agent on a project, with a brief '
          'describing its task. Nothing is started yet. Summarise the '
          'returned brief in one sentence, say the full text is on screen, '
          'and ask for confirmation; after an explicit yes call launch with '
          'the draft_id.',
      parameters: {
        'project': Schema.string(
          description:
              'The project folder name, as list_agents reports it. Only a '
              'folder some agent already runs in can be named by voice.',
        ),
        'brief': Schema.string(
          description:
              'The task for the new agent, written as a brief for a coding '
              "agent in the user's language. May be several sentences.",
        ),
        'kind': Schema.string(
          description:
              'The agent kind: $_kinds. Defaults to claude when omitted.',
        ),
      },
      optionalParameters: const ['kind'],
      run: (args) async {
        final kind = args['kind'] is String && '${args['kind']}'.isNotEmpty
            ? '${args['kind']}'
            : 'claude';
        if (!kAgentPresets.any((p) => p.kind == kind)) {
          return {'error': 'unknown kind $kind; kinds: $_kinds'};
        }
        final String cwd;
        try {
          cwd = resolveProjectCwd(herd.agents, '${args['project']}');
        } on VoiceAgentLookupError catch (e) {
          return {'error': e.message};
        }
        final draft = drafts.addLaunch(
          kind: kind,
          cwd: cwd,
          brief: '${args['brief']}',
        );
        return {
          'draft_id': draft.id,
          'kind': kind,
          'project': lastPathSegment(cwd),
          'brief': draft.brief,
        };
      },
    ),
    VoiceTool(
      name: 'launch',
      description:
          'Starts the drafted agent and hands it its brief. Call ONLY after '
          'the user explicitly confirmed. The agent is started only when '
          'this returns launched: true; brief_delivered false means it is '
          'running but never got the brief.',
      parameters: {
        'draft_id': Schema.string(
          description: 'The draft_id returned by draft_launch.',
        ),
      },
      run: (args) async {
        final id = '${args['draft_id']}';
        final draft = drafts.byId(id);
        if (draft is! LaunchDraft) {
          return {'error': 'unknown draft_id $id; call draft_launch first'};
        }
        if (!drafts.isPending(draft)) {
          // Already launched (here or from the screen's Launch button):
          // never start a second agent for the same draft.
          return {
            'error': 'draft $id was already launched; do not launch it again',
          };
        }
        if (drafts.isBusy(draft)) {
          return {'error': 'draft $id is already being launched; wait for it'};
        }
        // A throw here propagates as an error payload and leaves the draft
        // pending, so the user can still launch it from the screen. The busy
        // flag covers the launch's own bounded wait for the agent to come up,
        // which is far too long a window to leave the screen's button live.
        drafts.markBusy(draft);
        final VoiceLaunch launched;
        try {
          launched = await herd.launch(
            kind: draft.kind,
            cwd: draft.cwd,
            brief: draft.brief,
          );
          drafts.markSent(draft);
        } finally {
          drafts.release(draft);
        }
        return {
          'launched': true,
          'agent': launched.title,
          'project': lastPathSegment(draft.cwd),
          'brief_delivered': launched.briefDelivered,
        };
      },
    ),
    VoiceTool(
      name: 'answer_question',
      description:
          'Answers the question an agent is waiting on, either by option '
          'number or with free text. Give exactly one of the two.',
      parameters: {
        'agent': agentParam,
        'option_number': Schema.integer(
          description: 'The 1-based number of the option the user chose.',
        ),
        'text': Schema.string(description: 'A free-text answer instead.'),
      },
      optionalParameters: const ['option_number', 'text'],
      run: (args) async {
        final agent = resolveAgent(herd.agents, '${args['agent']}');
        final question = await herd.pendingQuestion(agent);
        if (question == null) {
          return {'error': 'agent is not waiting on a question'};
        }
        final option = args['option_number'];
        final text = args['text'];
        await herd.answer(
          agent,
          question,
          option: option is num ? option.toInt() : null,
          text: text is String && text.isNotEmpty ? text : null,
        );
        return {'answered': true};
      },
    ),
  ];
}

/// Converts [tools] into the single function-declarations [Tool] the live
/// model is configured with.
Tool voiceToolsToFirebase(List<VoiceTool> tools) => Tool.functionDeclarations([
  for (final t in tools)
    FunctionDeclaration(
      t.name,
      t.description,
      parameters: t.parameters,
      optionalParameters: t.optionalParameters,
    ),
]);

/// Runs every call in [calls] against [tools]. Never throws: an unknown tool
/// or a throwing handler becomes an `{'error': ...}` payload so the model can
/// recover in conversation. Each response keeps the call's id.
Future<List<FunctionResponse>> runVoiceToolCalls(
  List<FunctionCall> calls,
  List<VoiceTool> tools,
) async {
  final responses = <FunctionResponse>[];
  for (final call in calls) {
    Map<String, Object?> result;
    final tool = tools.where((t) => t.name == call.name).firstOrNull;
    if (tool == null) {
      result = {'error': 'unknown tool ${call.name}'};
    } else {
      try {
        result = await tool.run(call.args);
      } catch (e) {
        result = {'error': '$e'};
      }
    }
    responses.add(FunctionResponse(call.name, result, id: call.id));
  }
  return responses;
}
