// Pure parsing helpers for herdr `agent read` text output: stripping TUI
// chrome (status/mode lines, box-drawing rules), recognizing the agent's
// current mode, and recognizing Claude Code style numbered permission prompts.

import 'ansi_text.dart';

final _dashRule = RegExp(r'^[─]{5,}\s*$');
final _modeLine = RegExp(r'^\s*[⏸⏵]');
final _emptyPrompt = RegExp(r'^❯\s*$');

/// The agent's current interaction mode, as shown on the TUI mode line and
/// cycled with shift+tab (Claude Code).
enum AgentMode {
  normal('normal'),
  autoAccept('auto-accept'),
  plan('plan'),
  bypass('bypass');

  const AgentMode(this.label);

  final String label;
}

/// Reads the current [AgentMode] from the trailing mode line of [text] (e.g.
/// `-- INSERT -- ⏵⏵ auto mode on (shift+tab to cycle)`). Returns null when no
/// mode line is present. Expects plain text — strip ANSI first.
AgentMode? parseAgentMode(String text) {
  final lines = text.split('\n');
  final start = lines.length > 6 ? lines.length - 6 : 0;
  for (var i = lines.length - 1; i >= start; i--) {
    final lower = lines[i].toLowerCase();
    final isModeLine =
        lower.contains('-- insert --') || _modeLine.hasMatch(lines[i]);
    if (!isModeLine) continue;
    if (lower.contains('plan mode')) return AgentMode.plan;
    if (lower.contains('bypass')) return AgentMode.bypass;
    if (lower.contains('auto')) return AgentMode.autoAccept;
    return AgentMode.normal;
  }
  return null;
}

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
/// Claude Code permission dialog). Returns null if fewer than two options are
/// found or the numbering doesn't start at 1 and increment by 1.
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
