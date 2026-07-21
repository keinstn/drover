import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../transcript/native_transcript.dart';
import '../widgets/text_context_menu.dart';

/// Modal bottom sheet that stages and submits a user's answers to an agent's
/// interactive structured prompt (e.g. Claude Code's AskUserQuestion tool).
/// Each question renders its options (radios for single-select, checkboxes
/// for multi-select) plus a free-text field; selecting options and typing
/// custom text are mutually exclusive per question.
///
/// Answers are staged locally — nothing leaves the sheet until Send invokes
/// [onSubmit], which performs the actual submit via the resolved agent's
/// `StructuredPromptCapability`. Injecting [onSubmit] keeps the sheet
/// unit-testable without driving a real host: on success the sheet closes; on
/// failure [onSubmit] throws and the sheet stays open with its staged answers.
class StructuredPromptSheet extends StatefulWidget {
  const StructuredPromptSheet({
    super.key,
    required this.prompt,
    required this.onSubmit,
  });

  final StructuredPrompt prompt;
  final Future<void> Function(List<StructuredPromptAnswer> answers) onSubmit;

  @override
  State<StructuredPromptSheet> createState() => _StructuredPromptSheetState();
}

class _StructuredPromptSheetState extends State<StructuredPromptSheet> {
  // Staged option selections per question. A set even for single-select (where
  // it holds 0 or 1 entries); custom free-text answers live in the controllers.
  late final List<Set<int>> _selected;
  late final List<TextEditingController> _customControllers;
  // Whether the custom free-text field is expanded (revealed) per question.
  late final List<bool> _customOpen;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final count = widget.prompt.questions.length;
    _selected = List.generate(count, (_) => <int>{});
    _customControllers = List.generate(count, (_) => TextEditingController());
    _customOpen = List.generate(count, (_) => false);
  }

  @override
  void dispose() {
    for (final controller in _customControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _toggleOption(int questionIndex, int optionIndex) {
    final question = widget.prompt.questions[questionIndex];
    setState(() {
      // Selecting an option and typing custom text are mutually exclusive;
      // collapse the custom field back to its tap-to-expand affordance too.
      _customControllers[questionIndex].clear();
      _customOpen[questionIndex] = false;
      final selected = _selected[questionIndex];
      if (question.multiSelect) {
        if (!selected.remove(optionIndex)) selected.add(optionIndex);
      } else {
        selected
          ..clear()
          ..add(optionIndex);
      }
    });
  }

  void _onCustomChanged(int questionIndex, String value) {
    setState(() {
      // Typing custom text clears any option selection for this question.
      if (value.trim().isNotEmpty) _selected[questionIndex].clear();
    });
  }

  bool _isAnswered(int questionIndex) {
    final question = widget.prompt.questions[questionIndex];
    final selected = _selected[questionIndex];
    // Custom free-text answers exist only for single-select questions (the
    // submitter rejects them for multi-select), so multi-select is valid iff at
    // least one option is checked.
    if (question.multiSelect) return selected.isNotEmpty;
    return _customControllers[questionIndex].text.trim().isNotEmpty ||
        selected.length == 1;
  }

  bool get _canSend {
    for (var i = 0; i < widget.prompt.questions.length; i++) {
      if (!_isAnswered(i)) return false;
    }
    return true;
  }

  List<StructuredPromptAnswer> _buildAnswers() {
    final answers = <StructuredPromptAnswer>[];
    for (var i = 0; i < widget.prompt.questions.length; i++) {
      final custom = widget.prompt.questions[i].multiSelect
          ? ''
          : _customControllers[i].text.trim();
      if (custom.isNotEmpty) {
        answers.add(
          StructuredPromptAnswer(selectedIndexes: const [], customText: custom),
        );
      } else {
        final indexes = _selected[i].toList()..sort();
        answers.add(StructuredPromptAnswer(selectedIndexes: indexes));
      }
    }
    return answers;
  }

  Future<void> _submit() async {
    if (_submitting || !_canSend) return;
    setState(() => _submitting = true);
    try {
      await widget.onSubmit(_buildAnswers());
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      // The caller surfaces the error (top toast); keep the sheet open so the
      // staged answers aren't lost and the user can retry.
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final questions = widget.prompt.questions;
    return SafeArea(
      child: Padding(
        // Lift the sheet above the on-screen keyboard when a custom field has
        // focus, so the field and action row stay visible.
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              decoration: BoxDecoration(
                color: scheme.outline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (index, question) in questions.indexed) ...[
                      if (index > 0) const Divider(height: 20),
                      _buildQuestion(context, l10n, index, question),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  TextButton(
                    key: const ValueKey('structured_prompt_cancel_button'),
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: Text(l10n.agentAskUserClose),
                  ),
                  const Spacer(),
                  FilledButton(
                    key: const ValueKey('structured_prompt_send_button'),
                    onPressed: (_canSend && !_submitting) ? _submit : null,
                    child: _submitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.agentAskUserSend),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuestion(
    BuildContext context,
    AppLocalizations l10n,
    int index,
    StructuredPromptQuestion question,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final eyebrow = question.header.isNotEmpty
        ? question.header
        : l10n.agentAskUserQuestionNumber(
            index + 1,
            widget.prompt.questions.length,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          eyebrow,
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(question.question, style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        if (question.multiSelect)
          for (final (optionIndex, option) in question.options.indexed)
            _buildOption(index, question, optionIndex, option)
        else
          RadioGroup<int>(
            groupValue: _selected[index].isEmpty
                ? null
                : _selected[index].first,
            onChanged: (value) {
              if (!_submitting && value != null) _toggleOption(index, value);
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (optionIndex, option) in question.options.indexed)
                  _buildOption(index, question, optionIndex, option),
              ],
            ),
          ),
        // A custom free-text answer is offered only for single-select
        // questions; the submitter rejects custom text on multi-select ones.
        // It starts collapsed behind a tap-to-expand affordance (mirroring
        // the TUI's "Type something" option) and only reveals the TextField
        // once tapped.
        if (!question.multiSelect) ...[
          const SizedBox(height: 6),
          if (_customOpen[index])
            TextField(
              key: ValueKey('structured_prompt_q${index}_custom'),
              controller: _customControllers[index],
              enabled: !_submitting,
              autofocus: true,
              minLines: 1,
              maxLines: 4,
              contextMenuBuilder: noScanTextContextMenuBuilder,
              onChanged: (value) => _onCustomChanged(index, value),
              decoration: InputDecoration(
                hintText: l10n.agentAskUserCustomHint,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: ValueKey('structured_prompt_q${index}_custom_toggle'),
                onPressed: _submitting
                    ? null
                    : () => setState(() => _customOpen[index] = true),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  l10n.agentAskUserCustomHint,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.primary,
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildOption(
    int questionIndex,
    StructuredPromptQuestion question,
    int optionIndex,
    StructuredPromptOption option,
  ) {
    final selected = _selected[questionIndex].contains(optionIndex);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final titleStyle = theme.textTheme.bodyMedium;
    final subtitle = option.description == null
        ? null
        : Text(
            option.description!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          );
    final key = ValueKey('structured_prompt_q${questionIndex}_opt$optionIndex');
    void toggle() => _toggleOption(questionIndex, optionIndex);
    if (question.multiSelect) {
      return CheckboxListTile(
        key: key,
        value: selected,
        onChanged: _submitting ? null : (_) => toggle(),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        dense: true,
        visualDensity: VisualDensity.compact,
        title: Text(option.label, style: titleStyle),
        subtitle: subtitle,
      );
    }
    // Group value / onChanged are supplied by the enclosing [RadioGroup].
    return RadioListTile<int>(
      key: key,
      value: optionIndex,
      enabled: !_submitting,
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
      dense: true,
      visualDensity: VisualDensity.compact,
      title: Text(option.label, style: titleStyle),
      subtitle: subtitle,
    );
  }
}
