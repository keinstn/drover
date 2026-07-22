// Drives a live Codex CLI request_user_input TUI dialog to submit a staged
// set of answers by injecting keystrokes over herdr. This is safety-critical:
// a wrong key sent to a running agent is harmful, so the loop is READ-DRIVEN —
// after every action it re-reads the pane and confirms the expected transition
// actually happened, and ABORTS (throws) on any state it cannot recognise
// rather than sending keys blindly.
//
// Observed on Codex CLI 0.144.6:
//   - The dialog header reads "Question i/N (K unanswered)".
//   - Each question lists its options 1..N plus a synthetic "None of the
//     above" row at N+1; the currently selected row is marked `›`.
//   - Selection starts at row 1 for each question. Navigation uses `down`
//     arrow keys (one per step); after EVERY down key the pane is re-read
//     and the expected `› row. label` marker is confirmed before continuing.
//   - A normal answer: move down selectedIndex times, then Enter. Confirm
//     dialog advancement or closure before any further key.
//   - A custom-text answer: move down options.length times to the "None of the
//     above" row (confirm selected), Tab to open the notes editor (confirm
//     `Add notes` + notes footer), send text (confirm text visible), Enter.
//   - The dialog footer always contains "esc to interrupt" while the dialog is
//     open; closure is detected by the chrome disappearing (footer gone), NOT
//     by question-text absence (Codex scrollback repeats it).

import '../../transcript/native_transcript.dart';
import '../agent_capabilities.dart';
import '../structured_prompt_helpers.dart';

/// Thrown when the dialog is not in the expected state — the initial screen
/// isn't the dialog, an expected selection or transition never appears, or the
/// staged answers don't fit the prompt. Signals the caller to stop and surface
/// the failure rather than retry blindly.
class RequestUserInputSubmitError implements StructuredPromptSubmitError {
  const RequestUserInputSubmitError(this.message);

  @override
  final String message;

  @override
  String toString() => 'RequestUserInputSubmitError: $message';
}

/// Submits a staged answer set for a Codex CLI [StructuredPrompt] by injecting
/// keystrokes into the live TUI dialog. Depends only on three transport
/// closures (satisfied by [HerdrClient.readAgent]/`sendPaneText`/`sendKeys`),
/// so it is unit-testable without a real host.
class RequestUserInputSubmitter {
  RequestUserInputSubmitter({
    required this.readPane,
    required this.sendPaneText,
    required this.sendKeys,
    this.maxPolls = 5,
    this.pollInterval = const Duration(milliseconds: 150),
  });

  final Future<String> Function(String paneId) readPane;
  final Future<void> Function(String paneId, String text) sendPaneText;
  final Future<void> Function(String paneId, String key) sendKeys;

  /// How many times a confirmation re-reads the pane before giving up.
  final int maxPolls;

  /// Delay between confirmation re-reads (the TUI needs a moment to redraw).
  final Duration pollInterval;

  static const _noneOfTheAbove = 'None of the above';

  /// Submits [answers] for [prompt] into the dialog on [paneId]. One answer
  /// per question, in order. Throws [RequestUserInputSubmitError] on any
  /// unexpected state; never sends Esc, and never sends keys when the state
  /// is unknown.
  Future<void> submit({
    required String paneId,
    required StructuredPrompt prompt,
    required List<StructuredPromptAnswer> answers,
  }) async {
    _validate(prompt, answers);

    final questions = prompt.questions;

    // Gate the very first keystroke on actually seeing the dialog's first
    // question — never act on an unrecognised initial screen. We require the
    // exact "Question 1/N" header AND the initial "› 1. <label>" selection
    // marker, not merely the question text or footer, so that a partially
    // loaded pane or scrollback from a prior question cannot trigger sends.
    await _confirm(
      paneId,
      (text) =>
          _dialogOpen(text) &&
          _showsQuestionHeader(text, 0, questions.length) &&
          _showsInitialSelection(text, questions[0]) &&
          _showsQuestion(text, questions[0]),
      'initial screen is not the expected request_user_input dialog',
    );

    for (var i = 0; i < questions.length; i++) {
      final question = questions[i];
      final answer = answers[i];
      final isLast = i == questions.length - 1;

      // How many `down` keys to send: selectedIndex for a normal answer, or
      // options.length to land on the synthetic "None of the above" row.
      final moveCount = answer.customText != null
          ? question.options.length
          : answer.selectedIndexes.single;

      // Move down to the target row, confirming the selection marker after
      // each individual key — never advance to the next key until the
      // expected row marker is positively observed.
      for (var move = 0; move < moveCount; move++) {
        await sendKeys(paneId, 'down');
        // After the (move+1)-th down from row 1 we are at row (move+2).
        final currentRow = move + 2;
        final label = currentRow <= question.options.length
            ? question.options[currentRow - 1].label
            : _noneOfTheAbove;
        await _confirm(
          paneId,
          (text) =>
              _dialogOpen(text) &&
              _showsQuestion(text, question) &&
              text.contains('› $currentRow. ${normalizePaneText(label)}'),
          'question ${i + 1}: row $currentRow ($label) was not selected '
          'after moving down',
        );
      }

      if (answer.customText != null) {
        // Open the notes editor for the selected "None of the above" row.
        await sendKeys(paneId, 'tab');
        await _confirm(
          paneId,
          (text) =>
              _dialogOpen(text) &&
              _showsQuestionHeader(text, i, questions.length) &&
              _showsQuestion(text, question) &&
              _showsNotesEditor(text),
          'notes editor did not open for question ${i + 1}',
        );

        // Type the custom text, then confirm it is visibly present before
        // submitting — never send Enter against an unconfirmed editor state.
        await sendPaneText(paneId, answer.customText!);
        await _confirm(
          paneId,
          (text) =>
              _dialogOpen(text) &&
              _showsQuestionHeader(text, i, questions.length) &&
              _showsQuestion(text, question) &&
              text.contains(normalizePaneText(answer.customText!)),
          'custom text was not visible in the notes editor '
          'for question ${i + 1}',
        );

        await sendKeys(paneId, 'enter');
      } else {
        await sendKeys(paneId, 'enter');
      }

      if (isLast) {
        await _confirm(
          paneId,
          _dialogClosed,
          'dialog did not close after answering question ${i + 1}',
        );
      } else {
        final next = questions[i + 1];
        // Positively confirm the exact "Question i+2/N" header AND the
        // initial "› 1. <label>" marker for the next question, establishing
        // the navigation origin for the following down-key sequence.
        await _confirm(
          paneId,
          (text) =>
              _dialogOpen(text) &&
              _showsQuestionHeader(text, i + 1, questions.length) &&
              _showsInitialSelection(text, next) &&
              _showsQuestion(text, next),
          'question ${i + 1} did not advance to question ${i + 2}',
        );
      }
    }
  }

