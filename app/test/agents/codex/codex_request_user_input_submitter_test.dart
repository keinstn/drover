import 'package:drover/src/agents/codex/codex_request_user_input_submitter.dart';
import 'package:drover/src/transcript/native_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake transport that hands out SCRIPTED pane reads in order (the last
/// entry repeats once exhausted) and records every send. [events] is a single
/// ordered log so tests can assert reads gate the sends.
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

RequestUserInputSubmitter submitterFor(FakePane pane) =>
    RequestUserInputSubmitter(
      readPane: pane.read,
      sendPaneText: pane.sendText,
      sendKeys: pane.sendKeys,
      maxPolls: 3,
      pollInterval: Duration.zero,
    );

// ---------------------------------------------------------------------------
// Prompt fixtures
// ---------------------------------------------------------------------------

/// A single question with two options.
const singlePrompt = StructuredPrompt(
  id: 'call_1',
  questions: [
    StructuredPromptQuestion(
      question: 'Which approach?',
      header: 'Approach',
      multiSelect: false,
      options: [
        StructuredPromptOption(label: 'Ship it'),
        StructuredPromptOption(label: 'Keep iterating'),
      ],
    ),
  ],
);

/// A single question whose text wraps in the terminal.
const wrappedPrompt = StructuredPrompt(
  id: 'call_wrap',
  questions: [
    StructuredPromptQuestion(
      question:
          'Should I refactor the parser now or keep the current '
          'implementation and revisit it later once the other work lands?',
      header: 'Refactor',
      multiSelect: false,
      options: [
        StructuredPromptOption(label: 'Refactor now'),
        StructuredPromptOption(label: 'Later'),
      ],
    ),
  ],
);

/// Two questions: first single, second also single.
const twoQuestionPrompt = StructuredPrompt(
  id: 'call_2q',
  questions: [
    StructuredPromptQuestion(
      question: 'What priority?',
      header: 'Priority',
      multiSelect: false,
      options: [
        StructuredPromptOption(label: 'High'),
        StructuredPromptOption(label: 'Low'),
      ],
    ),
    StructuredPromptQuestion(
      question: 'Which style?',
      header: 'Style',
      multiSelect: false,
      options: [
        StructuredPromptOption(label: 'Async'),
        StructuredPromptOption(label: 'Sync'),
      ],
    ),
  ],
);

StructuredPrompt promptWithOptions(int count) => StructuredPrompt(
  id: 'call_n',
  questions: [
    StructuredPromptQuestion(
      question: 'Pick one',
      header: '',
      multiSelect: false,
      options: [
        for (var i = 0; i < count; i++)
          StructuredPromptOption(label: 'Option ${i + 1}'),
      ],
    ),
  ],
);

// ---------------------------------------------------------------------------
// Pane-text fixtures — each line ends up as a single string; the submitter
// receives normalised (ANSI-stripped, whitespace-collapsed) versions.
// ---------------------------------------------------------------------------

const singleDialogRow1 = '''
Question 1/1 (1 unanswered)
Which approach?

› 1. Ship it
  2. Keep iterating
  3. None of the above

tab to add notes | enter to submit answer | esc to interrupt''';

const singleDialogRow2 = '''
Question 1/1 (1 unanswered)
Which approach?

  1. Ship it
› 2. Keep iterating
  3. None of the above

tab to add notes | enter to submit answer | esc to interrupt''';

const singleDialogNoneOfAbove = '''
Question 1/1 (1 unanswered)
Which approach?

  1. Ship it
  2. Keep iterating
› 3. None of the above

tab to add notes | enter to submit answer | esc to interrupt''';

const notesEditorOpen = '''
Question 1/1 (1 unanswered)
Which approach?

  1. Ship it
  2. Keep iterating
› 3. None of the above

Add notes

tab or esc to clear notes | enter to submit answer | esc to interrupt''';

const notesWithText = '''
Question 1/1 (1 unanswered)
Which approach?

  1. Ship it
  2. Keep iterating
› 3. None of the above

Add notes
Rewrite it

tab or esc to clear notes | enter to submit answer | esc to interrupt''';

// Closed: no footer chrome, but scrollback retains the question text.
const answeredSingle = '''
● request_user_input answered: Which approach? → Keep iterating

Working...''';

