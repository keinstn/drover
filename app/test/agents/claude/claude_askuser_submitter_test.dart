import 'package:drover/src/agents/claude/claude_askuser_submitter.dart';
import 'package:drover/src/transcript/native_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake transport that hands out SCRIPTED pane reads in order (the last entry
/// repeats once exhausted) and records every key send. [events] is a single
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

AskUserQuestionSubmitter submitterFor(FakePane pane) =>
    AskUserQuestionSubmitter(
      readPane: pane.read,
      sendPaneText: pane.sendText,
      sendKeys: pane.sendKeys,
      maxPolls: 3,
      pollInterval: Duration.zero,
    );

// --- Prompt fixtures -------------------------------------------------------

const singleSelectPrompt = StructuredPrompt(
  id: 'tool_1',
  questions: [
    StructuredPromptQuestion(
      question: 'What should I do next?',
      header: 'Next step',
      multiSelect: false,
      options: [
        StructuredPromptOption(label: 'Ship it'),
        StructuredPromptOption(label: 'Keep iterating'),
      ],
    ),
  ],
);

const wrappedPrompt = StructuredPrompt(
  id: 'tool_wrap',
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

const multiSelectPrompt = StructuredPrompt(
  id: 'tool_2',
  questions: [
    StructuredPromptQuestion(
      question: 'Which files should I touch?',
      header: 'Files',
      multiSelect: true,
      options: [
        StructuredPromptOption(label: 'lib/a.dart'),
        StructuredPromptOption(label: 'lib/b.dart'),
        StructuredPromptOption(label: 'lib/c.dart'),
      ],
    ),
  ],
);

const twoQuestionPrompt = StructuredPrompt(
  id: 'tool_3',
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
      question: 'Which files?',
      header: 'Files',
      multiSelect: true,
      options: [
        StructuredPromptOption(label: 'lib/a.dart'),
        StructuredPromptOption(label: 'lib/b.dart'),
      ],
    ),
  ],
);

// --- Pane-text fixtures ----------------------------------------------------

const singleSelectDialog = '''
 What should I do next?

 ❯ 1. Ship it
   2. Keep iterating

 Esc to cancel · ↑↓ to select''';

const multiSelectDialog = '''
 Which files should I touch?

 ❯ [ ] 1. lib/a.dart
   [ ] 2. lib/b.dart
   [ ] 3. lib/c.dart

 Esc to cancel · number to toggle · → to continue''';

// A long question the terminal wrapped across lines with inserted newlines and
// indentation — the raw `question.question` never substring-matches this.
const wrappedDialog = '''
 Should I refactor the parser now or keep the
 current implementation and revisit it later
 once the other work lands?

 ❯ 1. Refactor now
   2. Later

 Esc to cancel · ↑↓ to select''';

const twoQuestionQ1 = '''
 ← [ ] Priority  [ ] Files  ✔ Submit →

 What priority?

 ❯ 1. High
   2. Low

 Esc to cancel · ↑↓ to select''';

const twoQuestionQ2 = '''
 ← ✔ Priority  [ ] Files  ✔ Submit →

 Which files?

 ❯ [ ] 1. lib/a.dart
   [ ] 2. lib/b.dart

 Esc to cancel · number to toggle · → to continue''';

const reviewScreen = '''
 Review your answers

 ❯ 1. Submit answers
   2. Cancel''';

// After a lone single-select submit the dialog closes, but Claude echoes the
// question text back — so closure must be detected by the absent selection
// chrome, not by the question text being gone.
const answerEcho = '''
⏺ User answered Claude's questions:
  ⎿  · What should I do next? → Ship it

✻ Working…''';

const wrappedAnswerEcho = '''
⏺ User answered Claude's questions:
  ⎿  · Should I refactor the parser now or keep the current implementation and revisit it later once the other work lands? → Refactor now

✻ Working…''';