  /// Validates the staged answers against the prompt up front, so a mismatch
  /// aborts before a single keystroke is sent.
  void _validate(
    StructuredPrompt prompt,
    List<StructuredPromptAnswer> answers,
  ) {
    if (answers.length != prompt.questions.length) {
      throw RequestUserInputSubmitError(
        'answer count ${answers.length} does not match '
        '${prompt.questions.length} question(s)',
      );
    }
    for (var i = 0; i < answers.length; i++) {
      final question = prompt.questions[i];
      final answer = answers[i];

      if (question.multiSelect) {
        throw RequestUserInputSubmitError(
          'request_user_input does not support multi-select questions '
          '(question ${i + 1})',
        );
      }

      if (question.options.isEmpty) {
        throw RequestUserInputSubmitError('question ${i + 1} has no options');
      }

      if (answer.customText != null) {
        if (answer.selectedIndexes.isNotEmpty) {
          throw RequestUserInputSubmitError(
            'a custom answer cannot also select an option index '
            '(question ${i + 1})',
          );
        }
        if (answer.customText!.trim().isEmpty) {
          throw RequestUserInputSubmitError(
            'a custom answer cannot be blank (question ${i + 1})',
          );
        }
        continue;
      }

      if (answer.selectedIndexes.length != 1) {
        throw RequestUserInputSubmitError(
          'question ${i + 1} needs exactly one selected option, got '
          '${answer.selectedIndexes.length}',
        );
      }

      final index = answer.selectedIndexes.single;
      if (index < 0 || index >= question.options.length) {
        throw RequestUserInputSubmitError(
          'selected index $index is out of range for question ${i + 1} '
          '(${question.options.length} option(s))',
        );
      }
    }
  }

  /// Re-reads the pane up to [maxPolls] times until [predicate] holds,
  /// throwing [RequestUserInputSubmitError] with [failure] if it never does.
  /// The pane output is ANSI-stripped and whitespace-normalised before the
  /// predicate.
  Future<void> _confirm(
    String paneId,
    bool Function(String text) predicate,
    String failure,
  ) => pollUntil(
    readPane: readPane,
    paneId: paneId,
    predicate: predicate,
    makeError: RequestUserInputSubmitError.new,
    failure: failure,
    maxPolls: maxPolls,
    pollInterval: pollInterval,
  );

  /// Whether the active pane shows the 'Question k/N' header for the question
  /// at [questionIndex] (0-based) out of [total]. Both are known at call time,
  /// so this is an exact match — not a substring of the question text.
  bool _showsQuestionHeader(String text, int questionIndex, int total) =>
      text.contains('Question ${questionIndex + 1}/$total');

  /// Whether the first option of [question] (row 1) is currently selected:
  /// the pane must contain '› 1. <label>'. This confirms the dialog just
  /// arrived at this question with the cursor at its natural starting position,
  /// so subsequent down-key counts are anchored correctly.
  bool _showsInitialSelection(String text, StructuredPromptQuestion question) =>
      text.contains('› 1. ${normalizePaneText(question.options.first.label)}');

  /// Whether the active tab shows [question]'s text. Both sides are
  /// whitespace-normalised so terminal line-wrapping doesn't break the match.
  bool _showsQuestion(String text, StructuredPromptQuestion question) =>
      text.contains(normalizePaneText(question.question));

  /// Whether the notes editor is open: the `Add notes` header and the
  /// clear-notes footer are both visible.
  bool _showsNotesEditor(String text) =>
      text.contains('Add notes') && text.contains('tab or esc to clear notes');

  /// Whether the dialog is open. Keyed off "esc to interrupt", which appears
  /// in every Codex dialog footer while a question is active. NOT keyed off
  /// question text: Codex scrollback repeats answered questions, so question
  /// text cannot reliably detect dialog state.
  bool _dialogOpen(String text) => text.contains('esc to interrupt');

  /// True once all questions are answered and the dialog chrome is gone.
  bool _dialogClosed(String text) =>
      !text.contains('esc to interrupt') &&
      !text.contains('enter to submit answer') &&
      !text.contains('enter to submit all');
}