// Wrapped dialog — the terminal broke the long question across lines.
const wrappedDialogRow1 = '''
Question 1/1 (1 unanswered)
Should I refactor the parser now or keep the
current implementation and revisit it later
once the other work lands?

› 1. Refactor now
  2. Later
  3. None of the above

tab to add notes | enter to submit answer | esc to interrupt''';

const wrappedAnswerEcho = '''
● request_user_input answered: Should I refactor the parser now or keep the current implementation and revisit it later once the other work lands? → Refactor now

Working...''';

// Two-question fixtures.
const twoQDialog1Row1 = '''
Question 1/2 (2 unanswered)
What priority?

› 1. High
  2. Low
  3. None of the above

tab to add notes | enter to submit answer | esc to interrupt | ←/→ to navigate questions''';

const twoQDialog2Row1 = '''
Question 2/2 (1 unanswered)
Which style?

› 1. Async
  2. Sync
  3. None of the above

tab to add notes | enter to submit all | esc to interrupt | ←/→ to navigate questions''';

const twoQDialog2Row2 = '''
Question 2/2 (1 unanswered)
Which style?

  1. Async
› 2. Sync
  3. None of the above

tab to add notes | enter to submit all | esc to interrupt | ←/→ to navigate questions''';

const answeredTwo = '''
● request_user_input answered

Working...''';

const unrelatedScreen = '''
✻ Baked for 13s

❯ send it a real task''';

// ---------------------------------------------------------------------------
// Regression fixtures: scenarios that expose the safety gaps fixed by the
// strict confirmation predicates.
// ---------------------------------------------------------------------------

// Dialog is open and question text is present, but the initial selection
// marker ('› 1. Ship it') is absent — cursor may be elsewhere.
const singleDialogNoSelectionMarker = '''
Question 1/1 (1 unanswered)
Which approach?

  1. Ship it
  2. Keep iterating
  3. None of the above

tab to add notes | enter to submit answer | esc to interrupt''';

// After Q1 Enter, Q2 question text is shown but with the wrong question
// header ('Question 1/2' instead of 'Question 2/2').
const twoQDialog2WrongHeader = '''
Question 1/2 (1 unanswered)
Which style?

› 1. Async
  2. Sync
  3. None of the above

tab to add notes | enter to submit all | esc to interrupt | ←/→ to navigate questions''';

// Notes editor is open and footer is present, but for a different question
// text — simulates incidental 'Add notes' chrome visible for the wrong context.
const notesEditorWrongQuestionText = '''
Question 1/1 (1 unanswered)
A completely different question?

› 3. None of the above

Add notes

tab or esc to clear notes | enter to submit answer | esc to interrupt''';

// Notes editor is open AND the custom text is present, but for a different
// question text — incidental match for the text but wrong question context.
const notesEditorWithUnrelatedCustomText = '''
Question 1/1 (1 unanswered)
A completely different question?

Add notes
Rewrite it

tab or esc to clear notes | enter to submit answer | esc to interrupt''';

// ---------------------------------------------------------------------------
// Regression tests: must fail under old behavior, pass under new.
// ---------------------------------------------------------------------------

