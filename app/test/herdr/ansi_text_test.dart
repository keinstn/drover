import 'dart:ui' show Color;

import 'package:drover/src/herdr/ansi_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('stripAnsi', () {
    test('removes SGR sequences, leaving plain text', () {
      const input = '\x1B[0m\x1B[38;2;136;136;136m─── hi ───\x1B[0m';
      expect(stripAnsi(input), '─── hi ───');
    });

    test('is a no-op on plain text', () {
      expect(stripAnsi('nothing here'), 'nothing here');
    });
  });

  group('parseAnsi', () {
    test('splits truecolor runs and carries the default colour', () {
      const input = 'plain\x1B[38;2;255;0;0mred\x1B[0mback';
      final spans = parseAnsi(input);
      expect(spans.map((s) => s.text), ['plain', 'red', 'back']);
      expect(spans[0].color, isNull);
      expect(spans[1].color, const Color(0xFFFF0000));
      expect(spans[2].color, isNull);
    });

    test('tracks bold on and reset', () {
      const input = '\x1B[1mbold\x1B[0mnormal';
      final spans = parseAnsi(input);
      expect(spans[0].bold, isTrue);
      expect(spans[1].bold, isFalse);
    });

    test('parses 256-colour cube and greyscale', () {
      // 196 = pure red in the 6x6x6 cube; 231 = white.
      final red = parseAnsi('\x1B[38;5;196mx').single;
      expect(red.color, const Color(0xFFFF0000));
      final white = parseAnsi('\x1B[38;5;231mx').single;
      expect(white.color, const Color(0xFFFFFFFF));
    });

    test('handles basic and bright foreground codes', () {
      expect(parseAnsi('\x1B[31mx').single.color, const Color(0xFFCD0000));
      expect(parseAnsi('\x1B[91mx').single.color, const Color(0xFFFF0000));
    });

    test('returns a single span for text with no escapes', () {
      final spans = parseAnsi('just text');
      expect(spans, hasLength(1));
      expect(spans.single.text, 'just text');
      expect(spans.single.color, isNull);
    });
  });
}
