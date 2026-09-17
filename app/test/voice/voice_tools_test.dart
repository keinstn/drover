import 'dart:async';

import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/voice/voice_drafts.dart';
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
    late VoiceDrafts drafts;
    late List<VoiceTool> tools;

    VoiceTool tool(String name) => tools.singleWhere((t) => t.name == name);

    setUp(() {
      herd = FakeVoiceHerd(agents: _agents);
      drafts = VoiceDrafts();
      tools = droverVoiceTools(herd, drafts);
    });

    tearDown(() => drafts.dispose());

    test('exposes the seven tools; only some parameters are optional', () {
      expect(tools.map((t) => t.name), [
        'list_agents',
        'read_agent',
        'draft_message',
        'send_message',
        'draft_launch',
        'launch',
        'answer_question',
      ]);
      expect(tool('draft_launch').optionalParameters, ['kind']);
      expect(tool('list_agents').parameters, isEmpty);
      expect(tool('answer_question').optionalParameters, isEmpty);
      expect(tool('draft_message').description, contains('Nothing is sent'));
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

    test('draft_message stores a pending draft and echoes it', () async {
      final result = await tool(
        'draft_message',
      ).run({'agent': 'claude', 'message': 'add tests too'});

      expect(result, {
        'draft_id': 'd1',
        'agent': 'Implement the OAuth callback',
        'message': 'add tests too',
      });
      final draft = drafts.pending.single as MessageDraft;
      expect(draft.message, 'add tests too');
      expect(draft.agent.paneId, 'wB:p1');
      expect(herd.sent, isEmpty);
    });

    test('send_message delivers the draft and marks it sent', () async {
      await tool(
        'draft_message',
      ).run({'agent': 'claude', 'message': 'add tests too'});

      final result = await tool('send_message').run({'draft_id': 'd1'});

      expect(result, {
        'sent': true,
        'agent': 'Implement the OAuth callback',
        'message': 'add tests too',
      });
      expect(herd.sent.single.$1.paneId, 'wB:p1');
      expect(herd.sent.single.$2, 'add tests too');
      expect(drafts.pending, isEmpty);
    });

    test('send_message with an unknown id sends nothing', () async {
      final result = await tool('send_message').run({'draft_id': 'd7'});

      expect(result['error'], contains('unknown draft_id d7'));
      expect(herd.sent, isEmpty);
    });

    test('a failed send keeps the draft pending', () async {
      await tool('draft_message').run({'agent': 'claude', 'message': 'hi'});
      herd.sendError = StateError('ssh down');

      final responses = await runVoiceToolCalls([
        const FunctionCall('send_message', {'draft_id': 'd1'}, id: 'c5'),
      ], tools);

      // The model is told it failed and nothing else: an unrecognised error
      // is reduced to its type, so the host's own words cannot cross.
      expect(responses.single.response['error'], 'StateError');
      expect(responses.single.response['error'], isNot(contains('ssh down')));
      expect(drafts.pending, hasLength(1));
    });

    test('a herdr failure sends the code, never the host stderr', () async {
      await tool('draft_message').run({'agent': 'claude', 'message': 'hi'});
      // Shaped exactly like HerdrClient._exec's transport fallback, whose
      // message embeds the raw stderr of the command it ran.
      herd.sendError = const HerdrException(
        'agent_pane_busy',
        "herdr 'agent' 'prompt' failed (exit 1): "
            '/Users/kei/Projects/drover/app: permission denied',
      );

      final responses = await runVoiceToolCalls([
        const FunctionCall('send_message', {'draft_id': 'd1'}, id: 'c5b'),
      ], tools);

      final error = '${responses.single.response['error']}';
      expect(error, 'agent_pane_busy', reason: 'the coded reason, on its own');
      expect(error, isNot(contains('/Users/kei')));
      expect(error, isNot(contains('permission denied')));
      expect(error, isNot(contains('exit 1')));
      expect(drafts.pending, hasLength(1));
    });

    test('answer_question answers every question in one call', () async {
      const question = AgentQuestion(
        questions: [
          VoiceQuestion(question: 'Go?', options: ['Yes', 'No']),
          VoiceQuestion(
            question: 'Which?',
            options: ['lib', 'test'],
            multiSelect: true,
          ),
        ],
      );
      herd.questions['wB:p1'] = question;

      final result = await tool('answer_question').run({
        'agent': 'claude',
        'answers': [
          {
            'option_numbers': [2],
          },
          {
            'option_numbers': [1, 2],
          },
        ],
      });

      expect(result, {'answered': true});
      final (recordedAgent, recordedQuestion, answers) = herd.answered.single;
      expect(recordedAgent, _agents[0]);
      expect(recordedQuestion, question);
      // Records hold a List, so == would compare it by identity; assert the
      // fields instead.
      expect(answers.map((a) => a.optionNumbers), [
        [2],
        [1, 2],
      ]);
      expect(answers.map((a) => a.text), [null, null]);
    });

    test('answer_question errors instead of crashing on a bad count', () async {
      herd.questions['wB:p1'] = const AgentQuestion(
        questions: [
          VoiceQuestion(question: 'Go?', options: ['Yes', 'No']),
          VoiceQuestion(question: 'Which?', options: ['lib', 'test']),
        ],
      );

      final responses = await runVoiceToolCalls([
        const FunctionCall('answer_question', {
          'agent': 'claude',
          'answers': [
            {
              'option_numbers': [1],
            },
          ],
        }, id: 'c9'),
      ], tools);

      expect(responses.single.id, 'c9');
      expect(
        responses.single.response['error'],
        allOf(contains('1 answer'), contains('2 question')),
      );
      expect(herd.answered, isEmpty);

      // A non-list `answers` is reported the same way, without reaching the
      // herd.
      expect(
        await tool(
          'answer_question',
        ).run({'agent': 'claude', 'answers': 'yes'}),
        {'error': 'answers must be a list, one entry per question'},
      );
      expect(herd.answered, isEmpty);
    });

    test('answer_question reports an agent with nothing pending', () async {
      expect(
        await tool('answer_question').run({'agent': 'codex', 'text': 'x'}),
        {'error': 'agent is not waiting on a question'},
      );
      expect(herd.answered, isEmpty);
    });

    test('answer_question errors on option_numbers it cannot read', () async {
      herd.questions['wB:p1'] = const AgentQuestion(
        questions: [
          VoiceQuestion(question: 'Go?', options: ['Yes', 'No']),
        ],
      );

      // A stringly-typed number would otherwise have been read as "no option
      // chosen" and submitted as a blank answer.
      final result = await tool('answer_question').run({
        'agent': 'claude',
        'answers': [
          {'option_numbers': '1'},
        ],
      });
      expect(result['error'], contains('answers entry 1'));

      // So would a bare value where an object belongs.
      final bare = await tool('answer_question').run({
        'agent': 'claude',
        'answers': [1],
      });
      expect(bare['error'], contains('answers entry 1'));
      expect(herd.answered, isEmpty);
    });

    test('draft_launch resolves the folder case-insensitively', () async {
      final result = await tool('draft_launch').run({
        'project': 'PROJ',
        'brief': 'Add a retry to the webhook client. Keep it small.',
        'kind': 'codex',
      });

      expect(result, {
        'draft_id': 'd1',
        'kind': 'codex',
        'project': 'proj',
        'brief': 'Add a retry to the webhook client. Keep it small.',
      });
      final draft = drafts.pending.single as LaunchDraft;
      expect((draft.kind, draft.cwd), ('codex', '/tmp/proj'));
      expect(herd.launched, isEmpty);
    });

    test('draft_launch defaults the kind to claude', () async {
      final result = await tool(
        'draft_launch',
      ).run({'project': 'x', 'brief': 'ship it'});

      expect(result['kind'], 'claude');
      expect((drafts.pending.single as LaunchDraft).kind, 'claude');
    });

    test('draft_launch rejects an unknown kind', () async {
      final result = await tool(
        'draft_launch',
      ).run({'project': 'x', 'brief': 'ship it', 'kind': 'gemini'});

      expect(result['error'], contains('unknown kind gemini'));
      expect(result['error'], contains('claude, codex'));
      expect(drafts.pending, isEmpty);
    });

    test('draft_launch lists the folders for an unknown project', () async {
      final result = await tool(
        'draft_launch',
      ).run({'project': 'nope', 'brief': 'ship it'});

      expect(
        result['error'],
        'no project folder matches "nope"; projects: proj, x, y',
      );
      expect(drafts.pending, isEmpty);
    });

    test('draft_launch refuses an ambiguous folder name', () async {
      herd.agents = [
        ..._agents,
        fakeAgent(paneId: 'wB:p4', cwd: '/other/proj'),
      ];

      final result = await tool(
        'draft_launch',
      ).run({'project': 'proj', 'brief': 'ship it'});

      expect(result['error'], contains('several projects are called "proj"'));
      expect(result['error'], contains('projects: proj, x, y'));
      expect(drafts.pending, isEmpty);
    });

    test('launch starts the drafted agent and marks the draft done', () async {
      await tool('draft_launch').run({'project': 'x', 'brief': 'ship it'});

      final result = await tool('launch').run({'draft_id': 'd1'});

      expect(result, {
        'launched': true,
        'agent': 'claude',
        'project': 'x',
        'brief_delivered': true,
      });
      expect(herd.launched.single, ('claude', '/tmp/x', 'ship it'));
      expect(drafts.pending, isEmpty);
    });

    test('launch reports a brief that never landed', () async {
      await tool('draft_launch').run({'project': 'x', 'brief': 'ship it'});
      herd.briefDelivered = false;

      final result = await tool('launch').run({'draft_id': 'd1'});

      expect(result['launched'], isTrue);
      expect(result['brief_delivered'], isFalse);
    });

    test('launch with an unknown or message draft id starts nothing', () async {
      await tool('draft_message').run({'agent': 'claude', 'message': 'hi'});

      expect(
        (await tool('launch').run({'draft_id': 'd7'}))['error'],
        contains('unknown draft_id d7'),
      );
      expect(
        (await tool('launch').run({'draft_id': 'd1'}))['error'],
        contains('unknown draft_id d1'),
      );
      expect(herd.launched, isEmpty);
    });

    test('launch refuses to start the same draft twice', () async {
      await tool('draft_launch').run({'project': 'x', 'brief': 'ship it'});
      await tool('launch').run({'draft_id': 'd1'});

      final result = await tool('launch').run({'draft_id': 'd1'});

      expect(result['error'], contains('already launched'));
      expect(herd.launched, hasLength(1));
    });

    test('launch refuses a second call while the first is in flight', () async {
      await tool('draft_launch').run({'project': 'x', 'brief': 'ship it'});
      herd.launchGate = Completer<void>();
      final first = tool('launch').run({'draft_id': 'd1'});
      await pumpEventQueue();

      final second = await tool('launch').run({'draft_id': 'd1'});

      expect(second['error'], contains('already being launched'));
      expect(herd.launched, hasLength(1));
      herd.launchGate!.complete();
      expect((await first)['launched'], isTrue);
    });

    test(
      'send_message refuses a second call while the first is in flight',
      () async {
        await tool('draft_message').run({'agent': 'claude', 'message': 'hi'});
        final gate = Completer<void>();
        herd.sendGate = gate;
        final first = tool('send_message').run({'draft_id': 'd1'});
        await pumpEventQueue();

        final second = await tool('send_message').run({'draft_id': 'd1'});

        expect(second['error'], contains('already being sent'));
        expect(herd.sent, hasLength(1));
        gate.complete();
        expect((await first)['sent'], isTrue);
      },
    );

    test('a failed launch releases the draft for a retry', () async {
      await tool('draft_launch').run({'project': 'x', 'brief': 'ship it'});
      herd.launchError = StateError('ssh down');
      await runVoiceToolCalls([
        const FunctionCall('launch', {'draft_id': 'd1'}, id: 'c7'),
      ], tools);
      herd.launchError = null;

      final result = await tool('launch').run({'draft_id': 'd1'});

      expect(result['launched'], isTrue);
      expect(herd.launched, hasLength(1));
    });

    test('a failed launch keeps the draft pending', () async {
      await tool('draft_launch').run({'project': 'x', 'brief': 'ship it'});
      herd.launchError = const HerdrException(
        'workspace_create_failed',
        'herdr workspace create failed (exit 2): /Users/kei/Projects: no such '
            'file or directory',
      );

      final responses = await runVoiceToolCalls([
        const FunctionCall('launch', {'draft_id': 'd1'}, id: 'c6'),
      ], tools);

      expect(responses.single.response['error'], 'workspace_create_failed');
      expect(
        '${responses.single.response['error']}',
        isNot(contains('/Users/kei')),
      );
      expect(drafts.pending, hasLength(1));
    });

    test('an unknown agent becomes a readable error payload', () async {
      final responses = await runVoiceToolCalls([
        const FunctionCall('draft_message', {
          'agent': 'gemini',
          'message': 'hi',
        }, id: 'c9'),
      ], tools);

      expect(
        responses.single.response['error'],
        'no agent matches "gemini"; agents: Implement the OAuth callback, '
        'Reviewer, agent',
      );
      expect(drafts.pending, isEmpty);
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
      // The type, not the thrown message: see voiceToolError.
      expect(responses.single.response['error'], 'StateError');
    });

    group('voiceToolError', () {
      test('keeps what the app itself wrote, so the model can retry', () {
        expect(
          voiceToolError(const VoiceAgentLookupError('no agent matches "x"')),
          'no agent matches "x"',
        );
        expect(
          voiceToolError(ArgumentError('got 1 answer(s) for 2 question(s)')),
          'got 1 answer(s) for 2 question(s)',
        );
      });

      test('drops what the host wrote', () {
        expect(
          voiceToolError(
            const HerdrException('transport', 'boom at /Users/kei/secret'),
          ),
          'transport',
        );
        expect(
          voiceToolError(const FormatException('bad JSON from /etc/herdr')),
          'FormatException',
        );
      });
    });
  });

  test('voiceToolsToFirebase declares every tool', () {
    final tool = voiceToolsToFirebase(
      droverVoiceTools(FakeVoiceHerd(), VoiceDrafts()),
    );
    final json = tool.toJson() as Map<String, Object?>;
    final decls = json['functionDeclarations'] as List<Object?>;
    expect(decls.map((d) => (d as Map<String, Object?>)['name']), [
      'list_agents',
      'read_agent',
      'draft_message',
      'send_message',
      'draft_launch',
      'launch',
      'answer_question',
    ]);
  });
}