void regressionTests() {
  group('regression: initial selection marker required', () {
    test(
      'missing › 1. marker causes zero sends even for selectedIndex=0',
      () async {
        // Old behavior: _dialogOpen && _showsQuestion passes → Enter sent.
        // New behavior: _showsInitialSelection required → throws before any send.
        final pane = FakePane([
          singleDialogNoSelectionMarker,
          singleDialogNoSelectionMarker,
          singleDialogNoSelectionMarker,
        ]);

        await expectLater(
          submitterFor(pane).submit(
            paneId: 'w:p1',
            prompt: singlePrompt,
            answers: const [
              StructuredPromptAnswer(selectedIndexes: [0]),
            ],
          ),
          throwsA(isA<RequestUserInputSubmitError>()),
        );

        expect(pane.sends, isEmpty);
      },
    );
  });

  group('regression: exact question header required after advancement', () {
    test(
      'wrong question number after Q1 Enter causes no Q2 answer keys',
      () async {
        // Old behavior: _showsQuestion for Q2 text passes despite wrong header
        //   → Q2 down + Enter sent.
        // New behavior: _showsQuestionHeader(1, 2) required → throws after Q1 Enter.
        final pane = FakePane([
          twoQDialog1Row1,
          twoQDialog2WrongHeader, // Q2 text but says "Question 1/2"
          twoQDialog2WrongHeader,
          twoQDialog2WrongHeader,
        ]);

        await expectLater(
          submitterFor(pane).submit(
            paneId: 'w:p1',
            prompt: twoQuestionPrompt,
            answers: const [
              StructuredPromptAnswer(selectedIndexes: [0]),
              StructuredPromptAnswer(selectedIndexes: [0]),
            ],
          ),
          throwsA(
            isA<RequestUserInputSubmitError>().having(
              (e) => e.message,
              'message',
              contains('did not advance'),
            ),
          ),
        );

        // Q1 Enter was sent; no Q2 keys were ever injected.
        expect(pane.sends, ['keys:enter']);
      },
    );
  });

  group(
    'regression: notes-editor confirmation requires current question context',
    () {
      test(
        'unrelated notes editor (wrong question text) does not trigger custom-text send',
        () async {
          // Old behavior: _showsNotesEditor passes for any Add notes chrome →
          //   custom text sent.
          // New behavior: _showsQuestion also required → throws before typing.
          final pane = FakePane([
            singleDialogRow1,
            singleDialogRow2,
            singleDialogNoneOfAbove,
            notesEditorWrongQuestionText, // notes chrome but wrong question
            notesEditorWrongQuestionText,
            notesEditorWrongQuestionText,
          ]);

          await expectLater(
            submitterFor(pane).submit(
              paneId: 'w:p1',
              prompt: singlePrompt,
              answers: const [
                StructuredPromptAnswer(
                  selectedIndexes: [],
                  customText: 'Rewrite it',
                ),
              ],
            ),
            throwsA(
              isA<RequestUserInputSubmitError>().having(
                (e) => e.message,
                'message',
                contains('notes editor'),
              ),
            ),
          );

          // Downs and Tab were sent; custom text and Enter were never injected.
          expect(pane.sends, ['keys:down', 'keys:down', 'keys:tab']);
        },
      );
    },
  );

  group('regression: custom-text confirmation requires current question context', () {
    test(
      'incidental custom text visible in wrong question context does not trigger Enter',
      () async {
        // Notes editor opens correctly (notesEditorOpen has the right question
        // text, so the notes-editor confirmation passes). After the text is
        // typed, the pane transitions to one that has the custom text BUT shows
        // a different question — simulating scrollback contamination or a race.
        //
        // Old behavior: text.contains(customText) passes regardless of which
        //   question is displayed → Enter sent.
        // New behavior: _showsQuestion required in the custom-text check →
        //   throws before Enter is sent.
        final pane = FakePane([
          singleDialogRow1, // initial confirmation
          singleDialogRow2, // after down 1
          singleDialogNoneOfAbove, // after down 2
          notesEditorOpen, // notes editor opens with correct question text
          notesEditorWithUnrelatedCustomText, // custom text present but wrong question
          notesEditorWithUnrelatedCustomText,
          notesEditorWithUnrelatedCustomText,
        ]);

        await expectLater(
          submitterFor(pane).submit(
            paneId: 'w:p1',
            prompt: singlePrompt,
            answers: const [
              StructuredPromptAnswer(
                selectedIndexes: [],
                customText: 'Rewrite it',
              ),
            ],
          ),
          throwsA(
            isA<RequestUserInputSubmitError>().having(
              (e) => e.message,
              'message',
              contains('not visible'),
            ),
          ),
        );

        // Custom text was sent; Enter was NOT sent because the question context
        // check failed in the custom-text confirmation.
        expect(pane.sends, [
          'keys:down',
          'keys:down',
          'keys:tab',
          'text:Rewrite it',
        ]);
      },
    );
  });
}

