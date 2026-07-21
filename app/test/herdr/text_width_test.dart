import 'package:drover/src/herdr/text_width.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('runeDisplayWidth', () {
    test('ASCII is 1 cell', () {
      expect(runeDisplayWidth('a'.runes.single), 1);
      expect(runeDisplayWidth(' '.runes.single), 1);
    });

    test('box-drawing and block glyphs are 1 cell', () {
      for (final rune in '│┃║━▄▀'.runes) {
        expect(
          runeDisplayWidth(rune),
          1,
          reason: 'U+${rune.toRadixString(16)}',
        );
      }
    });

    test('CJK, fullwidth, Hangul and wide emoji are 2 cells', () {
      expect(runeDisplayWidth('日'.runes.single), 2);
      expect(runeDisplayWidth('Ａ'.runes.single), 2); // fullwidth A, U+FF21
      expect(runeDisplayWidth('한'.runes.single), 2); // Hangul syllable
      expect(runeDisplayWidth(0x20000), 2); // non-BMP CJK Extension B
      expect(runeDisplayWidth(0x1F600), 2); // emoji 😀
    });
  });

  group('displayWidth', () {
    test('ASCII counts 1 cell per char', () {
      expect(displayWidth(''), 0);
      expect(displayWidth('hello world'), 11);
    });

    test('hiragana and kanji count 2 cells per char', () {
      expect(displayWidth('日本語'), 6);
      expect(displayWidth('ひらがな'), 8);
    });

    test('katakana counts 2 cells per char', () {
      expect(displayWidth('カタカナ'), 8);
    });

    test('fullwidth forms count 2 cells per char', () {
      expect(displayWidth('Ａ'), 2);
      expect(displayWidth('！？'), 4);
    });

    test('Hangul syllables count 2 cells per char', () {
      expect(displayWidth('한글'), 4);
    });

    test('box-drawing and block glyphs count 1 cell per char', () {
      expect(displayWidth('│┃║━▄▀'), 6);
    });

    test('non-BMP wide ideograph counts 2 cells, not per surrogate half', () {
      expect(displayWidth('\u{20000}'), 2);
    });

    test('emoji count 2 cells', () {
      expect(displayWidth('😀'), 2);
      expect(displayWidth('🚀🎉'), 4);
    });

    test('EAW-Wide status symbols common in agent output count 2 cells', () {
      for (final symbol in ['✅', '❌', '⚡', '⭐', '🟢', '⌚']) {
        expect(displayWidth(symbol), 2, reason: symbol);
      }
    });

    test('an EAW-Neutral pictograph counts 1 cell', () {
      // U+1F321 THERMOMETER is emoji-adjacent but East_Asian_Width=N, so a
      // terminal renders it single-width; a broad "emoji block" range would
      // wrongly count it as 2.
      expect(displayWidth('\u{1F321}'), 1);
    });

    test('mixed ASCII/CJK strings total per-rune widths', () {
      // Matches a row measured live from Copilot CLI: 17 runes, 3 of them
      // wide (幅完了), so 20 cells.
      expect(displayWidth('width=幅 check 完了.'), 20);
      // 15 wide runes (14 CJK + 幅) and 21 ASCII: 15 * 2 + 21 = 51.
      expect(displayWidth('日本語の行で幅を確認します。 line 3 mixed: width=幅'), 51);
    });
  });
}
