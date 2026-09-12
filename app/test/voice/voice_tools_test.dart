import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:drover/src/voice/voice_tools.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRunner extends CommandRunner {
  _FakeRunner(this.stdout);

  final String stdout;
  final commands = <String>[];

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
    return CommandResult(exitCode: 0, stdout: stdout, stderr: '');
  }

  @override
  Future<void> uploadFile(String remotePath, List<int> bytes) async {}

  @override
  Future<List<RemoteDirEntry>> listDirectory(String path) async => [];

  @override
  Future<String> resolvePath(String path) async => path;

  @override
  Future<void> dispose() async {}
}

const _agentList =
    '{"id":"1","result":{"agents":['
    '{"agent":"claude","agent_status":"blocked","cwd":"/tmp/proj",'
    '"focused":false,"pane_id":"wB:p1","tab_id":"wB:t1","workspace_id":"wB",'
    '"terminal_title_stripped":"Implement the OAuth callback"},'
    '{"agent":"codex","name":"Reviewer","agent_status":"idle","cwd":"/tmp/x",'
    '"focused":false,"pane_id":"wB:p2","tab_id":"wB:t1","workspace_id":"wB"},'
    '{"agent":null,"agent_status":"working","cwd":"/tmp/y",'
    '"focused":false,"pane_id":"wB:p3","tab_id":"wB:t2","workspace_id":"wB"}'
    ']}}';

void main() {
  group('droverVoiceTools', () {
    test('exposes exactly list_agents, with no parameters', () {
      final tools = droverVoiceTools(HerdrClient(_FakeRunner(_agentList)));
      expect(tools.map((t) => t.name), ['list_agents']);
      expect(tools.single.parameters, isEmpty);
    });

    test('list_agents returns title/kind/status/project per agent', () async {
      final runner = _FakeRunner(_agentList);
      final tool = droverVoiceTools(HerdrClient(runner)).single;

      final result = await tool.run({});

      expect(runner.commands.single, contains("'agent' 'list'"));
      expect(result, {
        'agents': [
          {
            'title': 'Implement the OAuth callback',
            'kind': 'claude',
            'status': 'blocked',
            'project': 'proj',
          },
          {
            'title': 'Reviewer',
            'kind': 'codex',
            'status': 'idle',
            'project': 'x',
          },
          {'title': 'agent', 'kind': null, 'status': 'working', 'project': 'y'},
        ],
      });
    });
  });

  group('runVoiceToolCalls', () {
    final tools = [
      VoiceTool(
        name: 'ok',
        description: '',
        parameters: const {},
        run: (args) async => {'echo': args['x']},
      ),
      VoiceTool(
        name: 'boom',
        description: '',
        parameters: const {},
        run: (_) async => throw StateError('nope'),
      ),
    ];

    test('runs known tools and keeps the call id', () async {
      final responses = await runVoiceToolCalls([
        const FunctionCall('ok', {'x': 1}, id: 'c1'),
      ], tools);

      expect(responses.single.name, 'ok');
      expect(responses.single.id, 'c1');
      expect(responses.single.response, {'echo': 1});
    });

    test('unknown tool yields an error payload with the call id', () async {
      final responses = await runVoiceToolCalls([
        const FunctionCall('nah', {}, id: 'c2'),
      ], tools);

      expect(responses.single.id, 'c2');
      expect(responses.single.response, {'error': 'unknown tool nah'});
    });

    test('a throwing handler yields an error payload, not a throw', () async {
      final responses = await runVoiceToolCalls([
        const FunctionCall('boom', {}, id: 'c3'),
      ], tools);

      expect(responses.single.id, 'c3');
      expect(responses.single.response['error'], contains('nope'));
    });
  });

  test('voiceToolsToFirebase declares every tool', () {
    final tool = voiceToolsToFirebase(
      droverVoiceTools(HerdrClient(_FakeRunner(_agentList))),
    );
    final json = tool.toJson() as Map<String, Object?>;
    final decls = json['functionDeclarations'] as List<Object?>;
    expect(decls, hasLength(1));
    expect((decls.single as Map<String, Object?>)['name'], 'list_agents');
  });
}
