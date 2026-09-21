import 'package:drover/src/agents/agent_adapter.dart';
import 'package:drover/src/agents/agent_capabilities.dart';
import 'package:drover/src/herdr/command_runner.dart';
import 'package:drover/src/herdr/herdr_client.dart';
import 'package:drover/src/models/agent_info.dart';
import 'package:drover/src/models/remote_dir_entry.dart';
import 'package:drover/src/transcript/native_transcript.dart';
import 'package:drover/src/voice/voice_herd.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class _FakeRunner extends CommandRunner {
  _FakeRunner([this.respond]);

  final commands = <String>[];

  /// Per-command stdout; a null result falls back to an empty ok envelope.
  final String? Function(String command)? respond;

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
    return CommandResult(
      exitCode: 0,
      stdout: respond?.call(command) ?? '{"id":"1","result":{}}',
      stderr: '',
    );
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

class _FakeCapability implements StructuredPromptCapability {
  _FakeCapability(this.prompt);

  final StructuredPrompt? prompt;
  final submitted = <List<StructuredPromptAnswer>>[];

  @override
  StructuredPrompt? pendingPrompt(NativeTranscript history) => prompt;

  @override
  Future<void> submit({
    required HerdrClient client,
    required String paneId,
    required StructuredPrompt prompt,
    required List<StructuredPromptAnswer> answers,
  }) async => submitted.add(answers);
}

class _FakeAdapter extends AgentAdapter {
  const _FakeAdapter(this.capability);

  final StructuredPromptCapability? capability;

  @override
  bool supports(AgentInfo agent) => true;

  @override
  StructuredPromptCapability? get structuredPrompt => capability;
}

const _permissionPrompt = '''
 Bash command

   touch spike-test.txt
   Create empty file spike-test.txt

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to drover-spike-test/ from this
      project
   3. No

 Esc to cancel · Tab to amend · ctrl+e to explain''';

StructuredPrompt _prompt(int questions, {int? multiSelectAt}) =>
    StructuredPrompt(
      id: 'toolu_1',
      questions: [
        for (var i = 0; i < questions; i++)
          StructuredPromptQuestion(
            question: 'Question $i?',
            header: 'Q$i',
            multiSelect: i == multiSelectAt,
            options: const [
              StructuredPromptOption(label: 'Alpha'),
              StructuredPromptOption(label: 'Beta'),
            ],
          ),
      ],
    );

NativeTranscript _transcript(List<(TranscriptSpeaker, String)> messages) =>
    NativeTranscript([
      for (final (speaker, text) in messages)
        TranscriptMessage(speaker: speaker, text: text),
    ]);

