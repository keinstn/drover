import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/voice/voice_herd.dart';
import 'package:drover/src/voice/voice_tools.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

final _agents = [
  fakeAgent(
    paneId: 'wB:p1',
    kind: 'claude',
    status: AgentStatus.blocked,
    title: 'Implement the OAuth callback',
  ),
  fakeAgent(
    paneId: 'wB:p2',
    kind: 'codex',
    name: 'Reviewer',
    status: AgentStatus.idle,
    cwd: '/tmp/x',
  ),
  fakeAgent(
    paneId: 'wB:p3',
    kind: null,
    status: AgentStatus.working,
    cwd: '/tmp/y',
  ),
];

void main() {
  group('droverVoiceTools', () {
    late FakeVoiceHerd herd;
    late List<VoiceTool> tools;

    VoiceTool tool(String name) => tools.singleWhere((t) => t.name == name);

    setUp(() {
      herd = FakeVoiceHerd(agents: _agents);
      tools = droverVoiceTools(herd);
    });

    test('exposes the four tools; only answer_question has optionals', () {
      expect(tools.map((t) => t.name), [
        'list_agents',
        'read_agent',
        'send_message',
        'answer_question',
      ]);
      expect(tool('list_agents').parameters, isEmpty);
      expect(tool('answer_question').optionalParameters, [
        'option_number',
        'text',
      ]);
      expect(tool('send_message').description, contains('voicemail'));
    });

    test('list_agents returns title/kind/status/project per agent', () async {
      final result = await tool('list_agents').run({});

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

    test('read_agent returns status and the last reply', () async {
      herd.replies['wB:p2'] = 'Looks good.';
      expect(await tool('read_agent').run({'agent': 'reviewer'}), {
        'agent': 'Reviewer',
        'status': 'idle',
        'last_reply': 'Looks good.',
      });
      expect(
        (await tool('read_agent').run({'agent': 'oauth'}))['last_reply'],
        isNull,
      );
    });

    test('send_message sends to the resolved agent', () async {
      final result = await tool(
        'send_message',
      ).run({'agent': 'claude', 'message': 'add tests too'});

      expect(result, {'sent': true, 'agent': 'Implement the OAuth callback'});
      expect(herd.sent.single.$1.paneId, 'wB:p1');
      expect(herd.sent.single.$2, 'add tests too');
    });

    test('answer_question answers by option number', () async {
      const question = AgentQuestion(question: 'Go?', options: ['Yes', 'No']);
      herd.questions['wB:p1'] = question;

      final result = await tool(
        'answer_question',
      ).run({'agent': 'claude', 'option_number': 2});

      expect(result, {'answered': true});
      expect(herd.answered.single, (_agents[0], question, 2, null));
    });

    test('answer_question reports an agent with nothing pending', () async {
      expect(
        await tool('answer_question').run({'agent': 'codex', 'text': 'x'}),
        {'error': 'agent is not waiting on a question'},
      );
      expect(herd.answered, isEmpty);
    });

    test('an unknown agent becomes a readable error payload', () async {
      final responses = await runVoiceToolCalls([
        const FunctionCall('send_message', {
          'agent': 'gemini',
          'message': 'hi',
        }, id: 'c9'),
      ], tools);

      expect(
        responses.single.response['error'],
        'no agent matches "gemini"; agents: Implement the OAuth callback, '
        'Reviewer, agent',
      );
      expect(herd.sent, isEmpty);
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
    final tool = voiceToolsToFirebase(droverVoiceTools(FakeVoiceHerd()));
    final json = tool.toJson() as Map<String, Object?>;
    final decls = json['functionDeclarations'] as List<Object?>;
    expect(decls.map((d) => (d as Map<String, Object?>)['name']), [
      'list_agents',
      'read_agent',
      'send_message',
      'answer_question',
    ]);
  });
}
