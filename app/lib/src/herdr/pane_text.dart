// Pure parsing helpers for herdr `agent read` text output: stripping TUI
// chrome (status/mode lines, box-drawing rules) and recognizing a generic
// numbered-options permission prompt (the shared fallback for agents with no
// dedicated structured-prompt capability).

import 'ansi_text.dart';

final _dashRule = RegExp(r'^[─]{5,}\s*$');
final _modeLine = RegExp(r'^\s*[⏸⏵]');
final _emptyPrompt = RegExp(r'^❯\s*$');

// A CSI escape sequence, ESC included -- the same shape `ansi_text.dart`'s
// own `stripAnsi` already matches and removes. We can't reuse `stripAnsi`
// here, though: `_truncateVisible` below needs each token's *position* so it
// can copy escapes through verbatim while truncating the surrounding visible
// text, and `stripAnsi` only deletes matches, it doesn't expose their spans.
// The accepted parameter charset (`[0-9;?]*`) intentionally mirrors
// `ansi_text.dart`'s `_anyAnsi` so both regexes recognize the same tokens.
final _csiToken = RegExp('\x1B\\[[0-9;?]*[A-Za-z]');

// A line ending in "padding ASCII spaces + one Unicode vertical border
// glyph", optionally followed by further trailing spaces. Deliberately
// restricted to │/┃/║ (not ASCII `|`) so Markdown tables and prose are never
// candidates, and to ASCII spaces (not tabs) since a tab's visible column
// depends on terminal tab-stop state we don't track, so it can't be counted
// reliably.
final _borderRowPattern = RegExp(
  r'^(?<content>.*?)(?<pad> +)(?<border>[│┃║]) *$',
);

// Below this column, treat a border as belonging to a small, legitimate box
// (e.g. a short confirmation dialog) rather than an artificially wide,
// fixed-column panel -- those don't need de-padding to wrap sanely.
const _minPanelColumn = 40;

// Need at least this many consecutive matching rows sharing the same border
// column before treating them as a real fixed-width panel, so a single
// one-off line that happens to look like a padded row is left alone.
const _minPanelRun = 2;

/// Removes the artificial fixed-width right-padding and trailing Unicode
/// vertical border (`│`, `┃`, `║`) that some bordered-panel TUI agents (e.g.
/// Copilot CLI) pad every row out to, so Flutter's soft-wrap doesn't strand
/// the lone border glyph on its own wrapped line (drover issue #16).
///
/// Detection is conservative and block-based, not a per-line regex: a line
/// only qualifies as "padding" if it ends in ASCII spaces followed by a
/// Unicode vertical border, *and* at least [_minPanelRun] consecutive lines
/// share the exact same border column, *and* that column is wide enough
/// ([_minPanelColumn]) to rule out short, legitimately narrow boxes. That
/// combination is what a fixed-width panel looks like structurally, and it's
/// what keeps this from touching Markdown tables (ASCII `|`), source/tree
/// output (the border isn't the trailing glyph there), ordinary diagrams,
/// short boxes, or an isolated line with no surrounding panel context.
///
/// Only the identified trailing padding/border *visible* characters are
/// removed; every ANSI escape sequence in the line -- including ones that sat
/// inside the removed span -- is preserved verbatim. This ensures all
/// zero-width escapes are retained so the exact post-line terminal SGR state
/// is preserved. A style-start with no reset intentionally carries across
/// newline, just as in the original terminal; resets are also retained.
/// Leading borders/content and all newlines are untouched. The transform is
/// idempotent: a cleaned line no longer matches [_borderRowPattern], so
/// re-running it is a no-op.
String stripPanelPadding(String text) {
  final lines = text.split('\n');
  final matches = lines
      .map((line) => _matchBorderRow(stripAnsi(line)))
      .toList();

  final result = List<String>.of(lines);
  var i = 0;
  while (i < lines.length) {
    final match = matches[i];
    if (match == null) {
      i++;
      continue;
    }
    final borderColumn = match.borderColumn;
    if (borderColumn < _minPanelColumn) {
      i++;
      continue;
    }
    var j = i + 1;
    while (j < lines.length &&
        matches[j] != null &&
        matches[j]!.borderColumn == borderColumn) {
      j++;
    }
    if (j - i >= _minPanelRun) {
      for (var k = i; k < j; k++) {
        result[k] = _truncateVisible(lines[k], matches[k]!.keepVisibleCount);
      }
    }
    i = j;
  }
  return result.join('\n');
}

/// A line's parsed "padding + trailing Unicode border" shape, in visible
/// (post-ANSI-stripping) *rune* offsets -- not UTF-16 code units, so a
/// non-BMP character (e.g. an emoji) in "content" counts as one column, not
/// two, matching how [_truncateVisible] counts runes when it consumes this
/// value. `RegExpMatch` only exposes the start/end of the whole match, not of
/// individual groups, so these offsets are derived from group rune counts
/// instead (safe because `_borderRowPattern` is anchored at `^`, so the match
/// -- and its "content" group -- always starts at offset 0).
class _BorderRowMatch {
  const _BorderRowMatch({
    required this.keepVisibleCount,
    required this.borderColumn,
  });

  /// Visible runes to keep -- i.e. the rune count of "content".
  final int keepVisibleCount;

  /// Visible column (in runes) of the trailing border character.
  final int borderColumn;
}

_BorderRowMatch? _matchBorderRow(String plainLine) {
  final match = _borderRowPattern.firstMatch(plainLine);
  if (match == null) return null;
  final contentLength = match.namedGroup('content')!.runes.length;
  final padLength = match.namedGroup('pad')!.runes.length;
  return _BorderRowMatch(
    keepVisibleCount: contentLength,
    borderColumn: contentLength + padLength,
  );
}

/// Returns [raw] with only its first [keepVisibleCount] non-escape runes
/// kept; every ANSI escape sequence is always kept, wherever it falls, since
/// escapes are zero-width and retaining them ensures the exact post-line
/// terminal SGR state is preserved.
String _truncateVisible(String raw, int keepVisibleCount) {
  final buffer = StringBuffer();
  var visible = 0;
  var cursor = 0;

  void keepVisibleRun(String run) {
    for (final rune in run.runes) {
      if (visible < keepVisibleCount) buffer.writeCharCode(rune);
      visible++;
    }
  }

  for (final match in _csiToken.allMatches(raw)) {
    keepVisibleRun(raw.substring(cursor, match.start));
    buffer.write(match.group(0));
    cursor = match.end;
  }
  keepVisibleRun(raw.substring(cursor));
  return buffer.toString();
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
