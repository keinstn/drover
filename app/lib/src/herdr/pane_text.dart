// Pure parsing helpers for herdr `agent read` text output: stripping TUI
// chrome (status/mode lines, box-drawing rules) and recognizing a generic
// numbered-options permission prompt (the shared fallback for agents with no
// dedicated structured-prompt capability).

import 'ansi_text.dart';

final _dashRule = RegExp(r'^[─]{5,}\s*$');
final _modeLine = RegExp(r'^\s*[⏸⏵]');
final _emptyPrompt = RegExp(r'^❯\s*$');

/// Strips trailing TUI chrome lines (bottom-up) from [text]: blank lines,
/// box-drawing rules, `-- INSERT --` mode indicators, status lines, and a
/// bare empty prompt. Stops at the first trailing line that matches none of
/// these, so a pending draft (a prompt line WITH content) survives. Kept lines
/// are returned verbatim, so any ANSI styling on them survives.
String stripTuiChrome(String text) {
  final lines = text.split('\n');
  var end = lines.length;
  while (end > 0) {
    final line = stripAnsi(lines[end - 1]);
    if (line.trim().isEmpty ||
        _dashRule.hasMatch(line) ||
        line.contains('-- INSERT --') ||
        _modeLine.hasMatch(line) ||
        _emptyPrompt.hasMatch(line)) {
      end--;
    } else {
      break;
    }
  }
  return lines.sublist(0, end).join('\n');
}

class PromptOption {
  const PromptOption({
    required this.number,
    required this.label,
    required this.selected,
  });

  final int number;
  final String label;
  final bool selected;
}

class PromptQuestion {
  const PromptQuestion({required this.question, required this.options});

  final String? question;
  final List<PromptOption> options;
}

final _optionPattern = RegExp(r'^(\s*)(❯\s*)?(\d+)\.\s+(\S.*)$');

/// Scans the last 30 lines of [text] for a numbered options prompt (e.g. a
/// Claude Code style permission dialog). This is the shared fallback used
/// when the current agent has no [StructuredPromptCapability] of its own.
/// Returns null if fewer than two options are found or the numbering doesn't
/// start at 1 and increment by 1.
PromptQuestion? parsePromptOptions(String text) {
  final allLines = text.split('\n');
  final windowStart = allLines.length > 30 ? allLines.length - 30 : 0;
  final lines = allLines.sublist(windowStart);

  int? firstOptionIndex;
  for (var i = 0; i < lines.length; i++) {
    if (_optionPattern.hasMatch(lines[i])) {
      firstOptionIndex = i;
      break;
    }
  }
  if (firstOptionIndex == null) return null;

  final options = <PromptOption>[];
  int? numberColumn;
  var i = firstOptionIndex;
  while (i < lines.length) {
    final line = lines[i];
    final match = _optionPattern.firstMatch(line);
    if (match != null) {
      final leadIn = match.group(1)!.length + (match.group(2)?.length ?? 0);
      numberColumn ??= leadIn;
      options.add(
        PromptOption(
          number: int.parse(match.group(3)!),
          label: match.group(4)!.trim(),
          selected: match.group(2) != null,
        ),
      );
      i++;
      continue;
    }

    if (line.trim().isEmpty) break;

    final indent = line.length - line.trimLeft().length;
    if (options.isNotEmpty && indent > (numberColumn ?? 0)) {
      final last = options.removeLast();
      options.add(
        PromptOption(
          number: last.number,
          label: '${last.label} ${line.trim()}',
          selected: last.selected,
        ),
      );
      i++;
      continue;
    }
    break;
  }

  if (options.length < 2) return null;
  for (var idx = 0; idx < options.length; idx++) {
    if (options[idx].number != idx + 1) return null;
  }

  String? question;
  for (var j = firstOptionIndex - 1; j >= 0; j--) {
    final trimmed = lines[j].trim();
    if (trimmed.isEmpty) continue;
    question = trimmed.endsWith('?') ? trimmed : null;
    break;
  }

  return PromptQuestion(question: question, options: options);
}