void main() {
  regressionTests();

  group('first option (selectedIndex=0), single question, no down keys', () {
    test(
      'reads dialog, sends Enter, reads closed — no down keys sent',
      () async {
        final pane = FakePane([singleDialogRow1, answeredSingle]);

        await submitterFor(pane).submit(
          paneId: 'w:p1',
          prompt: singlePrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [0]),
          ],
        );

        // read (confirm initial dialog), then Enter, then read (confirm closed).
        expect(pane.events, ['read', 'keys:enter', 'read']);
      },
    );

    test('detects closure when scrollback retains the question text', () async {
      // answeredSingle contains the question text but has no dialog chrome —
      // _dialogClosed must not rely on question-text absence.
      final pane = FakePane([singleDialogRow1, answeredSingle]);

      await submitterFor(pane).submit(
        paneId: 'w:p1',
        prompt: singlePrompt,
        answers: const [
          StructuredPromptAnswer(selectedIndexes: [0]),
        ],
      );

      expect(pane.sends, ['keys:enter']);
    });
  });

  group('later option (selectedIndex=1), single question, one down', () {
    test(
      'sends down, confirms row 2, then Enter, then confirms closed',
      () async {
        final pane = FakePane([
          singleDialogRow1,
          singleDialogRow2,
          answeredSingle,
        ]);

        await submitterFor(pane).submit(
          paneId: 'w:p1',
          prompt: singlePrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [1]),
          ],
        );

        // read (initial) → down → read (confirm row 2) → enter → read (closed).
        expect(pane.events, [
          'read',
          'keys:down',
          'read',
          'keys:enter',
          'read',
        ]);
      },
    );
  });

  group('two questions: Q1 first option, Q2 second option', () {
    test('Enter on Q1 advances to Q2; Enter on Q2 closes dialog', () async {
      final pane = FakePane([
        twoQDialog1Row1,
        twoQDialog2Row1,
        twoQDialog2Row2,
        answeredTwo,
      ]);

      await submitterFor(pane).submit(
        paneId: 'w:p1',
        prompt: twoQuestionPrompt,
        answers: const [
          StructuredPromptAnswer(selectedIndexes: [0]), // Q1: first option
          StructuredPromptAnswer(selectedIndexes: [1]), // Q2: second option
        ],
      );

      expect(pane.events, [
        'read', // confirm initial Q1 dialog
        'keys:enter', // Q1 answer (no downs needed for index 0)
        'read', // confirm advanced to Q2
        'keys:down', // move to row 2 for Q2 index 1
        'read', // confirm row 2 selected
        'keys:enter', // Q2 answer
        'read', // confirm dialog closed
      ]);
    });
  });

  group('custom notes flow (None of the above)', () {
    test(
      'moves down to None of the above, Tabs, types, confirms, Enters',
      () async {
        // Two options → 2 downs to reach None of the above (row 3).
        final pane = FakePane([
          singleDialogRow1, // initial
          singleDialogRow2, // after 1st down: row 2 selected
          singleDialogNoneOfAbove, // after 2nd down: None of the above selected
          notesEditorOpen, // after Tab: notes editor open
          notesWithText, // after typing: text visible
          answeredSingle, // after Enter: dialog closed
        ]);

        await submitterFor(pane).submit(
          paneId: 'w:p1',
          prompt: singlePrompt,
          answers: const [
            StructuredPromptAnswer(
              selectedIndexes: [],
              customText: 'Rewrite it',
            ),
          ],
        );

        expect(pane.events, [
          'read', // confirm initial dialog
          'keys:down', // move to row 2
          'read', // confirm row 2
          'keys:down', // move to row 3 (None of the above)
          'read', // confirm row 3 selected
          'keys:tab', // open notes editor
          'read', // confirm notes editor open
          'text:Rewrite it', // type custom text
          'read', // confirm text visible
          'keys:enter', // submit
          'read', // confirm dialog closed
        ]);
      },
    );
  });

  group('wrapped question text normalization', () {
    test(
      'matches a question whose text was wrapped across terminal lines',
      () async {
        final pane = FakePane([wrappedDialogRow1, wrappedAnswerEcho]);

        await submitterFor(pane).submit(
          paneId: 'w:p1',
          prompt: wrappedPrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [0]),
          ],
        );

        expect(pane.events, ['read', 'keys:enter', 'read']);
      },
    );
  });

  group('invalid staged answers — all rejected before any I/O', () {
    test('answer count mismatch', () async {
      final pane = FakePane([singleDialogRow1]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'w:p1',
          prompt: singlePrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [0]),
            StructuredPromptAnswer(selectedIndexes: [0]),
          ],
        ),
        throwsA(isA<RequestUserInputSubmitError>()),
      );

      expect(pane.events, isEmpty);
    });

    test('multi-select question is rejected', () async {
      final pane = FakePane([singleDialogRow1]);
      const multiSelectPrompt = StructuredPrompt(
        id: 'call_1',
        questions: [
          StructuredPromptQuestion(
            question: 'Which approach?',
            header: '',
            multiSelect: true,
            options: [StructuredPromptOption(label: 'Ship it')],
          ),
        ],
      );

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'w:p1',
          prompt: multiSelectPrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [0]),
          ],
        ),
        throwsA(
          isA<RequestUserInputSubmitError>().having(
            (e) => e.message,
            'message',
            contains('multi-select'),
          ),
        ),
      );

      expect(pane.events, isEmpty);
    });

    test('question with empty options list is rejected', () async {
      final pane = FakePane([singleDialogRow1]);
      const emptyOptionsPrompt = StructuredPrompt(
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
          paneId: 'w:p1',
          prompt: emptyOptionsPrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [0]),
          ],
        ),
        throwsA(
          isA<RequestUserInputSubmitError>().having(
            (e) => e.message,
            'message',
            contains('no options'),
          ),
        ),
      );

      expect(pane.events, isEmpty);
    });

    test('custom answer and selected index together are rejected', () async {
      final pane = FakePane([singleDialogRow1]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'w:p1',
          prompt: singlePrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [0], customText: 'x'),
          ],
        ),
        throwsA(isA<RequestUserInputSubmitError>()),
      );

      expect(pane.events, isEmpty);
    });

    test('blank custom text is rejected', () async {
      final pane = FakePane([singleDialogRow1]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'w:p1',
          prompt: singlePrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [], customText: '   '),
          ],
        ),
        throwsA(isA<RequestUserInputSubmitError>()),
      );

      expect(pane.events, isEmpty);
    });

    test('zero selected indexes with no custom text is rejected', () async {
      final pane = FakePane([singleDialogRow1]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'w:p1',
          prompt: singlePrompt,
          answers: const [StructuredPromptAnswer(selectedIndexes: [])],
        ),
        throwsA(
          isA<RequestUserInputSubmitError>().having(
            (e) => e.message,
            'message',
            contains('exactly one'),
          ),
        ),
      );

      expect(pane.events, isEmpty);
    });

    test(
      'two selected indexes is rejected for a single-select question',
      () async {
        final pane = FakePane([singleDialogRow1]);

        await expectLater(
          submitterFor(pane).submit(
            paneId: 'w:p1',
            prompt: singlePrompt,
            answers: const [
              StructuredPromptAnswer(selectedIndexes: [0, 1]),
            ],
          ),
          throwsA(isA<RequestUserInputSubmitError>()),
        );

        expect(pane.events, isEmpty);
      },
    );

    test('out-of-range selected index is rejected', () async {
      final pane = FakePane([singleDialogRow1]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'w:p1',
          prompt: singlePrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [5]),
          ],
        ),
        throwsA(
          isA<RequestUserInputSubmitError>().having(
            (e) => e.message,
            'message',
            contains('out of range'),
          ),
        ),
      );

      expect(pane.events, isEmpty);
    });
  });

  group('unrecognised transitions throw without blind follow-up keys', () {
    test('when the initial pane is not the dialog — no keys sent', () async {
      final pane = FakePane([unrelatedScreen]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'w:p1',
          prompt: singlePrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [0]),
          ],
        ),
        throwsA(isA<RequestUserInputSubmitError>()),
      );

      expect(pane.sends, isEmpty);
      // Polled up to maxPolls times before giving up.
      expect(pane.events, ['read', 'read', 'read']);
    });

    test(
      'when a down key does not update the selection — no Enter sent',
      () async {
        // Every re-read keeps showing row 1 (down did not register).
        final pane = FakePane([
          singleDialogRow1,
          singleDialogRow1,
          singleDialogRow1,
          singleDialogRow1,
        ]);

        await expectLater(
          submitterFor(pane).submit(
            paneId: 'w:p1',
            prompt: singlePrompt,
            answers: const [
              StructuredPromptAnswer(selectedIndexes: [1]),
            ],
          ),
          throwsA(
            isA<RequestUserInputSubmitError>().having(
              (e) => e.message,
              'message',
              contains('row 2'),
            ),
          ),
        );

        // The down key was sent once; Enter was never blindly injected.
        expect(pane.sends, ['keys:down']);
      },
    );

    test('when Tab does not open the notes editor', () async {
      // After 2 downs confirming None of the above, Tab is sent but the pane
      // never shows the notes editor — abort before sending custom text.
      final pane = FakePane([
        singleDialogRow1,
        singleDialogRow2,
        singleDialogNoneOfAbove,
        singleDialogNoneOfAbove, // Tab sent, but notes editor never appears
        singleDialogNoneOfAbove,
      ]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'w:p1',
          prompt: singlePrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [], customText: 'Rewrite'),
          ],
        ),
        throwsA(
          isA<RequestUserInputSubmitError>().having(
            (e) => e.message,
            'message',
            contains('notes editor'),
          ),
        ),
      );

      // Tab was sent; but the custom text and Enter were never blindly sent.
      expect(pane.sends, ['keys:down', 'keys:down', 'keys:tab']);
    });

    test('when typed custom text is not visible — no Enter sent', () async {
      final pane = FakePane([
        singleDialogRow1,
        singleDialogRow2,
        singleDialogNoneOfAbove,
        notesEditorOpen, // Tab succeeded
        notesEditorOpen, // but text never appears after typing
        notesEditorOpen,
      ]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'w:p1',
          prompt: singlePrompt,
          answers: const [
            StructuredPromptAnswer(
              selectedIndexes: [],
              customText: 'Rewrite it',
            ),
          ],
        ),
        throwsA(
          isA<RequestUserInputSubmitError>().having(
            (e) => e.message,
            'message',
            contains('not visible'),
          ),
        ),
      );

      // Custom text was sent; Enter was NOT blindly sent after it.
      expect(pane.sends, [
        'keys:down',
        'keys:down',
        'keys:tab',
        'text:Rewrite it',
      ]);
    });

    test(
      'when the dialog does not close after Enter on the last question',
      () async {
        final pane = FakePane([
          singleDialogRow1,
          singleDialogRow1, // Enter sent, but dialog stays open
          singleDialogRow1,
        ]);

        await expectLater(
          submitterFor(pane).submit(
            paneId: 'w:p1',
            prompt: singlePrompt,
            answers: const [
              StructuredPromptAnswer(selectedIndexes: [0]),
            ],
          ),
          throwsA(
            isA<RequestUserInputSubmitError>().having(
              (e) => e.message,
              'message',
              contains('did not close'),
            ),
          ),
        );

        expect(pane.sends, ['keys:enter']);
      },
    );

    test(
      'when a non-last question does not advance to the next question',
      () async {
        // Enter sent for Q1, but reads keep showing Q1.
        final pane = FakePane([
          twoQDialog1Row1,
          twoQDialog1Row1, // Q1 never advances
          twoQDialog1Row1,
        ]);

        await expectLater(
          submitterFor(pane).submit(
            paneId: 'w:p1',
            prompt: twoQuestionPrompt,
            answers: const [
              StructuredPromptAnswer(selectedIndexes: [0]),
              StructuredPromptAnswer(selectedIndexes: [0]),
            ],
          ),
          throwsA(
            isA<RequestUserInputSubmitError>().having(
              (e) => e.message,
              'message',
              contains('did not advance'),
            ),
          ),
        );

        // Q1 Enter was sent; Q2 was never touched.
        expect(pane.sends, ['keys:enter']);
      },
    );

    test(
      'when the already-closed pane (dialog gone) is the initial read',
      () async {
        final pane = FakePane([answeredSingle]);

        await expectLater(
          submitterFor(pane).submit(
            paneId: 'w:p1',
            prompt: singlePrompt,
            answers: const [
              StructuredPromptAnswer(selectedIndexes: [0]),
            ],
          ),
          throwsA(isA<RequestUserInputSubmitError>()),
        );

        expect(pane.sends, isEmpty);
      },
    );
  });
}
