import 'package:drover/src/agents/copilot/copilot_askuser_submitter.dart';
import 'package:drover/src/transcript/native_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake transport that hands out SCRIPTED pane reads in order (the last
/// entry repeats once exhausted) and records every key send. [events] is a
/// single ordered log so tests can assert reads gate the sends.
class FakePane {
  FakePane(this._reads);

  final List<String> _reads;
  var _readIndex = 0;

  /// Ordered log: 'read', `text:<value>`, or `keys:<value>`.
  final events = <String>[];

  Future<String> read(String paneId) async {
    final text = _readIndex < _reads.length ? _reads[_readIndex] : _reads.last;
    _readIndex++;
    events.add('read');
    return text;
  }

  Future<void> sendText(String paneId, String text) async {
    events.add('text:$text');
  }

  Future<void> sendKeys(String paneId, String key) async {
    events.add('keys:$key');
  }

  List<String> get sends =>
      events.where((e) => e != 'read').toList(growable: false);
}

CopilotAskUserSubmitter submitterFor(FakePane pane) => CopilotAskUserSubmitter(
  readPane: pane.read,
  sendPaneText: pane.sendText,
  sendKeys: pane.sendKeys,
  maxPolls: 3,
  pollInterval: Duration.zero,
);

// --- Prompt fixtures --------------------------------------------------------

const choicePrompt = StructuredPrompt(
  id: 'call_1',
  questions: [
    StructuredPromptQuestion(
      question: 'Which approach?',
      header: '',
      multiSelect: false,
      options: [
        StructuredPromptOption(label: 'Ship it'),
        StructuredPromptOption(label: 'Keep iterating'),
      ],
    ),
  ],
);

const wrappedChoicePrompt = StructuredPrompt(
  id: 'call_wrap',
  questions: [
    StructuredPromptQuestion(
      question:
          'Should I refactor the parser now or keep the current '
          'implementation and revisit it later once the other work lands?',
      header: '',
      multiSelect: false,
      options: [
        StructuredPromptOption(label: 'Refactor now'),
        StructuredPromptOption(label: 'Later'),
      ],
    ),
  ],
);

const freeformPrompt = StructuredPrompt(
  id: 'call_free',
  questions: [
    StructuredPromptQuestion(
      question: 'What is the project name?',
      header: '',
      multiSelect: false,
      options: [],
    ),
  ],
);

/// A single-question prompt with [count] choices, for exercising the digit
/// range guard.
StructuredPrompt promptWithChoices(int count) => StructuredPrompt(
  id: 'call_n',
  questions: [
    StructuredPromptQuestion(
      question: 'Pick an option',
      header: '',
      multiSelect: false,
      options: [
        for (var i = 0; i < count; i++)
          StructuredPromptOption(label: 'Option ${i + 1}'),
      ],
    ),
  ],
);

// --- Pane-text fixtures ------------------------------------------------------

const choiceDialog = '''
Question
Which approach?

❯ 1. Ship it
  2. Keep iterating
  3. Other (type your answer)

↑/↓ to select · enter to confirm · esc to cancel''';

// The terminal wrapped the long question across lines with inserted newlines
// and indentation — the raw `question.question` never substring-matches this.
const wrappedChoiceDialog = '''
Question
Should I refactor the parser now or keep the
current implementation and revisit it later
once the other work lands?

❯ 1. Refactor now
  2. Later
  3. Other (type your answer)

↑/↓ to select · enter to confirm · esc to cancel''';

const freeformDialog = '''
Question
What is the project name?

>

enter to submit · esc to cancel''';

// After selecting "Other", the dialog stays open on an edit field: the
// numbered "Other" row is replaced by this `Type your answer:` placeholder
// (note the capital `T`, distinct from the lowercase `(type your answer)`
// inside the row label on `choiceDialog`) — the load-bearing, live-observed
// marker the submitter requires before typing. The exact edit-mode footer
// text is unverified live, so it is deliberately not asserted.
const customEditField = '''
Question
Which approach?

Type your answer:
>

enter to confirm · esc to cancel''';

