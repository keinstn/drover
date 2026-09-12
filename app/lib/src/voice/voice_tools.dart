import 'package:firebase_ai/firebase_ai.dart';

import '../herdr/herdr_client.dart';
import '../utils/path.dart';

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
    required this.run,
  });

  final String name;
  final String description;
  final Map<String, Schema> parameters;
  final Future<Map<String, Object?>> Function(Map<String, Object?> args) run;
}

/// The tools drover exposes to the voice assistant for one herdr host.
List<VoiceTool> droverVoiceTools(HerdrClient client) => [
  VoiceTool(
    name: 'list_agents',
    description:
        'Lists the coding agents running on the herdr host with their '
        'status (idle, working, blocked, done) and project folder name.',
    parameters: const {},
    run: (_) async {
      final agents = await client.listAgents();
      return {
        'agents': [
          for (final a in agents)
            {
              'title': a.sessionTitle ?? a.name ?? a.agent ?? 'agent',
              'kind': a.agent,
              'status': a.status.name,
              'project': lastPathSegment(a.foregroundCwd ?? a.cwd),
            },
        ],
      };
    },
  ),
];

/// Converts [tools] into the single function-declarations [Tool] the live
/// model is configured with.
Tool voiceToolsToFirebase(List<VoiceTool> tools) => Tool.functionDeclarations([
  for (final t in tools)
    FunctionDeclaration(t.name, t.description, parameters: t.parameters),
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
