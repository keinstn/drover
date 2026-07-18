import 'package:drover/src/herdr/pane_text.dart';
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

void main() {
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