void main() {
  group('speakable', () {
    test('replaces fenced code, strips markers, collapses whitespace', () {
      const text = '''
# Done

- Added the test
* And  the fix
1. Step one

```dart
void main() {}
```
Ship it.''';
      expect(
        speakable(text),
        'Done Added the test And the fix Step one (code omitted) Ship it.',
      );
    });

    test('replaces inline code spans too, so paths in them never cross', () {
      expect(
        speakable('Updated `lib/src/voice/voice_session.dart` and `x.yaml`.'),
        'Updated (code omitted) and (code omitted) .',
      );
    });

    test('a lone backtick does not swallow the rest of the prose', () {
      // Single-line by construction: an unpaired backtick must not eat the
      // paragraph looking for a partner.
      expect(
        speakable('It prints ` then stops.\nAll green.'),
        'It prints ` then stops. All green.',
      );
    });

    test(
      'prose keeps the paths it carries — code stripping is not a scrubber',
      () {
        expect(
          speakable('Wrote the fix to lib/src/voice/voice_tools.dart today.'),
          'Wrote the fix to lib/src/voice/voice_tools.dart today.',
        );
      },
    );

    test('truncates to 600 characters with an ellipsis', () {
      final result = speakable('a' * 700);
      expect(result.length, 601);
      expect(result.endsWith('…'), isTrue);
    });
  });

  group('resolveAgent', () {
    final agents = [
      fakeAgent(paneId: 'p1', kind: 'claude', title: 'Implement OAuth'),
      fakeAgent(paneId: 'p2', kind: 'codex', name: 'Reviewer'),
      fakeAgent(paneId: 'p3', kind: 'claude', title: 'Fix the auth bug'),
    ];

    test('exact title wins over substring matches', () {
      expect(resolveAgent(agents, 'implement oauth').paneId, 'p1');
    });

    test('kind matches when unique', () {
      expect(resolveAgent(agents, 'Codex').paneId, 'p2');
    });

    test('unique substring matches', () {
      expect(resolveAgent(agents, 'review').paneId, 'p2');
    });

    test('no match names the agents', () {
      expect(
        () => resolveAgent(agents, 'gemini'),
        throwsA(
          isA<VoiceAgentLookupError>().having(
            (e) => e.message,
            'message',
            'no agent matches "gemini"; agents: Implement OAuth, Reviewer, '
                'Fix the auth bug',
          ),
        ),
      );
    });

    test('ambiguous match lists the candidates', () {
      expect(
        () => resolveAgent(agents, 'claude'),
        throwsA(
          isA<VoiceAgentLookupError>().having(
            (e) => e.message,
            'message',
            'ambiguous: Implement OAuth, Fix the auth bug',
          ),
        ),
      );
    });
  });

  group('VoiceInbox', () {
    test('add replaces the pending event for the same pane', () {
      final inbox = VoiceInbox();
      final a = fakeAgent(paneId: 'p1');
      final b = fakeAgent(paneId: 'p2');
      var notifications = 0;
      inbox.addListener(() => notifications++);

      inbox.add(AgentEvent(AgentEventKind.blocked, a));
      inbox.add(AgentEvent(AgentEventKind.blocked, b));
      inbox.add(AgentEvent(AgentEventKind.finished, a));

      expect(inbox.pending.map((e) => (e.kind, e.agent.paneId)), [
        (AgentEventKind.blocked, 'p2'),
        (AgentEventKind.finished, 'p1'),
      ]);
      expect(notifications, 3);
      inbox.dispose();
    });

    test('drain returns and clears; every add reaches the stream', () async {
      final inbox = VoiceInbox();
      final seen = <AgentEventKind>[];
      inbox.events.listen((e) => seen.add(e.kind));
      final a = fakeAgent(paneId: 'p1');

      inbox.add(AgentEvent(AgentEventKind.blocked, a));
      inbox.add(AgentEvent(AgentEventKind.finished, a));
      await Future<void>.delayed(Duration.zero);

      expect(inbox.drain(), hasLength(1));
      expect(inbox.pending, isEmpty);
      expect(inbox.drain(), isEmpty);
      expect(seen, [AgentEventKind.blocked, AgentEventKind.finished]);
      inbox.dispose();
    });
  });

  group('HerdVoiceHerd', () {
    late _FakeRunner runner;
    final agent = fakeAgent(paneId: 'w:p1', title: 'Implement OAuth');

    HerdVoiceHerd herd({
      NativeTranscript? transcript,
      String pane = '',
      AgentAdapter? adapter,
    }) => HerdVoiceHerd(
      client: HerdrClient(runner),
      agents: () => [agent],
      loadTranscript: (_) async => transcript,
      readPane: (_) async => pane,
      adapterFor: (_) => adapter,
    );

    setUp(() => runner = _FakeRunner());

    test('lastReply speaks the trailing assistant message', () async {
      final h = herd(
        transcript: _transcript([
          (TranscriptSpeaker.user, 'add tests'),
          (TranscriptSpeaker.assistant, '## Done\n\nAdded 3 tests.'),
        ]),
      );
      expect(await h.lastReply(agent), 'Done Added 3 tests.');
    });

    test(
      'lastReply is null when the user spoke last or nothing loaded',
      () async {
        final h = herd(
          transcript: _transcript([
            (TranscriptSpeaker.assistant, 'Done.'),
            (TranscriptSpeaker.user, 'now add tests'),
          ]),
        );
        expect(await h.lastReply(agent), isNull);
        expect(await herd().lastReply(agent), isNull);
      },
    );

    test('pendingQuestion prefers the structured prompt', () async {
      final h = herd(
        transcript: const NativeTranscript([]),
        adapter: _FakeAdapter(_FakeCapability(_prompt(2, multiSelectAt: 1))),
        pane: _permissionPrompt,
      );
      final q = (await h.pendingQuestion(agent))!;
      expect(q.questions.map((e) => e.question), [
        'Question 0?',
        'Question 1?',
      ]);
      expect(q.questions.first.options, ['Alpha', 'Beta']);
      expect(q.questions.map((e) => e.multiSelect), [false, true]);
      expect(q.prompt, isNotNull);
    });

    test('pendingQuestion falls back to the numbered pane prompt', () async {
      final h = herd(
        adapter: _FakeAdapter(_FakeCapability(null)),
        pane: '\x1b[1m$_permissionPrompt\x1b[0m',
      );
      final q = (await h.pendingQuestion(agent))!;
      expect(q.questions.single.question, 'Do you want to proceed?');
      expect(q.questions.single.options, [
        'Yes',
        'Yes, and always allow access to drover-spike-test/ from this project',
        'No',
      ]);
      expect(q.questions.single.multiSelect, isFalse);
      expect(q.prompt, isNull);
      expect(await herd(pane: 'just working').pendingQuestion(agent), isNull);
    });

    test('send prompts the pane', () async {
      await herd().send(agent, 'add tests too');
      expect(runner.commands.single, contains("'agent' 'prompt' 'w:p1'"));
      expect(runner.commands.single, contains('add tests too'));
    });

    test('answer submits a structured option or custom text', () async {
      final capability = _FakeCapability(_prompt(1));
      final h = herd(
        transcript: const NativeTranscript([]),
        adapter: _FakeAdapter(capability),
      );
      final q = (await h.pendingQuestion(agent))!;

      await h.answer(agent, q, [
        (optionNumbers: [2], text: null),
      ]);
      await h.answer(agent, q, [(optionNumbers: [], text: 'neither')]);

      expect(capability.submitted[0].single.selectedIndexes, [1]);
      expect(capability.submitted[0].single.customText, isNull);
      expect(capability.submitted[1].single.selectedIndexes, isEmpty);
      expect(capability.submitted[1].single.customText, 'neither');
      expect(runner.commands, isEmpty);
    });

    test('answer submits every question of a multi-question prompt', () async {
      final capability = _FakeCapability(_prompt(2, multiSelectAt: 1));
      final h = herd(
        transcript: const NativeTranscript([]),
        adapter: _FakeAdapter(capability),
      );
      final q = (await h.pendingQuestion(agent))!;

      await h.answer(agent, q, [
        (optionNumbers: const [], text: 'something else'),
        (optionNumbers: const [1, 2], text: null),
      ]);

      final submitted = capability.submitted.single;
      expect(submitted, hasLength(2));
      expect(submitted[0].selectedIndexes, isEmpty);
      expect(submitted[0].customText, 'something else');
      expect(submitted[1].selectedIndexes, [0, 1]);
      expect(submitted[1].customText, isNull);
    });

    test('answer refuses a wrong number of answers', () async {
      final capability = _FakeCapability(_prompt(2));
      final h = herd(
        transcript: const NativeTranscript([]),
        adapter: _FakeAdapter(capability),
      );
      final q = (await h.pendingQuestion(agent))!;

      await expectLater(
        h.answer(agent, q, [
          (optionNumbers: const [1], text: null),
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            allOf(contains('1 answer'), contains('2 question')),
          ),
        ),
      );
      expect(capability.submitted, isEmpty);
    });

    test('answer refuses an answer holding both or neither', () async {
      final capability = _FakeCapability(_prompt(2, multiSelectAt: 1));
      final h = herd(
        transcript: const NativeTranscript([]),
        adapter: _FakeAdapter(capability),
      );
      final q = (await h.pendingQuestion(agent))!;
      Matcher named(String question) => throwsA(
        isA<ArgumentError>().having((e) => '$e', 'message', contains(question)),
      );

      // Both: the submitter keys the custom row first, silently dropping the
      // option the user picked.
      expect(
        () => h.answer(agent, q, [
          (optionNumbers: const [1], text: 'also this'),
          (optionNumbers: const [1], text: null),
        ]),
        named('question 1'),
      );
      // Neither: the multi-select dialog would be committed with nothing
      // checked, and reported as answered.
      expect(
        () => h.answer(agent, q, [
          (optionNumbers: const [1], text: null),
          (optionNumbers: const [], text: null),
        ]),
        named('question 2'),
      );
      expect(capability.submitted, isEmpty);
    });

    test('answer dedupes repeated option numbers', () async {
      final capability = _FakeCapability(_prompt(1, multiSelectAt: 0));
      final h = herd(
        transcript: const NativeTranscript([]),
        adapter: _FakeAdapter(capability),
      );
      final q = (await h.pendingQuestion(agent))!;

      await h.answer(agent, q, [
        (optionNumbers: const [1, 1], text: null),
      ]);

      expect(capability.submitted.single.single.selectedIndexes, [0]);
    });

    test('answer types the option digit into a pane prompt', () async {
      final h = herd(pane: _permissionPrompt);
      final q = (await h.pendingQuestion(agent))!;

      await h.answer(agent, q, [
        (optionNumbers: const [3], text: null),
      ]);

      expect(runner.commands.single, contains("'agent' 'prompt' 'w:p1' '3'"));
    });

    test('answer types free text into a pane prompt', () async {
      final h = herd(pane: _permissionPrompt);
      final q = (await h.pendingQuestion(agent))!;

      await h.answer(agent, q, [(optionNumbers: const [], text: 'neither')]);

      expect(
        runner.commands.single,
        contains("'agent' 'prompt' 'w:p1' 'neither'"),
      );
    });

    test('answer refuses two option numbers for a pane prompt', () async {
      final h = herd(pane: _permissionPrompt);
      final q = (await h.pendingQuestion(agent))!;

      expect(
        () => h.answer(agent, q, [
          (optionNumbers: const [1, 2], text: null),
        ]),
        throwsArgumentError,
      );
      expect(runner.commands, isEmpty);
    });

    test('answer validates the option range and argument pair', () async {
      final h = herd(pane: _permissionPrompt);
      final q = (await h.pendingQuestion(agent))!;

      VoiceAnswer a(List<int> numbers, [String? text]) =>
          (optionNumbers: numbers, text: text);

      expect(
        () => h.answer(agent, q, [
          a([0]),
        ]),
        throwsRangeError,
      );
      expect(
        () => h.answer(agent, q, [
          a([4]),
        ]),
        throwsRangeError,
      );
      expect(() => h.answer(agent, q, [a([])]), throwsArgumentError);
      expect(
        () => h.answer(agent, q, [
          a([1], 'x'),
        ]),
        throwsArgumentError,
      );
      expect(() => h.answer(agent, q, []), throwsArgumentError);
      expect(runner.commands, isEmpty);
    });
  });

  group('announceEvents', () {
    final agent = fakeAgent(paneId: 'p1', title: 'Implement OAuth');

    test('finished carries the last reply', () async {
      final herd = FakeVoiceHerd()..replies['p1'] = 'All green.';
      expect(
        await announceEvents([
          AgentEvent(AgentEventKind.finished, agent),
        ], herd),
        '[event] Agent "Implement OAuth" (claude) finished. '
        'Last reply: "All green."',
      );
      herd.replies.clear();
      expect(
        await announceEvents([
          AgentEvent(AgentEventKind.finished, agent),
        ], herd),
        endsWith('Last reply: "no reply text"'),
      );
    });

    test('blocked with a question lists numbered options', () async {
      final herd = FakeVoiceHerd()
        ..questions['p1'] = const AgentQuestion(
          questions: [
            VoiceQuestion(question: 'Proceed?', options: ['Yes', 'No']),
          ],
        );
      expect(
        await announceEvents([AgentEvent(AgentEventKind.blocked, agent)], herd),
        '[event] Agent "Implement OAuth" (claude) is waiting for you. '
        'Question: "Proceed?" Options: 1) Yes 2) No Ask the user each '
        'question in order — an option number, or a free-text answer — then '
        'call answer_question ONCE with one answer per question, in that '
        'order.',
      );
    });

    test(
      'blocked reads out every question of a multi-question prompt',
      () async {
        final herd = FakeVoiceHerd()
          ..questions['p1'] = const AgentQuestion(
            questions: [
              VoiceQuestion(question: 'Proceed?', options: ['Yes', 'No']),
              VoiceQuestion(
                question: 'Which files?',
                options: ['lib', 'test'],
                multiSelect: true,
              ),
            ],
          );
        final text = await announceEvents([
          AgentEvent(AgentEventKind.blocked, agent),
        ], herd);

        expect(
          text,
          allOf(
            contains('Question 1 of 2: "Proceed?" Options: 1) Yes 2) No'),
            contains(
              'Question 2 of 2: "Which files?" (more than one choice allowed) '
              'Options: 1) lib 2) test',
            ),
            contains('answer_question ONCE with one answer per question'),
            isNot(contains('only the first')),
          ),
        );
      },
    );

    test(
      'blocked without a question points to the app; one paragraph per event',
      () async {
        final herd = FakeVoiceHerd()..replies['p1'] = 'ok';
        final text = await announceEvents([
          AgentEvent(AgentEventKind.blocked, agent),
          AgentEvent(AgentEventKind.finished, agent),
        ], herd);
        expect(text.split('\n\n'), [
          '[event] Agent "Implement OAuth" (claude) is blocked waiting for '
              'input the app could not parse; tell the user to open it in the '
              'app.',
          '[event] Agent "Implement OAuth" (claude) finished. Last reply: "ok"',
        ]);
      },
    );
  });

  group('HerdVoiceHerd.launch', () {
    const workspace =
        '{"id":"1","result":{"workspace":{"workspace_id":"w2"},'
        '"root_pane":{"pane_id":"w2:p1"}}}';

    String agentList(String status) =>
        '{"id":"1","result":{"agents":[{"pane_id":"w2:p1","workspace_id":"w2",'
        '"tab_id":"w2:t1","agent":"claude","agent_status":"$status",'
        '"cwd":"/home/me/proj","focused":false,'
        '"terminal_title_stripped":"Add retries"}]}}';

    /// A herd whose `agent list` walks [statuses] (the last one repeating)
    /// and whose pane reads [panes] (likewise).
    ({HerdVoiceHerd herd, _FakeRunner runner}) launcher({
      List<String> statuses = const ['idle'],
      List<String> panes = const ['> add retries'],
      bool startFails = false,
      Set<String> namesTaken = const {},
    }) {
      var listCalls = 0;
      var paneCalls = 0;
      late final _FakeRunner runner;
      runner = _FakeRunner((command) {
        if (command.contains("'workspace' 'create'")) return workspace;
        if (command.contains("'agent' 'list'")) {
          final i = listCalls++;
          return agentList(
            statuses[i < statuses.length ? i : statuses.length - 1],
          );
        }
        if (command.contains("'agent' 'start'")) {
          if (startFails) {
            return '{"id":"1","error":{"code":"no_agent","message":"nope"}}';
          }
          if (namesTaken.any((n) => command.contains("'agent' 'start' '$n'"))) {
            return '{"id":"1","error":{"code":"agent_name_taken",'
                '"message":"taken"}}';
          }
        }
        return null;
      });
      return (
        herd: HerdVoiceHerd(
          client: HerdrClient(runner),
          agents: () => const [],
          loadTranscript: (_) async => null,
          readPane: (_) async {
            final i = paneCalls++;
            return panes[i < panes.length ? i : panes.length - 1];
          },
          adapterFor: (_) => null,
          sleep: (_) async {},
        ),
        runner: runner,
      );
    }

    test(
      'creates a workspace, starts the agent and prompts the brief',
      () async {
        final (:herd, :runner) = launcher();

        final result = await herd.launch(
          kind: 'claude',
          cwd: '/home/me/proj',
          brief: 'add retries',
        );

        expect(result, (
          paneId: 'w2:p1',
          title: 'Add retries',
          briefDelivered: true,
        ));
        expect(
          runner.commands
              .where((c) => c.contains("'workspace' 'create'"))
              .single,
          allOf(
            contains("'--label' 'proj'"),
            contains("'--cwd' '/home/me/proj'"),
          ),
        );
        expect(
          runner.commands.where((c) => c.contains("'agent' 'start'")).single,
          allOf(
            contains("'agent' 'start' 'claude'"),
            contains("'--pane' 'w2:p1'"),
          ),
        );
        expect(
          runner.commands.where((c) => c.contains("'agent' 'prompt'")),
          hasLength(1),
        );
      },
    );

    test('rolls the workspace back when the start fails', () async {
      final (:herd, :runner) = launcher(startFails: true);

      await expectLater(
        herd.launch(kind: 'claude', cwd: '/home/me/proj', brief: 'x'),
        throwsA(isA<HerdrException>()),
      );
      expect(
        runner.commands.where((c) => c.contains("'workspace' 'close' 'w2'")),
        hasLength(1),
      );
      expect(
        runner.commands.any((c) => c.contains("'agent' 'prompt'")),
        isFalse,
      );
    });

    test('starts under the next free name when the kind is taken', () async {
      final (:herd, :runner) = launcher(namesTaken: {'claude'});

      final result = await herd.launch(
        kind: 'claude',
        cwd: '/home/me/proj',
        brief: 'add retries',
      );

      expect(result, (
        paneId: 'w2:p1',
        title: 'Add retries',
        briefDelivered: true,
      ));
      expect(
        runner.commands.where((c) => c.contains("'agent' 'start'")).toList(),
        [
          contains("'agent' 'start' 'claude'"),
          contains("'agent' 'start' 'claude-2'"),
        ],
      );
      // A taken name is not a failed start: the workspace stays.
      expect(
        runner.commands.any((c) => c.contains("'workspace' 'close'")),
        isFalse,
      );
    });

    test(
      'falls the title back to the name it actually started under',
      () async {
        final (:herd, :runner) = launcher(
          namesTaken: {'claude'},
          statuses: ['working'],
        );

        final result = await herd.launch(
          kind: 'claude',
          cwd: '/home/me/proj',
          brief: 'add retries',
        );

        expect(result.title, 'claude-2');
      },
    );

    test('waits for the pane to read idle before prompting', () async {
      final (:herd, :runner) = launcher(
        statuses: ['working', 'working', 'idle'],
      );

      final result = await herd.launch(
        kind: 'claude',
        cwd: '/home/me/proj',
        brief: 'add retries',
      );

      expect(result.briefDelivered, isTrue);
      expect(
        runner.commands.where((c) => c.contains("'agent' 'list'")),
        hasLength(3),
      );
    });

    test('never prompts an agent that stays busy, and reports it', () async {
      final (:herd, :runner) = launcher(statuses: ['working']);

      final result = await herd.launch(
        kind: 'claude',
        cwd: '/home/me/proj',
        brief: 'add retries',
      );

      expect(result.briefDelivered, isFalse);
      expect(result.title, 'claude');
      expect(
        runner.commands.any((c) => c.contains("'agent' 'prompt'")),
        isFalse,
      );
    });

    test('prompts again when the brief is not in the pane', () async {
      final (:herd, :runner) = launcher(
        panes: ['\u001b[1mstarting…\u001b[0m', '> add ret\nries now'],
      );

      final result = await herd.launch(
        kind: 'claude',
        cwd: '/home/me/proj',
        brief: 'add retries now',
      );

      // Wrapped mid-word and coloured: still counts as delivered.
      expect(result.briefDelivered, isTrue);
      expect(
        runner.commands.where((c) => c.contains("'agent' 'prompt'")),
        hasLength(2),
      );
    });

    test('gives up after one re-prompt', () async {
      final (:herd, :runner) = launcher(panes: ['nothing here']);

      final result = await herd.launch(
        kind: 'claude',
        cwd: '/home/me/proj',
        brief: 'add retries',
      );

      expect(result.briefDelivered, isFalse);
      expect(
        runner.commands.where((c) => c.contains("'agent' 'prompt'")),
        hasLength(2),
      );
    });
  });

  group('resolveProjectCwd', () {
    final agents = [
      fakeAgent(paneId: 'p1', cwd: '/home/me/Drover'),
      fakeAgent(paneId: 'p2', cwd: '/home/me/billing-api'),
      fakeAgent(paneId: 'p3', cwd: '/home/me/Drover'),
    ];

    test('follows foregroundCwd, like list_agents and the launch sheet', () {
      final agent = fakeAgent(
        paneId: 'p9',
        cwd: '/home/me/Drover',
        foregroundCwd: '/home/me/drover/app',
      );
      // The folder list_agents named is the one the user says back.
      expect(resolveProjectCwd([agent], 'app'), '/home/me/drover/app');
      expect(
        () => resolveProjectCwd([agent], 'drover'),
        throwsA(isA<VoiceAgentLookupError>()),
      );
    });

    test('matches a folder name case-insensitively', () {
      expect(resolveProjectCwd(agents, ' drover '), '/home/me/Drover');
      expect(resolveProjectCwd(agents, 'billing-api'), '/home/me/billing-api');
    });

    test('lists the folders when nothing or several match', () {
      expect(
        () => resolveProjectCwd(agents, 'nope'),
        throwsA(
          isA<VoiceAgentLookupError>().having(
            (e) => e.message,
            'message',
            'no project folder matches "nope"; projects: drover, billing-api',
          ),
        ),
      );
      expect(
        () => resolveProjectCwd([
          ...agents,
          fakeAgent(paneId: 'p4', cwd: '/tmp/drover'),
        ], 'drover'),
        throwsA(
          isA<VoiceAgentLookupError>().having(
            (e) => e.message,
            'message',
            contains('several projects are called "drover"'),
          ),
        ),
      );
    });
  });
}
