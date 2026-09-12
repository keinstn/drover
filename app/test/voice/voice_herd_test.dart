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
  final commands = <String>[];

  @override
  Future<CommandResult> run(String command) async {
    commands.add(command);
    return CommandResult(
      exitCode: 0,
      stdout: '{"id":"1","result":{}}',
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

StructuredPrompt _prompt(int questions) => StructuredPrompt(
  id: 'toolu_1',
  questions: [
    for (var i = 0; i < questions; i++)
      StructuredPromptQuestion(
        question: 'Question $i?',
        header: 'Q$i',
        multiSelect: false,
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
        adapter: _FakeAdapter(_FakeCapability(_prompt(2))),
        pane: _permissionPrompt,
      );
      final q = (await h.pendingQuestion(agent))!;
      expect(q.question, 'Question 0?');
      expect(q.options, ['Alpha', 'Beta']);
      expect(q.prompt, isNotNull);
      expect(q.questionCount, 2);
    });

    test('pendingQuestion falls back to the numbered pane prompt', () async {
      final h = herd(
        adapter: _FakeAdapter(_FakeCapability(null)),
        pane: '\x1b[1m$_permissionPrompt\x1b[0m',
      );
      final q = (await h.pendingQuestion(agent))!;
      expect(q.question, 'Do you want to proceed?');
      expect(q.options, [
        'Yes',
        'Yes, and always allow access to drover-spike-test/ from this project',
        'No',
      ]);
      expect(q.prompt, isNull);
      expect(q.questionCount, 1);
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

      await h.answer(agent, q, option: 2);
      await h.answer(agent, q, text: 'neither');

      expect(capability.submitted[0].single.selectedIndexes, [1]);
      expect(capability.submitted[0].single.customText, isNull);
      expect(capability.submitted[1].single.selectedIndexes, isEmpty);
      expect(capability.submitted[1].single.customText, 'neither');
      expect(runner.commands, isEmpty);
    });

    test('answer refuses multi-question prompts', () async {
      final h = herd(
        transcript: const NativeTranscript([]),
        adapter: _FakeAdapter(_FakeCapability(_prompt(2))),
      );
      final q = (await h.pendingQuestion(agent))!;
      expect(() => h.answer(agent, q, option: 1), throwsStateError);
    });

    test('answer types the option digit into a pane prompt', () async {
      final h = herd(pane: _permissionPrompt);
      final q = (await h.pendingQuestion(agent))!;

      await h.answer(agent, q, option: 3);

      expect(runner.commands.single, contains("'agent' 'prompt' 'w:p1' '3'"));
    });

    test('answer validates the option range and argument pair', () async {
      final h = herd(pane: _permissionPrompt);
      final q = (await h.pendingQuestion(agent))!;

      expect(() => h.answer(agent, q, option: 0), throwsRangeError);
      expect(() => h.answer(agent, q, option: 4), throwsRangeError);
      expect(() => h.answer(agent, q), throwsArgumentError);
      expect(
        () => h.answer(agent, q, option: 1, text: 'x'),
        throwsArgumentError,
      );
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
          question: 'Proceed?',
          options: ['Yes', 'No'],
          questionCount: 2,
        );
      expect(
        await announceEvents([AgentEvent(AgentEventKind.blocked, agent)], herd),
        '[event] Agent "Implement OAuth" (claude) is waiting for you. '
        'Question: "Proceed?" Options: 1) Yes 2) No Ask the user which option '
        '(or a free-text answer), then call answer_question. This prompt has '
        '2 questions; only the first can be answered by voice.',
      );
    });

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
}
