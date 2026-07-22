// Drives a live Copilot CLI `ask_user` TUI dialog to submit a single staged
// answer by injecting keystrokes over herdr. This is safety-critical: a wrong
// key sent to a running agent is harmful, so the loop is READ-DRIVEN — after
// every action it re-reads the pane and confirms the expected transition
// actually happened, and ABORTS (throws) on any state it cannot recognize
// rather than sending keys blindly. Mirrors the shape of Claude Code's
// `AskUserQuestionSubmitter`, but Copilot's `ask_user` tool always carries
// exactly one single-select question (see docs/herdr-notes.md), so there is
// no question-tab-advance or multi-question review step to drive.

import '../../transcript/native_transcript.dart';
import '../agent_capabilities.dart';
import '../structured_prompt_helpers.dart';

/// Thrown when the dialog is not in the expected state — the initial screen
/// isn't the ask_user dialog, an expected transition never appears, or the
/// staged answer doesn't fit the prompt. Signals the caller to stop and
/// surface the failure rather than retry blindly.
class CopilotAskUserSubmitError implements StructuredPromptSubmitError {
  const CopilotAskUserSubmitError(this.message);

  @override
  final String message;

  @override
  String toString() => 'CopilotAskUserSubmitError: $message';
}
/// Submits a staged answer for a Copilot CLI `ask_user` [StructuredPrompt] by
/// injecting keystrokes into the live TUI dialog. Depends only on three
/// transport closures (satisfied by
/// `HerdrClient.readAgent`/`sendPaneText`/`sendKeys`), so it is unit-testable
/// without a real host.
class CopilotAskUserSubmitter {
  CopilotAskUserSubmitter({
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

  /// The footer shown when the dialog offers numbered choices.
  static const _choiceFooter =
      '↑/↓ to select · enter to confirm · esc to cancel';

  /// The footer shown when the dialog is a freeform text box (no choices).
  static const _freeformFooter = 'enter to submit · esc to cancel';

  /// The literal dialog header live-observed above the question text.
  static const _header = 'Question';

  /// The literal placeholder live-observed replacing the "Other" row once
  /// it is selected and its edit field opens. Note the capital `T`: this is
  /// distinct from the lowercase `(type your answer)` inside the closed-form
  /// "Other" row label (see [_otherRowLabel]), so it cannot appear on the
  /// unmodified choice dialog and is safe to use as positive evidence the
  /// edit field actually opened.
  static const _customAnswerPlaceholder = 'Type your answer';

  /// Submits [answers]' single entry for [prompt]'s single question into the
  /// dialog on [paneId]. Throws [CopilotAskUserSubmitError] on any unexpected
  /// state; never sends Esc, and never sends keys when the state is unknown.
  Future<void> submit({
    required String paneId,
    required StructuredPrompt prompt,
    required List<StructuredPromptAnswer> answers,
  }) async {
    _validate(prompt, answers);
    final question = prompt.questions.single;
    final answer = answers.single;
    final hasChoices = question.options.isNotEmpty;

    // Gate the very first keystroke on actually seeing the dialog's question
    // (with the footer that matches this question's shape) on screen — never
    // act on an unrecognized initial screen.
    await _confirm(
      paneId,
      (text) => _showsOpen(
        text,
        question,
        footer: hasChoices ? _choiceFooter : _freeformFooter,
      ),
      'initial screen is not the expected ask_user dialog',
    );

    if (!hasChoices) {
      // Freeform text box: type the answer, then Enter submits and closes.
      await sendPaneText(paneId, answer.customText!);
      await sendKeys(paneId, 'enter');
      await _confirm(
        paneId,
        _dialogClosed,
        'ask_user dialog did not close after submitting the freeform answer',
      );
      return;
    }

    if (answer.customText != null) {
      // The "Other (type your answer)" row is digit options.length + 1;
      // selecting it opens its edit field without closing the dialog. The
      // exact edit-mode footer text is unverified live, so this cannot be
      // used as evidence. But merely re-confirming "same question, dialog
      // not closed" is NOT enough on its own: that also holds on the
      // original, unchanged choice screen if the digit silently no-ops, so a
      // confirm() built only from those two checks would pass immediately
      // and the custom text/Enter would then be blindly injected into the
      // wrong (still-open, still-numbered-choices) screen. Require positive
      // evidence the edit field actually replaced the row instead.
      await sendPaneText(paneId, '${question.options.length + 1}');
      await _confirm(
        paneId,
        (text) => _showsCustomAnswerField(text, question),
        'custom answer field for the ask_user dialog did not open',
      );
      await sendPaneText(paneId, answer.customText!);
      await sendKeys(paneId, 'enter');
      await _confirm(
        paneId,
        _dialogClosed,
        'ask_user dialog did not close after submitting the custom answer',
      );
      return;
    }

    // A normal option digit alone confirms and closes the dialog immediately
    // — no Enter, no review step.
    await sendPaneText(paneId, '${answer.selectedIndexes.single + 1}');
    await _confirm(
      paneId,
      _dialogClosed,
      'ask_user dialog did not close after selecting the option',
    );
  }

  /// Validates the staged answer against the prompt up front, so a mismatch
  /// aborts before a single keystroke is sent.
  void _validate(
    StructuredPrompt prompt,
    List<StructuredPromptAnswer> answers,
  ) {
    if (prompt.questions.length != 1) {
      throw CopilotAskUserSubmitError(
        'ask_user prompt must have exactly one question, got '
        '${prompt.questions.length}',
      );
    }
    if (answers.length != 1) {
      throw CopilotAskUserSubmitError(
        'answer count ${answers.length} does not match the single ask_user '
        'question',
      );
    }
    final question = prompt.questions.single;
    final answer = answers.single;
    if (question.multiSelect) {
      throw CopilotAskUserSubmitError(
        'ask_user does not support multi-select questions',
      );
    }
    final hasChoices = question.options.isNotEmpty;
    if (!hasChoices) {
      if (answer.selectedIndexes.isNotEmpty) {
        throw CopilotAskUserSubmitError(
          'ask_user has no choices, so no option index can be selected',
        );
      }
      if (answer.customText == null || answer.customText!.trim().isEmpty) {
        throw CopilotAskUserSubmitError(
          'a freeform ask_user question needs a non-blank text answer',
        );
      }
      return;
    }
    if (answer.customText != null) {
      if (answer.selectedIndexes.isNotEmpty) {
        throw CopilotAskUserSubmitError(
          'a custom answer cannot also select an option index',
        );
      }
      if (answer.customText!.trim().isEmpty) {
        throw CopilotAskUserSubmitError('a custom answer cannot be blank');
      }
      // The custom row is numbered options.length + 1 and driven with a
      // single `sendPaneText` call; a two-digit number (options.length > 8)
      // would send a multi-char string whose first digit the TUI acts on
      // immediately — the wrong row.
      if (question.options.length > 8) {
        throw CopilotAskUserSubmitError(
          'custom row number ${question.options.length + 1} needs two '
          'digits, which cannot be keyed safely',
        );
      }
      return;
    }
    if (answer.selectedIndexes.length != 1) {
      throw CopilotAskUserSubmitError(
        'ask_user needs exactly one selected option or a custom answer',
      );
    }
    final index = answer.selectedIndexes.single;
    if (index < 0 || index >= question.options.length) {
      throw CopilotAskUserSubmitError(
        'selected index $index is out of range for ask_user '
        '(${question.options.length} option(s))',
      );
    }
    // Options are numbered 1..N and driven a digit at a time; a two-digit
    // number (index > 8) would send a multi-char string whose first digit the
    // TUI acts on immediately — the wrong option.
    if (index > 8) {
      throw CopilotAskUserSubmitError(
        'selected index $index needs a two-digit option number, which '
        'cannot be keyed safely',
      );
    }
  }

  /// Re-reads the pane up to [maxPolls] times until [predicate] holds,
  /// throwing [CopilotAskUserSubmitError] with [failure] if it never does.
  /// The pane output is ANSI-stripped and whitespace-normalized before the
  /// predicate.
  Future<void> _confirm(
    String paneId,
    bool Function(String text) predicate,
    String failure,
  ) => pollUntil(
    readPane: readPane,
    paneId: paneId,
    predicate: predicate,
    makeError: CopilotAskUserSubmitError.new,
    failure: failure,
    maxPolls: maxPolls,
    pollInterval: pollInterval,
  );

  /// Whether the pane shows the ask_user dialog open on [question] with the
  /// exact [footer] this question's shape (choices vs. freeform) is expected
  /// to render. Used only to gate the very first keystroke, where the shape
  /// is known up front and must match precisely.
  bool _showsOpen(
    String text,
    StructuredPromptQuestion question, {
    required String footer,
  }) =>
      text.contains(_header) &&
      text.contains(normalizePaneText(question.question)) &&
      text.contains(footer);

  /// Whether the dialog's full question text is visible, regardless of
  /// footer. Both sides are whitespace-normalized before matching.
  bool _showsQuestion(String text, StructuredPromptQuestion question) =>
      text.contains(normalizePaneText(question.question));

  /// The closed-form "Other" row label for [question], e.g.
  /// `3. Other (type your answer)` for a two-option question. Present only
  /// before "Other" is selected.
  String _otherRowLabel(StructuredPromptQuestion question) =>
      '${question.options.length + 1}. Other (type your answer)';

  /// Whether the pane shows the "Other" row's editable answer field open for
  /// [question]: still the same question, still not closed, AND displaying
  /// the live-observed `Type your answer` placeholder that replaces the row
  /// once selected. That placeholder is the load-bearing check — it cannot
  /// match the unmodified choice dialog (see [_customAnswerPlaceholder]) —
  /// so, unlike a bare "same question, not closed" check, this cannot pass
  /// on the original screen if the digit silently no-ops. The numbered
  /// "Other" row label having disappeared is checked too, as corroborating
  /// evidence, but is deliberately not the only signal (in case some other
  /// on-screen text incidentally still contains it).
  bool _showsCustomAnswerField(String text, StructuredPromptQuestion question) =>
      _showsQuestion(text, question) &&
      !_dialogClosed(text) &&
      text.contains(_customAnswerPlaceholder) &&
      !text.contains(_otherRowLabel(question));

  /// Whether the dialog is gone: neither the `Question` header nor either
  /// known footer is on screen. Scrollback may retain the question text (and
  /// a `● Asked user` summary), so closure must never be judged on
  /// question-text absence alone — only on the chrome (header/footer)
  /// disappearing.
  bool _dialogClosed(String text) =>
      !text.contains(_header) &&
      !text.contains(_choiceFooter) &&
      !text.contains(_freeformFooter);
}