// The closed screen after a review-path submit: no "Esc to cancel" chrome and
// no "Submit answers", so it reads as closed.
const submittedScreen = '''
⏺ User answered Claude's questions:
  ⎿  · Which files should I touch? → lib/a.dart, lib/c.dart

✻ Working…''';

const unrelatedScreen = '''
✻ Baked for 13s

❯ send it a real task''';

/// A single-question prompt with [count] options, for exercising the digit
/// range guard.
StructuredPrompt promptWithOptions(int count, {bool multiSelect = false}) =>
    StructuredPrompt(
      id: 'tool_n',
      questions: [
        StructuredPromptQuestion(
          question: 'Pick an option',
          header: 'Pick',
          multiSelect: multiSelect,
          options: [
            for (var i = 0; i < count; i++)
              StructuredPromptOption(label: 'Option ${i + 1}'),
          ],
        ),
      ],
    );

void main() {
  group('single question, single-select, normal option', () {
    test('sends one digit, no right/submit, gated by reads', () async {
      // Post-submit read echoes the question text back; closure is still
      // detected because the "Esc to cancel" chrome is gone.
      final pane = FakePane([singleSelectDialog, answerEcho]);

      await submitterFor(pane).submit(
        paneId: 'wB:p1',
        prompt: singleSelectPrompt,
        answers: const [
          StructuredPromptAnswer(selectedIndexes: [0]),
        ],
      );

      // read (confirm dialog) BEFORE the send, read (confirm closed) AFTER.
      expect(pane.events, ['read', 'text:1', 'read']);
    });

    test('detects closure across a wrapped question text', () async {
      // The dialog wraps the long question across lines; the submitter must
      // still match it, act, and confirm closure from the wrapped echo.
      final pane = FakePane([wrappedDialog, wrappedAnswerEcho]);

      await submitterFor(pane).submit(
        paneId: 'wB:p1',
        prompt: wrappedPrompt,
        answers: const [
          StructuredPromptAnswer(selectedIndexes: [0]),
        ],
      );

      expect(pane.events, ['read', 'text:1', 'read']);
    });
  });

  group('single question, single-select, custom', () {
    test('sends custom row digit, text, then enter', () async {
      final pane = FakePane([singleSelectDialog, answerEcho]);

      await submitterFor(pane).submit(
        paneId: 'wB:p1',
        prompt: singleSelectPrompt,
        answers: const [
          StructuredPromptAnswer(selectedIndexes: [], customText: 'Rewrite it'),
        ],
      );

      // Two options -> the "Type something" row is digit 3.
      expect(pane.events, [
        'read',
        'text:3',
        'text:Rewrite it',
        'keys:enter',
        'read',
      ]);
    });
  });

  group('single question, multi-select', () {
    test('toggles each digit, sends right, then submits with 1', () async {
      final pane = FakePane([multiSelectDialog, reviewScreen, submittedScreen]);

      await submitterFor(pane).submit(
        paneId: 'wB:p1',
        prompt: multiSelectPrompt,
        answers: const [
          StructuredPromptAnswer(selectedIndexes: [0, 2]),
        ],
      );

      expect(pane.events, [
        'read',
        'text:1',
        'text:3',
        'keys:right',
        'read',
        'text:1',
        'read', // confirm the dialog closed after submitting
      ]);
    });
  });

  group('two questions (single-select then multi-select)', () {
    test('answers Q1, advances, answers Q2, reviews, submits', () async {
      final pane = FakePane([
        twoQuestionQ1,
        twoQuestionQ2,
        reviewScreen,
        submittedScreen,
      ]);

      await submitterFor(pane).submit(
        paneId: 'wB:p1',
        prompt: twoQuestionPrompt,
        answers: const [
          StructuredPromptAnswer(selectedIndexes: [0]),
          StructuredPromptAnswer(selectedIndexes: [0, 1]),
        ],
      );

      expect(pane.events, [
        'read', // confirm Q1 tab is active
        'text:1', // Q1 single-select digit
        'read', // confirm advanced to Q2 tab
        'text:1', // Q2 first toggle
        'text:2', // Q2 second toggle
        'keys:right', // advance to review
        'read', // confirm review screen
        'text:1', // Submit answers
        'read', // confirm the dialog closed after submitting
      ]);
    });
  });

  group('aborts', () {
    test('when the initial pane does not show the dialog', () async {
      final pane = FakePane([unrelatedScreen]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: singleSelectPrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [0]),
          ],
        ),
        throwsA(isA<AskUserQuestionSubmitError>()),
      );

      // Never sent a key when it couldn't recognize the screen.
      expect(pane.sends, isEmpty);
      // Polled up to maxPolls before giving up.
      expect(pane.events, ['read', 'read', 'read']);
    });

    test('when an expected transition never appears', () async {
      // Dialog shows, digits/right are sent, but the review screen never
      // arrives (reads keep showing the same tab).
      final pane = FakePane([multiSelectDialog]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: multiSelectPrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [0, 2]),
          ],
        ),
        throwsA(isA<AskUserQuestionSubmitError>()),
      );

      // The toggles + right were sent before the failed confirmation, but no
      // blind Submit ('1') was ever sent.
      expect(pane.sends, ['text:1', 'text:3', 'keys:right']);
    });

    test('when the answers count does not match the questions', () async {
      final pane = FakePane([singleSelectDialog]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: singleSelectPrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [0]),
            StructuredPromptAnswer(selectedIndexes: [1]),
          ],
        ),
        throwsA(isA<AskUserQuestionSubmitError>()),
      );

      // Rejected before reading or touching the pane.
      expect(pane.events, isEmpty);
    });

    test('when a selected index is out of range', () async {
      final pane = FakePane([singleSelectDialog]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: singleSelectPrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [5]),
          ],
        ),
        throwsA(isA<AskUserQuestionSubmitError>()),
      );

      expect(pane.events, isEmpty);
    });

    test('when the pane shows only the post-answer echo (no chrome)', () async {
      // The echo reprints the question text but has no "Esc to cancel" chrome:
      // the dialog is gone, so injecting a digit would hit a different screen.
      final pane = FakePane([answerEcho]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: singleSelectPrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [0]),
          ],
        ),
        throwsA(isA<AskUserQuestionSubmitError>()),
      );

      // The safety property: no key was ever sent against the non-dialog screen.
      expect(pane.sends, isEmpty);
    });

    test('when the dialog does not close after submitting answers', () async {
      // Review screen reached and '1' sent, but the pane keeps showing the
      // review screen — the submit never committed.
      final pane = FakePane([multiSelectDialog, reviewScreen]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: multiSelectPrompt,
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [0, 2]),
          ],
        ),
        throwsA(
          isA<AskUserQuestionSubmitError>().having(
            (e) => e.message,
            'message',
            contains('dialog did not close after submitting'),
          ),
        ),
      );

      // '1' was sent, but success is not reported when closure isn't observed.
      expect(pane.sends, ['text:1', 'text:3', 'keys:right', 'text:1']);
    });

    test('when a selected index needs a two-digit option number', () async {
      final pane = FakePane([singleSelectDialog]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: promptWithOptions(10),
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [9]),
          ],
        ),
        throwsA(
          isA<AskUserQuestionSubmitError>().having(
            (e) => e.message,
            'message',
            contains('two-digit'),
          ),
        ),
      );

      expect(pane.events, isEmpty);
    });

    test('when the custom row number would need two digits', () async {
      final pane = FakePane([singleSelectDialog]);

      await expectLater(
        submitterFor(pane).submit(
          paneId: 'wB:p1',
          prompt: promptWithOptions(9),
          answers: const [
            StructuredPromptAnswer(selectedIndexes: [], customText: 'other'),
          ],
        ),
        throwsA(
          isA<AskUserQuestionSubmitError>().having(
            (e) => e.message,
            'message',
            contains('two digits'),
          ),
        ),
      );

      expect(pane.events, isEmpty);
    });
  });
}
