// Drives a live Claude Code AskUserQuestion TUI dialog to submit a staged set
// of answers by injecting keystrokes over herdr. This is safety-critical: a
// wrong key sent to a running agent is harmful, so the loop is READ-DRIVEN —
// after every action it re-reads the pane and confirms the expected transition
// actually happened, and ABORTS (throws) on any state it cannot recognize
// rather than sending keys blindly.

import '../transcript/native_transcript.dart';
import 'ansi_text.dart';

/// Thrown when the dialog is not in the expected state — the initial screen
/// isn't the dialog, a question can't be matched, an expected transition never
/// appears, or the staged answers don't fit the prompt. Signals the caller to
/// stop and surface the failure rather than retry blindly.
class AskUserQuestionSubmitError implements Exception {
  const AskUserQuestionSubmitError(this.message);

  final String message;

  @override
  String toString() => 'AskUserQuestionSubmitError: $message';
}

/// Submits a staged answer set for an [AskUserQuestionPrompt] by injecting
/// keystrokes into the live TUI dialog. Depends only on three transport
/// closures (satisfied by [HerdrClient.readAgent]/`sendPaneText`/`sendKeys`),
/// so it is unit-testable without a real host.
class AskUserQuestionSubmitter {
  AskUserQuestionSubmitter({
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

  /// Submits [answers] for [prompt] into the dialog on [paneId]. One answer per
  /// question, in order. Throws [AskUserQuestionSubmitError] on any unexpected
  /// state; never sends Esc, and never sends keys when the state is unknown.
  Future<void> submit({
    required String paneId,
    required AskUserQuestionPrompt prompt,
    required List<AskUserQuestionAnswer> answers,
  }) async {
    _validate(prompt, answers);

    final questions = prompt.questions;

    // Gate the very first keystroke on actually seeing the dialog's first
    // question on screen — never act on an unrecognized initial screen.
    await _confirm(
      paneId,
      (text) => _dialogOpen(text) && _showsQuestion(text, questions[0]),
      'initial screen is not the expected AskUserQuestion dialog',
    );

    for (var i = 0; i < questions.length; i++) {
      final question = questions[i];
      final isLast = i == questions.length - 1;

      await _apply(paneId, question, answers[i]);

      if (!isLast) {
        // A single-select question auto-advances; a multi-select one is
        // advanced by the `right` sent in [_apply]. Either way, confirm we
        // actually landed on the next question's tab before touching it.
        final next = questions[i + 1];
        await _confirm(
          paneId,
          (text) => _dialogOpen(text) && _showsQuestion(text, next),
          'question ${i + 1} did not advance to question ${i + 2}',
        );
        continue;
      }

      if (questions.length == 1 && !question.multiSelect) {
        // A lone single-select question (normal or custom) submits the whole
        // prompt immediately: the dialog closes with no review step.
        await _confirm(
          paneId,
          _dialogClosed,
          'dialog did not close after answering the single question',
        );
        return;
      }

      // Every other shape lands on the "Review your answers" screen; confirm
      // it, then choose "Submit answers" (option 1) to commit.
      await _confirm(
        paneId,
        _isReviewScreen,
        'did not reach the review screen after the final question',
      );
      await sendPaneText(paneId, '1');
      // Confirm the submission committed and the dialog closed — otherwise a
      // failed '1' would report success and leave the agent blocked forever.
      await _confirm(
        paneId,
        _dialogClosed,
        'dialog did not close after submitting answers',
      );
    }
  }

  /// Applies one staged [answer] to the currently active [question]. Options
  /// are numbered 1..N in order (0-based index i → digit i+1); the "Type
  /// something" custom row is digit N+1.
  Future<void> _apply(
    String paneId,
    AskUserQuestionItem question,
    AskUserQuestionAnswer answer,
  ) async {
    if (question.multiSelect) {
      // Each digit toggles a checkbox and keeps the dialog open; `right`
      // advances to the next tab / review screen.
      for (final index in answer.selectedIndexes) {
        await sendPaneText(paneId, '${index + 1}');
      }
      await sendKeys(paneId, 'right');
      return;
    }
    if (answer.customText != null) {
      // Select the "Type something" row (enters edit mode), type the text,
      // then Enter to commit the field.
      await sendPaneText(paneId, '${question.options.length + 1}');
      await sendPaneText(paneId, answer.customText!);
      await sendKeys(paneId, 'enter');
      return;
    }
    await sendPaneText(paneId, '${answer.selectedIndexes.single + 1}');
  }

  /// Validates the staged answers against the prompt up front, so a mismatch
  /// aborts before a single keystroke is sent.
  void _validate(
    AskUserQuestionPrompt prompt,
    List<AskUserQuestionAnswer> answers,
  ) {
    if (answers.length != prompt.questions.length) {
      throw AskUserQuestionSubmitError(
        'answer count ${answers.length} does not match '
        '${prompt.questions.length} question(s)',
      );
    }
    for (var i = 0; i < answers.length; i++) {
      final question = prompt.questions[i];
      final answer = answers[i];
      for (final index in answer.selectedIndexes) {
        if (index < 0 || index >= question.options.length) {
          throw AskUserQuestionSubmitError(
            'selected index $index is out of range for question ${i + 1} '
            '(${question.options.length} option(s))',
          );
        }
        // Options are numbered 1..N and driven a digit at a time; a two-digit
        // number (index > 8) would send a multi-char string whose first digit
        // the TUI acts on immediately — the wrong option.
        if (index > 8) {
          throw AskUserQuestionSubmitError(
            'selected index $index for question ${i + 1} needs a two-digit '
            'option number, which cannot be keyed safely',
          );
        }
      }
      if (question.multiSelect && answer.customText != null) {
        throw AskUserQuestionSubmitError(
          'custom text is not supported for multi-select question ${i + 1}',
        );
      }
      // The custom "Type something" row is numbered options.length + 1; if that
      // is two digits (options.length > 8) it likewise can't be keyed safely.
      if (answer.customText != null && question.options.length > 8) {
        throw AskUserQuestionSubmitError(
          'custom row number ${question.options.length + 1} for question '
          '${i + 1} needs two digits, which cannot be keyed safely',
        );
      }
      if (!question.multiSelect &&
          answer.customText == null &&
          answer.selectedIndexes.length != 1) {
        throw AskUserQuestionSubmitError(
          'single-select question ${i + 1} needs exactly one selected option',
        );
      }
    }
  }

  /// Re-reads the pane up to [maxPolls] times until [predicate] holds, throwing
  /// [AskUserQuestionSubmitError] with [failure] if it never does.
  Future<void> _confirm(
    String paneId,
    bool Function(String text) predicate,
    String failure,
  ) async {
    for (var attempt = 0; attempt < maxPolls; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(pollInterval);
      }
      final text = stripAnsi(await readPane(paneId));
      if (predicate(text)) return;
    }
    throw AskUserQuestionSubmitError(failure);
  }

  /// The active tab renders its question's full text in the dialog body (the
  /// tab bar only shows headers), so the question text identifies the active
  /// tab. The pane wraps long questions at terminal width, so both sides are
  /// whitespace-normalized before matching — the match is agnostic to how (or
  /// whether) the read was wrapped.
  bool _showsQuestion(String text, AskUserQuestionItem question) =>
      _normalize(text).contains(_normalize(question.question));

  /// The final review step lists "1. Submit answers / 2. Cancel". Matched on
  /// "Submit answers" so the tab bar's bare "Submit" label and the post-answer
  /// echo (neither contains that exact phrase) can't false-trigger.
  bool _isReviewScreen(String text) =>
      _normalize(text).contains('Submit answers');

  /// Whether a question dialog is still open. Keyed off the selection chrome —
  /// every open AskUserQuestion tab renders the "Esc to cancel" footer — NOT
  /// off question-text presence: after a submit Claude echoes "User answered
  /// Claude's questions: … `<question>` → `<answer>`", so the question text
  /// reappears even though the dialog is gone.
  bool _dialogOpen(String text) => _normalize(text).contains('Esc to cancel');

  /// True once the dialog is gone: neither an open question tab nor the review
  /// screen is showing.
  bool _dialogClosed(String text) =>
      !_dialogOpen(text) && !_isReviewScreen(text);

  /// Collapses every run of whitespace (spaces + newlines) to a single space
  /// and trims, so terminal wrapping doesn't defeat a substring match.
  String _normalize(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();
}