// Closed/resolved: header and footer chrome are gone, but scrollback retains
// the question text via a "● Asked user" summary — closure must not be judged
// on question-text absence alone.
const answeredChoice = '''
● Asked user: Which approach? → Ship it

Working…''';

const answeredWrapped = '''
● Asked user: Should I refactor the parser now or keep the current implementation and revisit it later once the other work lands? → Refactor now

Working…''';

const answeredCustom = '''
● Asked user: Which approach? → Rewrite it

Working…''';

const answeredFreeform = '''
● Asked user: What is the project name? → my-project

Working…''';

const unrelatedScreen = '''
✻ Baked for 13s

❯ send it a real task''';

void main() {
  group('choice question, normal option', () {
    test('sends one digit, no Enter, gated by reads', () async {
      final pane = FakePane([choiceDialog, answeredChoice]);

      await submitterFor(pane).submit(
        paneId: 'wB:p1',
        prompt: choicePrompt,
        answers: const [
          StructuredPromptAnswer(selectedIndexes: [0]),
        ],
      );

      // read (confirm dialog) BEFORE the send, read (confirm closed) AFTER.
      expect(pane.events, ['read', 'text:1', 'read']);
    });

    test('detects closure across a wrapped question text', () async {
      final pane = FakePane([wrappedChoiceDialog, answeredWrapped]);

      await submitterFor(pane).submit(
        paneId: 'wB:p1',
        prompt: wrappedChoicePrompt,
        answers: const [
          StructuredPromptAnswer(selectedIndexes: [0]),
        ],
      );

      expect(pane.events, ['read', 'text:1', 'read']);
    });
  });

  group('choice question, custom "Other" answer', () {
    test('sends the Other row digit, text, then Enter', () async {
      final pane = FakePane([choiceDialog, customEditField, answeredCustom]);

      await submitterFor(pane).submit(
        paneId: 'wB:p1',
        prompt: choicePrompt,
        answers: const [
          StructuredPromptAnswer(selectedIndexes: [], customText: 'Rewrite it'),
        ],
      );

      // Two choices -> the "Other" row is digit 3.
      expect(pane.events, [
        'read',
        'text:3',
        'read',
        'text:Rewrite it',
        'keys:enter',
        'read',
      ]);
    });
  });

  group('no-choice question, freeform', () {
    test('sends the text, then Enter', () async {
      final pane = FakePane([freeformDialog, answeredFreeform]);

      await submitterFor(pane).submit(
        paneId: 'wB:p1',
        prompt: freeformPrompt,
        answers: const [
          StructuredPromptAnswer(selectedIndexes: [], customText: 'my-project'),
        ],
      );

      expect(pane.events, ['read', 'text:my-project', 'keys:enter', 'read']);
    });
  });

  group('aborts', () {
    test('when the initial pane does not show the ask_user dialog', () async {
      final pane = FakePane([unrelatedScreen]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: choicePrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [0]),
          ],
        ),
        throwsA(isA<CopilotAskUserSubmitError>()),
      );

      // Never sent a key when it couldn't recognize the screen.
      expect(pane.sends, isEmpty);
      // Polled up to maxPolls before giving up.
      expect(pane.events, ['read', 'read', 'read']);
    });

    test(
      'when the initial pane shows the wrong footer for this question shape',
      () async {
        // The question text matches, but a no-choices prompt expects the
        // freeform footer while the pane shows the choice-style dialog/
        // footer instead — a shape mismatch, not the expected screen.
        final pane = FakePane([choiceDialog]);
        const mismatchedFreeformPrompt = StructuredPrompt(
          id: 'call_1',
          questions: [
            StructuredPromptQuestion(
              question: 'Which approach?',
              header: '',
              multiSelect: false,
              options: [],
            ),
          ],
        );

        await expectLater(
          submitterFor(pane).submit(
            paneId: 'wB:p1',
            prompt: mismatchedFreeformPrompt,
            answers: const [
              StructuredPromptAnswer(selectedIndexes: [], customText: 'x'),
            ],
          ),
          throwsA(isA<CopilotAskUserSubmitError>()),
        );

        expect(pane.sends, isEmpty);
      },
    );

    test('when the dialog is already closed (already answered)', () async {
      final pane = FakePane([answeredChoice]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: choicePrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [0]),
          ],
        ),
        throwsA(isA<CopilotAskUserSubmitError>()),
      );

      expect(pane.sends, isEmpty);
    });

    test(
      'when selecting an option never closes the dialog (timeout)',
      () async {
        // The digit is sent, but the pane keeps showing the same open dialog —
        // the selection never actually committed.
        final pane = FakePane([
          choiceDialog,
          choiceDialog,
          choiceDialog,
          choiceDialog,
        ]);

        await expectLater(
          submitterFor(pane).submit(
            paneId: 'wB:p1',
            prompt: choicePrompt,
            answers: const [
              StructuredPromptAnswer(selectedIndexes: [0]),
            ],
          ),
          throwsA(
            isA<CopilotAskUserSubmitError>().having(
              (e) => e.message,
              'message',
              contains('did not close after selecting the option'),
            ),
          ),
        );

        // Sent the digit once, but never anything else (no blind retries/Esc).
        expect(pane.sends, ['text:1']);
      },
    );

    test(
      'sends no blind text/Enter when the custom edit field never opens',
      () async {
        // Digit sent for "Other", but the very next read shows the dialog
        // fully closed/resolved rather than an edit field — abort before
        // typing the custom text or pressing Enter.
        final pane = FakePane([choiceDialog, answeredChoice]);

        await expectLater(
          submitterFor(pane).submit(
            paneId: 'wB:p1',
            prompt: choicePrompt,
            answers: const [
              StructuredPromptAnswer(
                selectedIndexes: [],
                customText: 'Rewrite it',
              ),
            ],
          ),
          throwsA(
            isA<CopilotAskUserSubmitError>().having(
              (e) => e.message,
              'message',
              contains('custom answer field'),
            ),
          ),
        );

        // Only the Other-row digit was sent; the custom text and Enter were
        // never blindly injected once the expected edit field didn't appear.
        expect(pane.sends, ['text:3']);
      },
    );

    test('sends no blind text/Enter when the Other digit leaves the choice '
        'dialog unchanged (regression: same-question-not-closed alone is not '
        'enough evidence the edit field opened)', () async {
      // The Other-row digit is sent, but every re-read still shows the
      // exact same, unmodified choice dialog: same question, dialog not
      // closed (header/footer both still present) — which a "same
      // question && dialog open" check alone would have wrongly accepted,
      // since that also describes the pristine original screen. Only the
      // live-observed `Type your answer` edit-field placeholder (absent
      // here) can tell them apart.
      final pane = FakePane([
        choiceDialog,
        choiceDialog,
        choiceDialog,
        choiceDialog,
      ]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: choicePrompt,
          answers: const [
            StructuredPromptAnswer(
              selectedIndexes: [],
              customText: 'Rewrite it',
            ),
          ],
        ),
        throwsA(
          isA<CopilotAskUserSubmitError>().having(
            (e) => e.message,
            'message',
            contains('custom answer field'),
          ),
        ),
      );

      // Only the Other-row digit was sent; the custom text and Enter must
      // never be injected into what is still the original choice screen.
      expect(pane.sends, ['text:3']);
    });

    test(
      'when the dialog does not close after submitting custom text',
      () async {
        final pane = FakePane([choiceDialog, customEditField, customEditField]);

        await expectLater(
          submitterFor(pane).submit(
            paneId: 'wB:p1',
            prompt: choicePrompt,
            answers: const [
              StructuredPromptAnswer(
                selectedIndexes: [],
                customText: 'Rewrite it',
              ),
            ],
          ),
          throwsA(
            isA<CopilotAskUserSubmitError>().having(
              (e) => e.message,
              'message',
              contains('did not close after submitting the custom answer'),
            ),
          ),
        );

        expect(pane.sends, ['text:3', 'text:Rewrite it', 'keys:enter']);
      },
    );

    test('when the prompt has more than one question', () async {
      final pane = FakePane([choiceDialog]);
      final twoQuestionPrompt = StructuredPrompt(
        id: 'call_1',
        questions: List.filled(2, choicePrompt.questions.single),
      );

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: twoQuestionPrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [0]),
            StructuredPromptAnswer(selectedIndexes: [0]),
          ],
        ),
        throwsA(isA<CopilotAskUserSubmitError>()),
      );

      // Rejected before reading or touching the pane.
      expect(pane.events, isEmpty);
    });

    test('when the answers count does not match the single question', () async {
      final pane = FakePane([choiceDialog]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: choicePrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [0]),
            StructuredPromptAnswer(selectedIndexes: [1]),
          ],
        ),
        throwsA(isA<CopilotAskUserSubmitError>()),
      );

      expect(pane.events, isEmpty);
    });

    test('when the question is marked multi-select', () async {
      final pane = FakePane([choiceDialog]);
      final multiSelectPrompt = StructuredPrompt(
        id: 'call_1',
        questions: [
          StructuredPromptQuestion(
            question: 'Which approach?',
            header: '',
            multiSelect: true,
            options: choicePrompt.questions.single.options,
          ),
        ],
      );

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: multiSelectPrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [0]),
          ],
        ),
        throwsA(isA<CopilotAskUserSubmitError>()),
      );

      expect(pane.events, isEmpty);
    });

    test('when a selected index is out of range', () async {
      final pane = FakePane([choiceDialog]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: choicePrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [5]),
          ],
        ),
        throwsA(isA<CopilotAskUserSubmitError>()),
      );

      expect(pane.events, isEmpty);
    });

    test('when a selected index needs a two-digit option number', () async {
      final pane = FakePane([choiceDialog]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: promptWithChoices(10),
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [9]),
          ],
        ),
        throwsA(
          isA<CopilotAskUserSubmitError>().having(
            (e) => e.message,
            'message',
            contains('two-digit'),
          ),
        ),
      );

      expect(pane.events, isEmpty);
    });

    test('when the Other row number would need two digits', () async {
      final pane = FakePane([choiceDialog]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: promptWithChoices(9),
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [], customText: 'other'),
          ],
        ),
        throwsA(
          isA<CopilotAskUserSubmitError>().having(
            (e) => e.message,
            'message',
            contains('two digits'),
          ),
        ),
      );

      expect(pane.events, isEmpty);
    });

    test('when a custom answer also selects an option index', () async {
      final pane = FakePane([choiceDialog]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: choicePrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [0], customText: 'x'),
          ],
        ),
        throwsA(isA<CopilotAskUserSubmitError>()),
      );

      expect(pane.events, isEmpty);
    });

    test('when a custom answer is blank', () async {
      final pane = FakePane([choiceDialog]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: choicePrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [], customText: '   '),
          ],
        ),
        throwsA(isA<CopilotAskUserSubmitError>()),
      );

      expect(pane.events, isEmpty);
    });

    test('when a freeform question is given a selected index', () async {
      final pane = FakePane([freeformDialog]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: freeformPrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [0]),
          ],
        ),
        throwsA(isA<CopilotAskUserSubmitError>()),
      );

      expect(pane.events, isEmpty);
    });

    test('when a freeform question has no text answer', () async {
      final pane = FakePane([freeformDialog]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: freeformPrompt,
          answers: const [StructuredPromptAnswer(selectedIndexes: [])],
        ),
        throwsA(isA<CopilotAskUserSubmitError>()),
      );

      expect(pane.events, isEmpty);
    });
  });
}
