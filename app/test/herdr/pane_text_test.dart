import 'package:drover/src/herdr/ansi_text.dart';
import 'package:drover/src/herdr/pane_text.dart';
import 'package:drover/src/herdr/text_width.dart';
import 'package:flutter_test/flutter_test.dart';

const permissionPromptFixture = '''
 Bash command

   touch spike-test.txt
   Create empty file spike-test.txt

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to drover-spike-test/ from this
      project
   3. No

 Esc to cancel · Tab to amend · ctrl+e to explain''';

const chromeFixture = '''
✻ Baked for 13s

─────────────────────────────────────────
❯ send it a real task
─────────────────────────────────────────
  -- INSERT -- ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents''';

/// A fixed-width "┃ content ┃"-style panel row like Copilot CLI draws: a
/// leading border, the content, then space padding out to [width] visible
/// columns, then the trailing border. [width] is chosen well above the
/// helper's short-box threshold.
String _panelRow(String content, {int width = 90}) {
  final inner = '┃ $content';
  final pad = width - inner.length - 1;
  assert(pad >= 0, 'content too long for width $width');
  return '$inner${' ' * pad}┃';
}

void main() {
  group('stripPanelPadding', () {
    test('removes right padding + trailing border from a multi-row panel, '
        'keeping content, leading border and newlines', () {
      final fixture =
          '${_panelRow('Hello there, human! How can I help?')}\n'
          '${_panelRow('This is a second line of assistant output.')}\n'
          '${_panelRow('And a third, just to be sure.')}';

      final result = stripPanelPadding(fixture);

      expect(
        result,
        '┃ Hello there, human! How can I help?\n'
        '┃ This is a second line of assistant output.\n'
        '┃ And a third, just to be sure.',
      );
      expect(result, isNot(contains('  ┃'))); // no orphaned right border
    });

    test('removes right padding + trailing border from a multi-row panel '
        'whose content has non-BMP emoji, keeping every emoji and losing no '
        'padding/border', () {
      // Built with display-cell-derived (not UTF-16-length-derived) padding,
      // unlike `_panelRow`, so the fixture itself is exactly [width] visible
      // cells wide regardless of the double-width surrogate-pair emoji it
      // contains -- just as a real terminal panel would be.
      String emojiPanelRow(String content, {int width = 90}) {
        final inner = '┃ $content';
        final pad = width - displayWidth(inner) - 1;
        assert(pad >= 0, 'content too long for width $width');
        return '$inner${' ' * pad}┃';
      }

      final fixture =
          '${emojiPanelRow('Shipped it 🚀🎉! Emoji: 😀 done')}\n'
          '${emojiPanelRow('A plain second row, no emoji here.')}';

      final result = stripPanelPadding(fixture);

      expect(
        result,
        '┃ Shipped it 🚀🎉! Emoji: 😀 done\n'
        '┃ A plain second row, no emoji here.',
      );
      expect(result, isNot(contains('  ┃'))); // no orphaned right border
    });

    test('removes padding + border from a panel mixing ASCII and CJK rows '
        'that share one display-cell border column, reverse-video border '
        'included', () {
      // Modeled on a live Copilot CLI capture in a 71-column pane: a ┃
      // scrollbar sits at display-cell column 69 on every row, some rows
      // with a reverse-video SGR immediately before the glyph. The CJK rows
      // reach that cell column with fewer runes than the ASCII rows, so
      // only a cell-based column measure groups them into one panel.
      String scrollbarRow(String content, {bool reverseVideo = false}) {
        final pad = ' ' * (69 - displayWidth(content));
        return reverseVideo ? '$content$pad\x1B[7m┃\x1B[0m' : '$content$pad┃';
      }

      final fixture = [
        scrollbarRow(' ● Tip: /feedback, an ASCII-only row'),
        scrollbarRow(
          '    日本語の行で幅を確認します。 line 3 mixed: width=幅',
          reverseVideo: true,
        ),
        scrollbarRow('    check 完了. Do not run any tools or commands.'),
        scrollbarRow('   width=幅 check 完了.', reverseVideo: true),
      ].join('\n');

      final result = stripPanelPadding(fixture);

      expect(result.split('\n'), [
        ' ● Tip: /feedback, an ASCII-only row',
        '    日本語の行で幅を確認します。 line 3 mixed: width=幅\x1B[7m\x1B[0m',
        '    check 完了. Do not run any tools or commands.',
        '   width=幅 check 完了.\x1B[7m\x1B[0m',
      ]);
      expect(stripAnsi(result), isNot(contains('┃')));
    });

    test('leaves rows alone whose display-cell border columns differ, even '
        'when their rune columns coincide', () {
      // Same rune column (50) on both rows -- the old rune-based measure
      // would have grouped and stripped them -- but different cell columns
      // (55 vs 50), so they are not one fixed-width panel.
      final fixture =
          '日本語メモ${' ' * 45}┃\n'
          'abcde${' ' * 45}┃';
      expect(stripPanelPadding(fixture), fixture);
    });

    test('is idempotent: reapplying makes no further change', () {
      final fixture =
          '${_panelRow('one two three')}\n${_panelRow('four five six')}';
      final once = stripPanelPadding(fixture);
      final twice = stripPanelPadding(once);
      expect(twice, once);
    });

    test('preserves an ANSI reset embedded in the removed suffix so styling '
        "doesn't leak into the next line", () {
      // Bold is switched on mid-content and never explicitly turned off
      // before the padding; only a reset sitting right before the border
      // (i.e. inside the removed span) closes it. Padded to the same
      // visible width (90) as row2 below so both are recognized as one
      // panel block: content "┃ ALERT" is 7 visible chars, so 82 spaces
      // of padding reach column 89 (width 90 minus the border itself).
      final row1 =
          '┃ \x1B[1mALERT${' ' * 82}\x1B[0m┃'; // width 90, bold left open
      final row2 = _panelRow('follow-up line', width: 90);
      final fixture = '$row1\n$row2';

      final result = stripPanelPadding(fixture);
      final lines = result.split('\n');

      // The border/padding characters are gone but the reset survived.
      expect(lines[0], '┃ \x1B[1mALERT\x1B[0m');
      expect(lines[1], '┃ follow-up line');

      // And parseAnsi (which carries style state across newlines, as a
      // terminal would) confirms bold does not leak into the second line.
      final spans = parseAnsi(result);
      final followUpSpan = spans.firstWhere(
        (span) => span.text.contains('follow-up'),
      );
      expect(followUpSpan.bold, isFalse);
    });

    test('preserves a style-opening SGR in the removed suffix with no reset, '
        'carrying it across the newline as terminal semantics dictate', () {
      // Bold is switched on inside the padding (the removed suffix) and never
      // closed. The border/padding must be removed, but the bold SGR is
      // retained so that parseAnsi sees it and correctly carries bold into
      // the next line. Padded to width 90: content "┃ text" is 6 visible
      // chars, so 83 spaces of padding reach column 89 (width 90 minus the
      // border itself).
      final row1 =
          '┃ text${' ' * 83}\x1B[1m┃'; // width 90, bold opened in padding
      final row2 = _panelRow('next line after bold', width: 90);
      final fixture = '$row1\n$row2';

      final result = stripPanelPadding(fixture);
      final lines = result.split('\n');

      // The border/padding characters and the spaces are gone, but the bold
      // SGR that was inside the removed span is preserved.
      expect(lines[0], '┃ text\x1B[1m');
      expect(lines[1], '┃ next line after bold');

      // parseAnsi carries the bold state across the newline, as a terminal
      // would, so the next line inherits the bold from the previous line.
      final spans = parseAnsi(result);
      final nextLineSpan = spans.firstWhere(
        (span) => span.text.contains('next line'),
      );
      expect(nextLineSpan.bold, isTrue);
    });

    test('leaves ordinary long prose untouched', () {
      const prose =
          'This is a perfectly ordinary long line of assistant prose that '
          'happens to be wider than a phone screen but contains no '
          'box-drawing characters at all, so it should wrap normally '
          'without any special handling from this helper whatsoever.';
      expect(stripPanelPadding(prose), prose);
    });

    test('leaves a Markdown table (ASCII pipes) untouched', () {
      const table =
          '| Column A | Column B | Column C that is deliberately long |\n'
          '| -------- | -------- | ----------------------------------- |\n'
          '| value 1  | value 2  | a rather long value in this cell    |';
      expect(stripPanelPadding(table), table);
    });

    test('leaves source/tree output with a non-trailing border untouched', () {
      const tree =
          'project/\n'
          '├── lib/\n'
          '│   └── main.dart\n'
          '└── test/\n'
          '    └── main_test.dart';
      expect(stripPanelPadding(tree), tree);
    });

    test('leaves a single suspicious padded-and-bordered line untouched '
        'without adjacent panel context', () {
      final lonely = _panelRow('only one row, no siblings');
      expect(stripPanelPadding(lonely), lonely);
    });

    test('leaves a short Unicode box untouched', () {
      const box =
          '┌────────┐\n'
          '│ Hi Bob │\n'
          '│ 2nd row │\n'
          '└────────┘';
      expect(stripPanelPadding(box), box);
    });
  });

  group('stripTuiChrome', () {
    test('strips trailing rule + mode line but keeps a draft with content', () {
      final result = stripTuiChrome(chromeFixture);

      expect(result.split('\n').last, '❯ send it a real task');
      expect(result, isNot(contains('-- INSERT --')));
      expect(
        result,
        '✻ Baked for 13s\n'
        '\n'
        '─────────────────────────────────────────\n'
        '❯ send it a real task',
      );
    });

    test('strips chrome even when the lines carry ANSI styling', () {
      const ansiChrome =
          'body\n'
          '\x1B[38;2;136;136;136m─────────────────\x1B[0m\n'
          '  \x1B[2m-- INSERT -- ⏵⏵ auto mode on (shift+tab to cycle)\x1B[0m';
      expect(stripTuiChrome(ansiChrome), 'body');
    });

    test('strips a bare empty prompt line', () {
      expect(stripTuiChrome('some output\n❯ '), 'some output');
    });

    test('leaves content untouched when there is no trailing chrome', () {
      expect(stripTuiChrome('a\nb\nc'), 'a\nb\nc');
    });
  });

  group('parsePromptOptions', () {
    test('parses the real Claude Code permission prompt fixture', () {
      final question = parsePromptOptions(permissionPromptFixture);

      expect(question, isNotNull);
      expect(question!.question, 'Do you want to proceed?');
      expect(question.options, hasLength(3));

      expect(question.options[0].number, 1);
      expect(question.options[0].label, 'Yes');
      expect(question.options[0].selected, isTrue);

      expect(question.options[1].number, 2);
      expect(
        question.options[1].label,
        'Yes, and always allow access to drover-spike-test/ from this '
        'project',
      );
      expect(question.options[1].selected, isFalse);

      expect(question.options[2].number, 3);
      expect(question.options[2].label, 'No');
      expect(question.options[2].selected, isFalse);
    });

    test('returns null when there is no options list', () {
      expect(parsePromptOptions(chromeFixture), isNull);
    });

    test('returns null when there is only one option', () {
      expect(parsePromptOptions('Proceed?\n1. Yes'), isNull);
    });

    test('returns null when numbering does not start at 1', () {
      expect(parsePromptOptions('Proceed?\n2. Yes\n3. No'), isNull);
    });

    test('returns null when numbering skips', () {
      expect(parsePromptOptions('Proceed?\n1. Yes\n3. No'), isNull);
    });
  });
}
