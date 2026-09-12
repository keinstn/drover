import 'package:firebase_ai/firebase_ai.dart';

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

/// The tools drover exposes to the voice assistant for one herdr host.
///
/// Sending is two-step (draft_message, then send_message with the draft id)
/// so the app, not the model's narration, decides whether a message went
/// out: on device the model was observed saying "sent" without ever calling
/// the tool.
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
        if (draft == null) {
          return {'error': 'unknown draft_id $id; call draft_message first'};
        }
        if (!drafts.isPending(draft)) {
          // Already delivered (by an earlier call or the screen's Send
          // button): never send twice, and let the model say so.
          return {'error': 'draft $id was already sent; do not send it again'};
        }
        // A throw here propagates as an error payload and leaves the draft
        // pending, so the user can still send it from the screen.
        await herd.send(draft.agent, draft.message);
        drafts.markSent(draft);
        return {
          'sent': true,
          'agent': voiceAgentTitle(draft.agent),
          'message': draft.message,
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
